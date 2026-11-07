# Cache Implementation Status

Snapshot: 7 November 2026.

This document describes the in-progress data-cache sources, the read/store-hit
paths, the SRAM design decisions and the partial-store ECC update. It separates
logic already present in the files from intended behavior and missing
integration. It is not an RTL verification or timing sign-off.

The architectural target is in [Cache Design Constraints](cache-design-constraints.md).
The earlier HTML, SVG and PDF proposal is historical and does not describe this
implementation accurately.

## Source Map and Integration Status

| Source | Responsibility |
| --- | --- |
| [data_cache.sv](../rtl/cache/data_cache.sv) | OBI request capture, lookup and read/store-hit paths |
| [cache_pkg.sv](../rtl/cache/cache_pkg.sv) | Stored-word structs, record dimensions and partial-store ECC function |
| [cache_typedef.svh](../rtl/cache/cache_typedef.svh) | Instance-dependent address-tag, valid and dirty struct |
| [cache_data_sram.sv](../rtl/cache/cache_data_sram.sv) | Masked 80-bit SRAM interface and physical macro packing |
| [data_cache_param_checks.svh](../rtl/cache/data_cache_param_checks.svh) | Cache geometry and OBI-width elaboration checks |
| [cache_data_sram_param_checks.svh](../rtl/cache/cache_data_sram_param_checks.svh) | SRAM depth and width elaboration checks |
| [IHP SRAM implementation](../ihp13/tc_sram_impl.sv) | Technology-specific cuts and bit-mask connections |
| [Ibex SECDED package](../ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_secded_pkg.sv) | Original encoding function used by the ECC update |
| [Ibex load/store unit](../ibex/rtl/ibex_load_store_unit.sv) | Core byte-enable generation and existing data ECC encoder/checker |
| [Ibex LSU protocol](../ibex/doc/03_reference/load_store_unit.rst) | Grant/response timing and split capability transfers |

Only the cache package is currently listed in the root Bender sources. The
data-cache and SRAM-wrapper module files are not, and no data-cache instance is
connected in the SoC. A generate loop instantiates one SRAM wrapper per way;
the default configuration still has two wrappers.

The core still has `MemECC = 0`. Its write-integrity output is not connected,
its read-integrity input is tied to zero, and the OBI request ECC and
`is_cap_access` fields are tied to zero in `croc_domain.sv`. These are integration
TODOs, not functional ECC or capability-access signaling. Existing HyperRAM
tests do not verify this new cache.

## Current Coverage

Here, "present" means source-level logic exists, not that the path has passed a
build or test.

| Case | Present in the source | Still missing or limited |
| --- | --- | --- |
| Request acceptance | `req && gnt` captures address, write flag, byte-enable, capability-access flag, ID and first write word | Verify response accounting and the capability-pair input contract |
| Set lookup | Valid/address-tag comparison across ways; selected way is retained; geometry is checked at elaboration | Miss handling, allocation, replacement and functional verification |
| Full 32-bit store hit | Places the buffered 40-bit word in the selected half, marks dirty and answers in the SRAM-write cycle | RTL verification and end-to-end ECC wiring |
| Capability store hit | Buffers both words, writes all 80 bits, answers once in the write cycle and once in `IDLE` using `cap_flag_q` | Pair-contract enforcement, core flag wiring and separate second-request ID handling for generic requesters |
| Byte/halfword store hit | Reads the old word, merges bytes/tag/ECC, writes the selected half, marks dirty and answers | RTL verification; empty masks are excluded by a simulation assertion, not a hardware no-op policy |
| ECC merge helper | `ecc_merge_partial32()` calls the original inverted Ibex encoder and is used in `ACCESS_SRAM` | End-to-end integration and tag protection are not implemented |
| Ordinary read hit | Reads one record, selects one stored word and returns data, stored tag/ECC and the saved ID | RTL verification and core ECC wiring |
| Capability read hit | Reuses the 80-bit store buffer; sends one response per accepted half; an extra flag prevents repeated first responses | RTL verification, SRAM output-hold validation during waiting, pair-contract enforcement and core flag wiring |
| Eviction/refill | Architectural write-back intent only | Dirty write-back, allocation, line reception and failure handling |
| I-cache/shared HyperBus arbiter | Architectural decisions only | RTL, routing, maintenance, coherence and burst integration |

