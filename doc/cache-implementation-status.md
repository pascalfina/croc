# Cache Implementation Status

Snapshot: 7 November 2026.

This document describes the in-progress data-cache sources, the SRAM design
decisions and the partial-store ECC update. It separates logic already present
in the files from intended behavior and missing integration. It is not an RTL
verification or timing sign-off.

The architectural target is in [Cache Design Constraints](cache-design-constraints.md).
The earlier HTML, SVG and PDF proposal is historical and does not describe this
implementation accurately.

## Source Map and Integration Status

| Source | Responsibility |
| --- | --- |
| [data_cache.sv](../rtl/cache/data_cache.sv) | OBI request capture, lookup and draft store-hit paths |
| [cache_pkg.sv](../rtl/cache/cache_pkg.sv) | Stored-word structs, record dimensions and partial-store ECC function |
| [cache_typedef.svh](../rtl/cache/cache_typedef.svh) | Instance-dependent address-tag, valid and dirty struct |
| [cache_data_sram.sv](../rtl/cache/cache_data_sram.sv) | Masked 80-bit SRAM interface and physical macro packing |
| [IHP SRAM implementation](../ihp13/tc_sram_impl.sv) | Technology-specific cuts and bit-mask connections |
| [Ibex SECDED package](../ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_secded_pkg.sv) | Original encoding function used by the ECC update |
| [Ibex load/store unit](../ibex/rtl/ibex_load_store_unit.sv) | Core byte-enable generation and existing data ECC encoder/checker |

Only the cache package is currently listed in the root Bender sources. The
data-cache and SRAM-wrapper module files are not, and no data-cache instance is
connected in the SoC. Two SRAM wrappers are instantiated inside the draft
data-cache module.

The core still has `MemECC = 0`. Its write-integrity output is not connected,
its read-integrity input is tied to zero, and the OBI request ECC and
`is_cap_store` fields are tied to zero in `croc_domain.sv`. These are integration
TODOs, not functional ECC or capability-store signaling. Existing HyperRAM
tests do not verify this new cache.

## Current Coverage

Here, "present" means source-level logic exists, not that the path has passed a
build or test.

| Case | Present in the source | Still missing or limited |
| --- | --- | --- |
| Request acceptance | `req && gnt` captures address, write flag, byte-enable, capability-store flag and first write word | Request ID capture and OBI completion |
| Set lookup | Valid/address-tag comparison across ways; selected way is retained | Miss handling, allocation, replacement and geometry assertions |
| Full 32-bit store hit | Places the buffered 40-bit word in the selected half and marks the line dirty | Correct partial/full-store guards and transition to an answer state |
| Capability store hit | Buffers the first word; accepts the second in lookup or a waiting state; writes all 80 bits | Complete pair contract, two OBI answers, core flag wiring and finished transitions |
| Byte/halfword store hit | Starts a read; selects the old word; merges enabled bytes and incoming tag; calls the ECC helper | SRAM write enable, dirty update and completion |
| ECC merge helper | `ecc_merge_partial32()` calls the original inverted Ibex encoder and is used in `ACCESS_SRAM` | End-to-end integration and tag protection are not implemented |
| Ordinary/capability reads | Request fields and SRAM interfaces exist | Read-hit datapath, tag/ECC forwarding and OBI response |
| Eviction/refill | Architectural write-back intent only | Dirty write-back, allocation, line reception and failure handling |
| I-cache/shared HyperBus arbiter | Architectural decisions only | RTL, routing, maintenance, coherence and burst integration |

All valid bits reset to zero. Since there is no refill path yet, the draft
cannot populate a valid line after reset. None of these store-hit paths is an
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

Two accepted OBI requests still require two correctly ordered responses and
their IDs. Writing both halves at one SRAM edge does not implement those
responses or provide system-wide atomicity against other memory paths.

### Byte and Halfword Store

A nonempty partial mask uses a read-modify-write path. This also covers a
partial bus request generated for a misaligned ordinary word access; it is not
restricted to instructions whose operand size is a byte or halfword.

1. On a lookup hit, save the way, request the old record with `sram_we = 0),
   leave dirty unchanged and enter `ACCESS_SRAM`.
2. In `ACCESS_SRAM`, select the lower or upper old 40-bit word using address
   bit 2. Start `merged_word` from that word.
3. For each enabled CPU byte, replace the corresponding payload byte with the
   saved incoming byte. Preserve all disabled bytes. Use the incoming saved tag.
4. Compute the ECC update described below, then place the complete resulting
   40-bit word into the selected SRAM half.
5. Write that half with the same five-byte mask used for full-word stores,
   mark the line dirty and complete the OBI transaction.

Step 4 is present: `ACCESS_SRAM` calls the helper before placing
`merged_word` on the write bus. Step 5 is incomplete: the partial-store state
does not yet assert SRAM write request or write enable, update dirty, or finish
the response sequence. Computing write data alone does not commit a write.

For an old word `0x11223344`, incoming data `0x0000AABB` and byte-enable
`0011`, the merged payload is `0x1122AABB`. The ECC of `0x0000AABB` alone
does not describe that result.

No extra register is required between the SRAM output and this merge. The
intended hit path uses one read phase followed by one merge/write phase: one
additional SRAM operation compared with a full-word hit. This is a scheduling
target, not a measured total OBI latency or a proven single-cycle timing path.

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
by 256, so both parts are exactly covered by the available cuts. These checks
are design requirements; elaboration assertions are not yet implemented.
`DataWidth` and `AddrWidth` are parameters, but fixed bit slices still restrict
the implementation to 80-bit records and a matching record-address width.

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
The complete cache is not yet sweep-ready: it still hard-codes two wrappers
and `NumWords = 512` instead of using the derived record count. One-way and
other geometries also need width/legality checks before they can be advertised.
The current 32-bit codec and 80-bit record are not automatic 64-bit CPU support.

## Remaining Work and Verification Gates

The current source still contains unfinished state assignments. Its store
guards use `1'b1111` where a four-bit constant is required, and the capability
assertion still refers to the old `CHACHE_LOOKUP` spelling. These must not be
mistaken for verified implementations of the intended paths above.

Before functional cache testing:

- Finish partial-store write strobes, dirty update and answer sequencing;
  define the zero-mask policy.
- Implement OBI response timing, request IDs and exactly one response per
  accepted request, including both halves of a capability transfer.
- Implement read hits, miss/refill, allocation, replacement and dirty
  write-back without exposing partially filled lines.
- Define initialization of encoded data/tag/ECC and protection of address tags,
  valid and dirty state. Payload ECC does not protect lookup metadata.
- Define the capability-pair input contract and conflicting JTAG/DMA accesses,
  plus I-cache/data-cache consistency and maintenance.
- Finalize and connect the shared data-plus-tag codec in the core and cache;
  remove the zero ECC and capability-store marker stubs.
- Register the modules with Bender and connect the cache only after focused
  module tests pass.

This documentation update changes no RTL and does not run builds or simulations.

The regression should cover both stored-word halves, all nonempty byte masks,
unchanged neighboring words/packed slots, macro boundaries, saved read
selection, reset, capability halves with and without waiting, and correct
dirty/valid transitions. Check default and representative legal/illegal
geometries. Inject faults into each payload/ECC bit in either input, two faults
within one input, and equal/different syndromes across both inputs. Explicitly
test the documented silent-corruption limit rather than expecting every such
case to trap.

Only after functional and interface checks should SRAM macro area, metadata
area, maximum frequency, hit/miss latency, HyperBus burst behavior and workload
performance be compared across cache configurations.