All valid bits reset to zero. Since there is no refill path yet, the draft
cannot populate a valid line after reset. None of these hit paths is an
end-to-end runnable cache at this snapshot.

## Representation and Addressing

### Payload, Stored Words and Tags

`cap_word_t` is a packed 40-bit word: 32 payload bits, one capability tag and
seven ECC bits. `cap_store_t` contains two of these words. Its name does not
mean every stored value is a capability; ordinary data also uses this layout.

| Record bits | Member |
| --- | --- |
| [31:0] | `lower.data` |
| [32] | `lower.cap_tag` |
| [39:33] | `lower.ecc` |
| [71:40] | `upper.data` |
| [72] | `upper.cap_tag` |
| [79:73] | `upper.ecc` |

There are two stored tags and no reserved bit. A capability still represents
one aligned 8-byte value. Ibex reconstructs its validity using the AND of the
tags returned with its two words. Normal stores produce tag zero; the cache
uses the saved incoming tag rather than sampling a later live request.

The target is seven ECC bits protecting each word's 32 payload bits plus tag.
The current helper protects only the 32 payload bits. Storing a tag next to an
ECC field does not mean that tag is covered by the code.

### Geometry and Lookup

The current parameter defaults are 8 KiB usable payload capacity, 16-byte
logical lines, two ways, 32-bit CPU data and 32-bit addresses.

```text
NumSets         = CacheDataBytes / (LineDataBytes * NumWays)
RecordsPerLine  = LineDataBytes / 8
RecordsPerWay   = CacheDataBytes / (NumWays * 8)
SramWordAddress = SetIndex * RecordsPerLine + floor(BlockOffset / 8)
```

With the defaults, there are 256 sets, two records per line and 512 records per
way. CPU address bits [3:0] are the line offset, [11:4] the set index and
[31:12] the cache address tag. Address bit 2 selects the lower or upper 32-bit
payload word within a record; byte enables select bytes within that word.

For example, address `0x80001234` selects set `0x23`, address tag `0x80001`,
the first record of the line, and its upper word. Within the selected way, the
SRAM word address is `0x23 * 2 = 70`. Address `0x80001230` uses the same
record's lower word; `0x80001238` uses record 71.

Lookup does not search the payload SRAM. It indexes the flipflop metadata by
set and compares the valid ways' address tags. The selected way plus record
offset then identifies one SRAM word.

CPU addresses count logical bytes. The SRAM wrapper address counts complete
80-bit records; it must not receive the CPU byte address or a multiplication
by ten. HyperRAM byte serialization is a separate, still-unimplemented layer.

The SRAM instances now use the derived `SramWordsPerWay`, `SramAddrWidth` and
`RecordBits`, with one instance per `NumWays`. The request vector is defaulted
as a whole. Way indices have at least one storage bit, so a direct-mapped
configuration is supported. For a single set, the set index is constant zero;
no set-address bits are consumed by the cache address tag.

Elaboration checks reject zero or inconsistent capacities, non-power-of-two
ways/sets, and line sizes that are not powers of two of at least 16 bytes.
Capacity must contain complete sets, and each way's record count must be a
positive multiple of 256. At least one address-tag bit must remain. OBI address,
32-bit data, byte-enable, ID, ECC and tag fields must match the implementation.
The 80-bit record and current codec are fixed during geometry sweeps.

The checks live in `data_cache_param_checks.svh` and
`cache_data_sram_param_checks.svh`, included directly in their respective
module scopes. This keeps the module bodies short without changing the
generate-time `$error` behavior. The headers use the existing `rtl/cache`
include path; no extra package, module instance or simulation-time process is
needed. Protocol assertions remain in `data_cache.sv`.

For example, 8 KiB with four ways uses 256 records per way and is supported
structurally. A 4 KiB, four-way configuration would need 128 records per way
and is rejected by the current SRAM packing constraints, not silently rounded.

## Store-Hit Control Flow

### IDLE and Request Lifetime

`IDLE` advertises grant. At an accepted request edge, it saves the transaction
fields and captures the first write word in `cap_store_q.lower`, including
the incoming ECC and tag. That member is a staging buffer: a normal store
targeting the upper SRAM word is still initially captured in `lower`.

The cache is initially blocking: no unrelated request may be accepted while
the current access is being completed. An OBI grant accepts a request; it is
not an OBI response or confirmation of a completed write.

### Full 32-Bit Store

On a hit with byte-enable `1111`, lookup can issue the SRAM write immediately.
No old payload is needed because the entire selected stored word is replaced.
Data, incoming tag and incoming ECC remain together.

| CPU address bit 2 | SRAM write-data placement | Ten-bit SRAM byte mask |
| --- | --- | --- |
| 0 | Buffered `lower` into bits [39:0] | `10'h01F` |
| 1 | Buffered `lower` into bits [79:40] | `10'h3E0` |

The mask does not move the data. Changing only the mask while leaving the new
word in the lower half would write stale upper-half data.

Dirty is a per-line property, not a per-record property. Set its next value
for the same set and way whose SRAM write is committing. With the fixed-latency
wrapper, metadata and SRAM can update at the same edge. A read request alone
must not set dirty, and reading an already dirty line must not clear it.

### Capability Store

Ibex emits two 32-bit requests for a complete capability. Both have byte-enable
`1111`; there is no halfword capability-store variant.

The first word is buffered in `lower`. If the second request is accepted during
a cache hit in `CACHE_LOOKUP`, its fields fill `cap_store_d.upper` and the
combined next-value struct can drive the SRAM write at that edge. Otherwise,
the saved way is used in `WAIT_FOR_SECOND_WORD`. The full-record mask is
`10'h3FF`. There is no need to read the previous record for this overwrite.

Using the combinational next value does not itself create a feedback loop.
It does create a timing path from the incoming second word and hit logic to
the SRAM write pins. Registering that result would shorten the path but add
latency and state.

The assumed pair is an 8-byte-aligned first address followed by address + 4,
from the same requester, with the expected write and capability-store flags.
The initial discussion assumes a CPU-data-only input. A crossbar does not
automatically lock two separate requests against JTAG/DMA interleaving. That
contract must be enforced before sharing this input with other requesters.
Instruction fetches belong to the separate I-cache path.

The SRAM-write cycle returns the first OBI response. `cap_flag_q` requests the
second response in the following `IDLE` cycle, which may also accept a new
request. The current store path echoes the first saved ID for both responses;
different IDs for the two halves are not yet handled. This relies on the
current same-core-ID assumption and must be revisited for generic requesters.
Writing both halves at one SRAM edge does not provide system-wide atomicity
against other memory paths.

### Byte and Halfword Store

A nonempty partial mask uses a read-modify-write path. This also covers a
partial bus request generated for a misaligned ordinary word access; it is not
restricted to instructions whose operand size is a byte or halfword.

1. On a lookup hit, save the way, request the old record with `sram_we = 0`,
   leave dirty unchanged and enter `ACCESS_SRAM`.
2. In `ACCESS_SRAM`, select the lower or upper old 40-bit word using address
   bit 2. Start `merged_word` from that word.
3. For each enabled CPU byte, replace the corresponding payload byte with the
   saved incoming byte. Preserve all disabled bytes. Use the incoming saved tag.
4. Compute the ECC update described below, then place the complete resulting
   40-bit word into the selected SRAM half.
5. Write that half with the same five-byte mask used for full-word stores,
   mark the line dirty and complete the OBI transaction.

These steps are present in the source: `ACCESS_SRAM` asserts the selected SRAM
request and write enable, sets dirty, returns one OBI response with the saved
ID and transitions to `IDLE`. This is source-level implementation status, not a
simulation result.

For an old word `0x11223344`, incoming data `0x0000AABB` and byte-enable
`0011`, the merged payload is `0x1122AABB`. The ECC of `0x0000AABB` alone
does not describe that result.

No extra register is required between the SRAM output and this merge. The
intended hit path uses one read phase followed by one merge/write phase: one
additional SRAM operation compared with a full-word hit. This is a scheduling
target, not a measured total OBI latency or a proven single-cycle timing path.

## Read-Hit Control Flow

### Shared Request Capture and SRAM Read

Both ordinary and capability reads enter through `IDLE`. An accepted
`obi_req_i.req && obi_rsp_o.gnt` saves the address, byte-enable, ID and
`is_cap_access` with `we = 0`. The capability-access marker applies to loads
and stores; `we` distinguishes their direction. No write data is captured for
a read.

On a hit, `CACHE_LOOKUP` handles both read types identically:

- Save the hit way in `selected_way_d`.
- Assert `sram_req[way]` with `sram_we = 0` and the derived record address.
- Set `cap_flag_read_valid_d = 1` and enter `ACCESS_SRAM`.
- Do not return an OBI response yet: the wrapper has one synchronous read cycle.

The wrapper reads the complete 80-bit record, even for an ordinary 32-bit
load. Its main and packed-remainder SRAM parts are read in parallel; neither
half requires another SRAM operation. Read hits do not write SRAM or change
the line's valid/dirty metadata.

### Ordinary Read

`read_word` is a combinational packed-struct view of the selected way's SRAM
output, not a flipflop. Saved CPU address bit 2 selects bits [39:0] or [79:40].
The selected `cap_word_t` provides the matching data, tag and ECC together.

In `ACCESS_SRAM`, the ordinary read returns:

| OBI response field | Source |
| --- | --- |
| `r.rdata` | `read_word.data` |
| `r.rid` | Saved `obi_aid_q` |
| `r.r_optional.ecc` | `read_word.ecc` |
| `r.r_optional.cap_tag` | `read_word.cap_tag` |

`rvalid` is asserted for that cycle and the next state is `IDLE`. The default
`obi_rsp_o = '0` supplies a zero error status for this hit response. The wrapper
has no error output, and the cache does not check ECC before answering.

Byte and halfword loads also receive the complete selected 32-bit word and its
stored ECC. The Ibex load/store unit extracts the requested bytes and performs
the required extension. The cache must not shift the returned word or generate
fresh ECC from the observed data.

The ordinary-read branch does not use the first-response flag: it leaves
`ACCESS_SRAM` immediately after its single response. The flag is armed again
by the next read hit in `CACHE_LOOKUP`.

### Capability Read and Shared Record Buffer

A capability load consists of two 32-bit OBI requests: an 8-byte-aligned first
address `A`, followed by `A + 4`, both marked `is_cap_access` with `we = 0`.
This pair uses one 80-bit record. Its two stored tags are returned separately;
Ibex combines them when reconstructing capability validity.

In `ACCESS_SRAM`, the cache assigns the complete SRAM result to
`cap_store_d`. Despite its store-oriented name, this packed struct is also the
read buffer. Reuse is safe for the current blocking cache: an unrelated store
cannot overwrite it while the capability read is active.

The first response uses `cap_store_d.lower` directly, so buffering the complete
record does not add a register-wait cycle. The registered `cap_store_q` retains
both words for the later upper-word response. No additional 80-bit read buffer
is needed for this path; the separately declared `rdata_cache_q` is not used
by it.

`cap_flag_read_valid_q` means the first response is still pending:

- It resets to zero and is armed in the read-hit lookup cycle.
- The first capability `ACCESS_SRAM` cycle asserts `rvalid` and clears the flag.
- Later cycles waiting in `ACCESS_SRAM` keep `rvalid = 0`. The first response
  must not repeat merely because the second request is late.

While in `ACCESS_SRAM`, `gnt` is high for the second request. On its
`req && gnt` handshake, the cache saves its ID in `obi_aid_d` and enters
`SEND_SECOND_WORD`. The first response still uses the previous `obi_aid_q`;
the second ID takes effect only at the clock edge. The second request's address
does not replace the saved first address or trigger another SRAM read.

`SEND_SECOND_WORD` returns the upper word, its stored tag/ECC and the captured
second ID for exactly one cycle, then enters `IDLE`. In that state,
`cap_store_d` defaults to `cap_store_q`, so the response is sourced from the
registered record. No new request is granted in `SEND_SECOND_WORD`.

The implementation assumes the second request belongs to the same capability
load and is the read of `A + 4`. This is not currently enforced by the
store-only second-address assertion. The initial CPU-data-only contract must
be preserved or explicitly enforced before allowing other requesters to
interleave here.

### OBI Timing and Latency

These bus-cycle labels describe the current read-hit scheduling, not measured
clock frequency. Handshakes and responses are sampled at the ending edge of
each listed cycle.

| Cycle | State | Ordinary read | Capability read with second request ready |
| --- | --- | --- | --- |
| C0 | `IDLE` | Accept the request | Accept the first request |
| C1 | `CACHE_LOOKUP` | Issue one SRAM read | Issue one SRAM read |
| C2 | `ACCESS_SRAM` | Return the selected word; next state `IDLE` | Return the lower word, buffer the record and accept the second request |
| C3 | `IDLE` / `SEND_SECOND_WORD` | May accept another request | Return the upper word; next state `IDLE` |
| C4 | Depends on next request / `IDLE` | Depends on next request | May accept another request |

The capability responses can therefore occupy consecutive cycles, one word
per cycle, with no empty response cycle between them. The first response and
the second request's grant may overlap because they belong to different
requests. A response to the newly granted request itself must wait until at
least the following cycle, as specified by the local Ibex LSU protocol.

If the second request arrives later, the first response still occurs at C2.
`ACCESS_SRAM` then waits with grant high and response-valid low. After the
second handshake at cycle Ck, `SEND_SECOND_WORD` answers at Ck+1. No repeated
SRAM request, first response or lookup is required. `UseRReady = 0` means
there is no response backpressure; each response-valid cycle completes one
previously accepted request.

The extra first-response flag costs one flipflop, not another pipeline stage.
This is not a fully pipelined cache: an ordinary read uses separate capture,
lookup and answer cycles, and the final capability-answer cycle does not also
accept a new independent access. Back-to-back capability answers are not a
claim of one new independent cache hit per cycle.

### SRAM Holding and Read Verification

The current capability branch assigns `cap_store_d` from `sram_rdata` on every
`ACCESS_SRAM` cycle, including cycles waiting for the second request. No new
SRAM operation is issued during that wait. The selected SRAM implementation
must therefore retain the read output until the second request has been
accepted. The wrapper's registered macro/slot selection alone is not proof of
an arbitrary macro output-hold guarantee.

This dependency must be tested with the selected SRAM model and preserved if
refill/write-back arbitration is added. If the SRAM output can change while
waiting, capture the record only on the initial read-result cycle and retain
that buffer afterwards; that behavior is not implemented by the current
repeated assignment.

Focused read regressions still need to verify both word selections, distinct
data/tag/ECC values in both halves, byte/halfword extraction, first and second
response IDs, and exactly one answer per accepted request. Delay the second
request for multiple cycles, change its live ID after its grant, and check
that reset clears the first-response flag. Read hits must leave SRAM contents
and dirty/valid state unchanged. Only the isolated geometry elaboration
described below has run; functional read behavior has not been RTL-simulated.

## SRAM Design Decisions

### One Masked Logical Port per Way

Each wrapper provides `req_i`, `we_i`, record address, 80-bit write data and
ten storage-byte enables, plus an 80-bit read result. There is no separate grant,
read-valid or SRAM-error signal. A valid request is sampled at the clock edge;
reads use one synchronous cycle. The controller must track that latency.

The four-bit CPU byte-enable and ten-bit storage mask are different interfaces.
After a partial store has assembled its complete new word and ECC, the SRAM
can overwrite all five storage bytes of that word. This does not overwrite
the other word.

### Packing 80 Bits into Available Cuts

Rather than allocate 64 + 32 bits per record and leave 16 bits unused, the
wrapper uses a main 64-bit part and a packed remainder:

| Part | Depth | Contents |
| --- | --- | --- |
| Main | `NumWords` | Record bits [63:0] |
| Remainder | `NumWords / 4` | Four 16-bit [79:64] record slices in each 64-bit word |

For record address `a`, main address is `a`, remainder address is `a >> 2`
and remainder slot is `a[1:0]`. Records 4 through 7 therefore share remainder
word 1, but use different slots.

The main part uses `be_i[7:0]`. The remainder write bus repeats the 16-bit
input slice four times, while `be_i[9:8]` is shifted into the selected slot.
Hardware byte/bit masks preserve the other slots without another read. Parts
with no enabled write bytes are not requested.

A lower-word write touches only the main part. An upper-word write touches
three main-part bytes and both bytes of its remainder slot at the same edge.
This follows from bit-slice packing; a physical part is not a capability word.
Current reads request both parts, even when only the lower word is needed.

### Elaboration-Time Macro Selection

Each part is decomposed independently into 64-bit-wide `tc_sram_impl` cuts,
largest first: depths 2048, 1024, 512, 256 and 64. All counts and base addresses
are elaboration-time constants. There is no runtime search for a suitable cut.

| Logical records per way | Main cuts | Remainder cuts | Total cuts per way |
| ---: | --- | --- | ---: |
| 256 | 1 x 256 | 1 x 64 | 2 |
| 512 | 1 x 512 | 2 x 64 | 3 |
| 1024 | 1 x 1024 | 1 x 256 | 2 |
| 2048 | 1 x 2048 | 1 x 512 | 2 |
| 4096 | 2 x 2048 | 1 x 1024 | 3 |

Widths in the table are all 64 bits. Require a positive record count divisible
by 256, so both parts are exactly covered by the available cuts. Generate-time
checks now enforce this rule, `DataWidth = 80` and the matching record-address
width. These remain overrideable parameters, but unsupported combinations fail
elaboration rather than silently losing data.

At the default size, each way uses 512 x 64 + 2 x 64 x 64 = 40,960 storage bits.
Both ways together use six cuts and 81,920 bits: 10 KiB for 8 KiB of payload.
There are no extra unused macro bits for these sizes. The record's own tag/ECC
overhead still exists.

### Read Selection and Reset

Each part registers a one-hot selected-macro vector for a read. The wrapper
also saves the two remainder-slot bits. Combinational multiplexers select
macro data and reassemble the 80-bit output. Selection uses the saved read
address information, not the address of a later request.

The wrapper can accept at most one logical operation per cycle. Changing the
request address does not add a second read-data register. Read-during-write
behavior and arbitrary output holding must not be assumed without testing the
selected SRAM implementation.

Reset clears selector registers, not SRAM contents. The cache resets valid
bits. Before a partial store reads a valid line, the full encoded line must
already have been initialized or refilled. Zero-filled data with zero ECC is
not a valid initialization rule for the inverted Ibex code.

## ECC Update Without a Cache Checker

### Codec Consistency

`ecc_merge_partial32()` calls
`prim_secded_pkg::prim_secded_inv_39_32_enc()`, the package-function equivalent
of the module used by the Ibex load/store unit. There is no copied parity matrix
or substitution of a different Hamming code just because its width matches.

The output contains 32 payload bits plus seven ECC bits; the helper extracts
bits [38:32]. The inverted code's ECC for zero data is `7'h2A`, not zero.
The function currently ignores `cap_tag`. Extending to data plus tag requires
one consistent 33-input-bit codec in store generation, partial updates, core
checking, initialization and all memory-image/packing logic.

### Merge Equation

Let `O` be the observed old 32-bit payload, `N` the incoming payload, and
`eO` and `eN` their supplied ECC fields. Let `E(x)` mean the seven ECC
bits produced by the exact inverted Ibex encoder. For every byte:

```text
Result byte = byte_enable ? incoming byte : old byte
Unused byte = byte_enable ? old byte      : incoming byte

eResult = eO XOR eN XOR E(Unused)
```

`Unused` contains the bytes not selected into the result. Its reversed
selection is intentional, not a second data result or a stored extra word.
For the halfword example above, `Result = 0x1122AABB` and
`Unused = 0x00003344`.

The inverted encoding is affine: it is a linear parity mapping plus a fixed
inversion constant. Using the original encoder for the third term preserves
that constant. Arbitrarily XORing only the two ECC fields, or using a
non-inverted encoder for the third term, would not implement this equation.

For analysis, define the seven-bit syndrome as:

```text
S(data, ecc) = ecc XOR E(data)

S(Result, eResult) = S(O, eO) XOR S(N, eN)
```

This follows from `Result XOR Unused = O XOR N`. The hardware does not compute
or test these syndromes. It implements byte selection, one encoding operation
and XORs. It has no decoder, correction action or ECC-error branch.

Blindly setting `eResult = E(Result)` would instead make every observed result
look valid, including corrupted preserved bytes. That is not the chosen update.

### Fault Model and Silent-Corruption Limit

| Input situation | Result |
| --- | --- |
| Both input codewords valid | Result codeword is valid for the merged payload |
| One input valid, the other has a nonzero syndrome | Nonzero syndrome is preserved for later detection in the core |
| Both inputs have nonzero syndromes | Syndromes combine by XOR; equal syndromes cancel |

Single- and double-bit errors inside one input codeword are detected by the
existing SECDED code and retain their nonzero syndrome through this update
when the other input is valid. There is no guarantee for arbitrary faults
across both inputs, nor for error patterns the underlying code already misses.

A concrete cancellation case uses byte-enable `0011`:

1. Old intended data is `0x11223344`; its bit 0 flips to produce
   `0x11223345`, while old ECC remains unchanged.
2. Incoming intended data is `0x0000AABB`; its bit 0 also flips to produce
   `0x0000AABA`, while incoming ECC remains unchanged.
3. Both inputs have the same nonzero syndrome. The merge produces
   `0x1122AABA`, not the intended `0x1122AABB`, but its output syndrome is zero.

The core can therefore accept corrupted data in this case. This is
deterministic silent corruption, not language-level undefined behavior and not
a guaranteed trap. Two bad inputs can arise at different times: a stored
syndrome may survive several partial stores until a faulty incoming request
with the same syndrome cancels it.

The chosen no-checker path accepts this limitation under the initial
single-faulty-input-codeword assumption. It must not be described as guaranteed
end-to-end detection of every two-bit fault across a store operation. A stricter
fault model requires another design decision, such as independently checking
both inputs before committing; that is not implemented here.

### Special Cases and Validation

- Full-word stores bypass the helper and use incoming ECC. Overwriting all
  old data must not unnecessarily retain an old-word error.
- A zero byte mask needs an explicit no-op or rejection policy. It must not
  silently change data, tag, ECC or dirty state.
- Reads return the stored ECC, not freshly generated ECC.
- Capability stores supply both complete words; no old-record ECC merge is
  needed.
- The current core-only checking policy detects errors when the core consumes
  a codeword. It does not itself scrub idle cache contents, validate every
  write-back, or give JTAG/DMA their own integrity checker.

During design, an ad hoc JavaScript model using the local encoder matrix
checked 262,248 cases: twelve deterministic data pairs, all fourteen nonempty
partial byte masks, and clean, single-bit and double-bit faults within each
input separately. It also demonstrated the two-input cancellation example.
This checks the merge identity, not SystemVerilog compilation, RTL simulation,
formal equivalence, core integration or timing. No checked-in RTL regression
for this helper exists yet.

## Hardware, Timing and Sweep Trade-Offs

| Decision | Benefit | Cost or limit |
| --- | --- | --- |
| 80-bit records | Two payload words, two tags and fourteen ECC bits fit without padding | 25% storage/transfer overhead relative to payload |
| Packed remainder instead of 64 + 32 bits per record | Avoids sixteen unused macro bits per record | Extra cuts, slot selection, masks and routing can increase physical area |
| Largest-fitting-cut decomposition | Scales depth without hand-written cases for every cache size | Not a proof of minimum area; cut periphery and placement matter |
| One logical SRAM port per way | Avoids a multiported payload memory | Reads, stores, refills and write-backs must arbitrate for that port |
| Metadata in flipflops | Direct indexed tag access and parallel way comparisons | Flipflop area, clock/reset load and comparator/multiplexer growth |
| Full-word/capability overwrite on a hit | No old-record read is necessary | Incoming data must reach the correct SRAM slice within the clock period |
| Partial-store read-modify-write | Preserves untouched bytes with the existing ECC grouping | Extra read phase and SRAM-to-merge-to-encoder-to-SRAM timing path |
| ECC update without checking | Avoids cache-side syndrome comparisons, decoder and correction logic | Retains the stated two-input cancellation risk; no early error report |
| Combinational merge without another data register | Avoids an additional register stage and its latency | Longer combinational path; timing analysis may still require a stage |
| Direct SRAM read-hit response | Avoids a separate response-data register stage | SRAM/way/word selection and OBI routing must meet the clock period |
| Shared 80-bit store/read buffer | Retains both capability words without another record-sized buffer | Depends on blocking request ownership and correct SRAM-result capture |
| One-bit first-read-response flag | Allows a delayed second request without repeating the first response | Must be reset, armed and cleared correctly; no extra pipeline stage |
| Pure `function automatic` helper | Reuses the original code definition and synthesizes combinationally | Not zero-area software; repeated simultaneous calls may duplicate logic |
| No write buffer or overlapping misses initially | Smaller control state and simpler ordering | Blocking latency limits throughput |

At the defaults, metadata has 512 lines x (20 tag bits + valid + dirty) =
11,264 logical state bits, before replacement state or metadata protection.
These are declared-state dimensions, not a post-synthesis cell count; incomplete
or unconnected logic may be optimized away.

At fixed payload capacity and line size, increasing ways does not increase the
total number of lines, but does increase parallel comparisons and may widen
address tags because there are fewer sets. It also changes the SRAM partition
per way and can increase cut count or mux cost. Larger lines reduce line
metadata but fetch/write back more unused data on some workloads.

Packing eliminates unused bits, not all physical overhead. At 512 records per
way the packed design needs three cuts, whereas a padded 512 x 64 plus
512 x 32 mapping would use two. The packed mapping may therefore be larger or
smaller in actual area despite using fewer bits. Evaluate macro area,
surrounding logic, power and timing, not only bit utilization.

The wrapper's depth decomposition is generic within its supported constraints.
The cache now derives its number of wrappers, records per way and address/index
widths from the geometry, including one-way and single-set cases. Its parameter
checks restrict sweeps to supported combinations. Performance sweeps still need
the missing refill/write-back logic, SoC integration and functional verification.
The current 32-bit codec and 80-bit record are not automatic 64-bit CPU support.

### Geometry Elaboration Checks

A temporary pyslang 3.0.0 harness elaborated 37 legal cache configurations,
including capacities from 4 to 32 KiB, 16/32/64-byte lines, one/two/four ways,
single-set configurations, an eight-way case and a matching 64-bit address
interface with 32-bit data. Generated way counts, record depths, address widths
and exact macro storage capacities were checked against the requested geometry.
All 64 wrapper depths from 256 through 16,384 records in steps of 256 also
elaborated. Fourteen invalid cache configurations and five invalid wrapper
configurations were rejected with the expected parameter diagnostics.

This was an isolated structural check using the actual cache sources and ECC
package, with `tc_sram_impl` replaced by a port-compatible stub. It does not
verify SRAM behavior, hit responses, a full Bender/SoC build, synthesis, timing
or RTL simulation. The temporary harness is not a checked-in regression.

## Remaining Work and Verification Gates

The ordinary and capability read/store-hit paths now have source-level
datapaths and response sequencing. Isolated geometry elaboration has passed as
described above; interface behavior, timing and fault assumptions have not been
verified in simulation. Miss/refill and dirty eviction remain unimplemented.

Before functional cache testing:

- Build with the real SRAM implementation and test the implemented hit paths,
  including OBI timing, captured IDs and exactly one response per accepted
  request. Capability-read and capability-store completion use different flags
  and sequences.
- Verify the partial-store write strobes/dirty update and the assertion that
  excludes empty masks; define a hardware policy if such masks must be handled.
- Implement miss/refill, allocation, replacement and dirty
  write-back without exposing partially filled lines.
- Define initialization of encoded data/tag/ECC and protection of address tags,
  valid and dirty state. Payload ECC does not protect lookup metadata.
- Define the capability-pair input contract and conflicting JTAG/DMA accesses,
  plus I-cache/data-cache consistency and maintenance.
- Finalize and connect the shared data-plus-tag codec in the core and cache;
  remove the zero ECC and capability-access marker stubs.
- Register the modules with Bender and connect the cache only after focused
  module tests pass.

The geometry changes do not alter read/write FSM scheduling. No full SoC build
or RTL simulation has been run for these changes.

The regression should cover both stored-word halves, all nonempty byte masks,
unchanged neighboring words/packed slots, macro boundaries, saved read
selection, reset, capability halves with and without waiting, and correct
dirty/valid transitions. In particular, a delayed second capability-read request
must not cause a repeated lower-word response, and the upper-word response
must use the ID captured at its grant, not the live input ID. Verify SRAM output
holding while waiting. Check default and representative legal/illegal
geometries. Inject faults into each payload/ECC bit in either input, two faults
within one input, and equal/different syndromes across both inputs. Explicitly
test the documented silent-corruption limit rather than expecting every such
case to trap.

Only after functional and interface checks should SRAM macro area, metadata
area, maximum frequency, hit/miss latency, HyperBus burst behavior and workload
performance be compared across cache configurations.
