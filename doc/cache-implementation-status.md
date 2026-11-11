# Cache Implementation Status

Snapshot: 8 November 2026.

The [instruction-cache section](#instruction-cache) was added on 10 November
2026 and includes the standalone verification results from 9 November. Other
sections retain their earlier D-cache/arbiter snapshot unless noted otherwise.

The [crossbar routing contract](cache-design-constraints.md#crossbar-routing-for-instruction-and-data-accesses)
was added on 10 November 2026: CPU instruction input 3 overrides the decoded
`XbarHyperbus` target with `XbarICache`; JTAG debug input 1 now overrides it with
`XbarJtagHyperram`. Register/peripheral routes stay unchanged. The
input-specific override is present in `obi_xbar.sv` and configured in
`croc_domain.sv`. Both caches and the JTAG adapter are wired to the shared
arbiter and listed in Bender. The adapter's rationale, posted-write barrier and
current verification boundary are documented in
[JTAG HyperRAM Adapter](jtag-hyperram-adapter.md). This integration update
supersedes older wiring limitations below; end-to-end firmware boot, ECC and
cache coherence remain separate work.

This document describes the in-progress data-cache sources, the read/store-hit
and refill/write-back paths, replacement state, SRAM design decisions and the
partial-store ECC update. The shared arbiter's current write path, port
selection and completion bridge are documented in
[Cache Memory Arbiter](cache-mem-arbiter.md). This document separates
logic already present in the files from intended behavior and missing
integration. It is not an RTL verification or timing sign-off.

The architectural target is in [Cache Design Constraints](cache-design-constraints.md).
The earlier HTML, SVG and PDF proposal is historical and does not describe this
implementation accurately.

## Source Map and Integration Status

| Source | Responsibility |
| --- | --- |
| [data_cache.sv](../rtl/cache/data_cache.sv) | OBI request capture, lookup, hit paths, refill/replacement control and FIFO-buffered dirty write-back |
| [instruction_cache.sv](../rtl/cache/instruction_cache.sv) | Read-only OBI instruction requests, SRAM lookup/read, full-line refill and replacement without write-back |
| [instruction_cache_param_checks.svh](../rtl/cache/instruction_cache_param_checks.svh) | I-cache geometry/interface checks and simulation-only fetch/refill assertions |
| [jtag_hyperram_adapter.sv](../rtl/cache/jtag_hyperram_adapter.sv) | Uncached JTAG OBI access, encoded-word buffering, masked commits, partial-write merging, readback and loader completion barrier |
| [jtag_hyperram_adapter_param_checks.svh](../rtl/cache/jtag_hyperram_adapter_param_checks.svh) | Adapter data/block/interface elaboration checks, included inside the module |
| [cache_mem_arbiter.sv](../rtl/cache/cache_mem_arbiter.sv) | Shared port ownership, round-robin handover, address expansion, masked write packing, read unpacking and final completion |
| [cache_pkg.sv](../rtl/cache/cache_pkg.sv) | Stored-word and line-stream structs, completion status, record dimensions and partial-store ECC function |
| [cache_typedef.svh](../rtl/cache/cache_typedef.svh) | Instance-dependent metadata, write-buffer and cache/arbiter command, request and response structs |
| [cache_data_sram.sv](../rtl/cache/cache_data_sram.sv) | Masked 80-bit SRAM interface and physical macro packing |
| [data_cache_param_checks.svh](../rtl/cache/data_cache_param_checks.svh) | Cache geometry/interface checks and simulation-only protocol/completion assertions |
| [cache_data_sram_param_checks.svh](../rtl/cache/cache_data_sram_param_checks.svh) | SRAM depth and width elaboration checks |
| [stream_fifo.sv](../rtl/common_cells/stream_fifo.sv), [fifo_v3.sv](../rtl/common_cells/fifo_v3.sv) | Existing register-based valid/ready FIFO used for write-back read-ahead |
| [IHP SRAM implementation](../ihp13/tc_sram_impl.sv) | Technology-specific cuts and bit-mask connections |
| [Ibex SECDED package](../ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_secded_pkg.sv) | Original encoding function used by the ECC update |
| [Ibex load/store unit](../ibex/rtl/ibex_load_store_unit.sv) | Core byte-enable generation and existing data ECC encoder/checker |
| [Ibex LSU protocol](../ibex/doc/03_reference/load_store_unit.rst) | Grant/response timing and split capability transfers |

The cache package, data-cache, instruction-cache, SRAM-wrapper, shared-arbiter
and JTAG-adapter module files are listed in the root Bender sources. In
`croc_domain.sv`, the caches occupy arbiter ports 0/1 and the adapter occupies
port 2. A generate loop instantiates one SRAM wrapper per way; the default
configuration still has two wrappers per cache.

The core still has `MemECC = 0`. Its write-integrity output and instruction/data
read-integrity inputs are now connected through `core_wrap` to the OBI ECC
fields. The direct TRVK bitmap response also carries ECC instead of a zero
tie-off. This is source-level integration, not a verified activation of ECC.
The capability-access marker travels from the LSU through `ibex_core`, `ibex_top` and TRVK to
`core_wrap.data_is_cap_access_o`, connected directly to the OBI request's
`a_optional.is_cap_access` field. It marks both words of capability loads and
stores, independently of the capability-validity tag. Ordinary accesses,
including split misaligned word accesses, have marker zero. This adds no
pipeline stage. Existing HyperRAM tests do not verify this new cache.

## Current Coverage

Here, "present" means source-level logic exists, not that the path has passed a
build or test.

| Case | Present in the source | Still missing or limited |
| --- | --- | --- |
| Request acceptance | `req && gnt` captures address, write flag, byte-enable, capability-access flag, ID and first write word | Verify response accounting and the capability-pair input contract |
| Set lookup | Valid/address-tag comparison across all ways; a miss is decided after the scan; invalid ways are preferred over the set's round-robin candidate | Functional verification and integration |
| Full 32-bit store hit | Places the buffered 40-bit word in the selected half, marks dirty and answers in the SRAM-write cycle | RTL verification and end-to-end ECC wiring |
| Capability store hit | Buffers both words, writes all 80 bits, captures the second request ID in both receive paths and answers once in the write cycle and once in `IDLE` using `cap_flag_q` | Pair-contract enforcement, SoC integration and regression of distinct IDs in both receive paths |
| Byte/halfword store hit | Reads the old word, merges bytes/tag/ECC, writes the selected half, marks dirty and answers | RTL verification; empty masks are excluded by a simulation assertion, not a hardware no-op policy |
| ECC merge helper | `ecc_merge_partial32()` uses the shared data-plus-tag codec in `ACCESS_SRAM`, including the old tag in its unused term | End-to-end integration and regression of the tag-aware update remain open |
| Ordinary read hit | Reads one record, selects one stored word and returns data, stored tag/ECC and the saved ID | RTL verification and core ECC wiring |
| Capability read hit | Reuses the 80-bit store buffer; sends one response per accepted half; an extra flag prevents repeated first responses | RTL verification, SRAM output-hold validation during waiting, pair-contract enforcement and SoC integration |
| Refill | Command handshake, full-record SRAM writes, record index, completion wait, metadata installation and lookup replay; an assertion stops on an accepted error completion | Shared transfer engine, actual error/abort recovery, record-count/`last` verification and functional tests |
| Dirty write-back | Old-line command, synchronous SRAM reads, parameterized fall-through FIFO, read-ahead capacity check, last-record handshake and separate completion wait | Shared packing/HyperBus engine, actual error recovery, FIFO area/performance evaluation and RTL tests |
| Replacement/eviction | Per-set round-robin pointers reset to zero and advance after successful refill; dirty victims use the write-back states before refill | Functional tests and local/global policy comparison |
| Shared HyperBus arbiter | Command selection, whole-operation ownership, round-robin handover, write packing and completion forwarding | Read path, complete interface guards, competing-port RTL tests, actual midend/HyperRAM tests and SoC integration; see [module documentation](cache-mem-arbiter.md) |
| I-cache | Read-hit, full-line refill, invalid-way preference, per-set round-robin, captured OBI ID and stored ECC transport; standalone regression passed | SoC routing, core ECC wiring, hardware error recovery, invalidation and instruction/data consistency; see [I-cache details](#instruction-cache) |

All valid bits reset to zero. The draft refill success path can now install a
valid line at source level. The shared write path now has an implementation
exercised in isolation, but its read counterpart and SoC connection remain
missing.
These modules do not yet form an end-to-end runnable, verified cached SoC.

## Instruction Cache

Updated: 10 November 2026.

The external I-cache reuses the D-cache's geometry, metadata lookup, masked
`cache_data_sram` wrapper, complete-line memory interface and refill/replay
sequence. It accepts word-aligned 32-bit OBI reads and captures the request
address and ID. The internal Ibex I-cache stays disabled.

Current defaults are 8 KiB of usable payload, 16 logical bytes per line and two
ways. Each 80-bit SRAM record holds two 32-bit payload words with their stored
ECC and capability tags. Thus, a default line contains two records: 16 logical
bytes in 20 stored bytes. Instructions use the same backing format as data;
fetch does not interpret the capability tags as execution permission. On the
OBI response, the cache removes the stored tag's parity contribution with
`stored_ecc ^ ({7{stored_tag}} & ibex_mem_ecc_pkg::MemEccTagSyndrome)` and returns
tag zero. This preserves the original fault syndrome while allowing the
existing 32-data-bit Ibex instruction checker to remain unchanged. Stored
records are not modified, and no instruction-tag input or extra cycle is needed.

The I-cache never modifies instructions. It therefore needs no dirty tracking,
write-back states or write-back FIFO: evicting a line only discards a copy of
data already held in HyperRAM. The shared metadata typedef currently retains
an unused `dirty` field. Writing received refill records into the local SRAM
does not constitute a HyperRAM write.

### Read and Refill Sequence

| State | Responsibility |
| --- | --- |
| `IDLE` | Assert OBI grant; capture address and ID on `req && gnt` |
| `CACHE_LOOKUP` | Compare valid/address tags in the indexed set; on a hit, select the way and issue the SRAM read; on a miss, prefer an invalid way, otherwise use the set's round-robin candidate |
| `ACCESS_SRAM` | Return the selected 32-bit word, ECC with the tag contribution removed, tag zero and captured ID with one OBI response, then return to `IDLE` |
| `SEND_REFILL_CMD` | Hold a line-aligned read command and `RecordsPerLine` until command acceptance |
| `WAIT_REFILL_DATA` | Write each accepted 80-bit record into the selected way at `set * RecordsPerLine + record_index`; advance only on handshake |
| `WAIT_REFILL_DONE` | On successful completion, install the address tag and valid bit, advance the replacement pointer with wrap and return to lookup to replay the pending request |

The cache is blocking and assumes OBI without response backpressure, matching
the current `UseRReady = 0` configuration. The SRAM read is requested during
lookup; its one-cycle-latency output is used directly in `ACCESS_SRAM`, without
an additional result register. Tested hits respond two clocks after request
acceptance. The current FSM accepts continuous all-hit traffic once every three
clocks, not one request per clock.

### Code Changes and Invalidation

Suppose the instruction at `0x80001000` is already resident in the I-cache.
If that instruction is later replaced in backing memory, for example through
JTAG, the I-cache does not detect the write. A subsequent hit still returns
the old instruction from its SRAM copy.

**Invalidation means marking the affected cache entry as invalid**, by clearing
its valid bit. The next fetch then misses and loads the new instruction from
HyperRAM. No I-cache write-back is needed: invalidation discards the old copy
rather than writing it over the new code.

There is currently no invalidation or maintenance interface. Initial bring-up
therefore assumes the program is loaded before CPU start and remains unchanged
afterwards. For later code changes through the write-back D-cache, the order
must be: write the modified code back to HyperRAM, invalidate the affected
I-cache entries, then fetch the modified code. A general `FENCE.I`/debug/DMA
consistency mechanism remains to be designed and connected; disabling the
internal Ibex I-cache does not provide invalidation for this external cache.

### Assertions and Standalone Verification

`instruction_cache_param_checks.svh` is included in the module scope. It checks
geometry and interface widths, read-only and word-aligned accepted fetches,
refill `last` against the record count, and early/final refill errors. Enable
Verilator `--assert` to execute concurrent assertions. The current error policy
is simulation fail-fast, not hardware recovery: without assertions, an accepted
error completion leaves the unfinished error branch waiting indefinitely.

For the actual IHP SRAM mapping, Verilator 5.042 requires the tested
`--unroll-count 64 --unroll-stmts 1` settings. Count 1 fails while elaborating
the 64-bit write-mask generate loop. This changes a simulator elaboration limit,
not the hardware or the cache's cycle count.

Standalone tests live outside Croc in the sibling `../croc-icache-tests`
directory, alongside the D-cache and arbiter suites. The final matrix and
stress run passed 102 functional simulations with 1,093,830 checked OBI fetch
responses. Coverage includes generic/IHP SRAMs, 14 configurations, both record
halves, ECC/tag/ID transport, replacement, long stalls, continuous requests and
coordinated reset. Six injected faults triggered their expected assertion;
eleven invalid configurations produced their parameter diagnostic. The local
README and `REVIEW-2026-11-09.md` contain commands, logs and exact source hashes.

These are cache unit tests with a memory-stream responder, not a complete
Ibex/crossbar/arbiter/HyperBus/HyperRAM simulation. At that tested revision ECC
was transported unchanged. The instruction-response ECC adaptation above was
added later and is not covered by that run. Core checking/correction and
protection of the capability tag are not verified by these tests. SoC
integration and cache-maintenance behavior remain open.

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

The shared `ibex_mem_ecc_pkg` codec protects each word's 32 payload bits plus
tag with seven ECC bits. The partial-store helper uses this codec as well.
End-to-end activation still requires consistent wiring and encoding on every
response path; `MemECC` remains disabled.

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
by ten. HyperRAM byte serialization is a separate layer, implemented for writes
in the [shared arbiter](cache-mem-arbiter.md#logical-addresses-and-physical-transfers).

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
needed for the elaboration checks. The same data-cache header now contains
the simulation-only protocol and completion assertions; it is included after
the module declarations and instances. Enable assertion evaluation in the
simulator to execute them. They are excluded from synthesis with
`translate_off/on`; elaborating them alone does not test a failure report.

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
request. Both `CACHE_LOOKUP` and `WAIT_FOR_SECOND_WORD` now capture the second
request ID in `obi_aid_d`: the first response still uses the previous
`obi_aid_q`, and the following `IDLE` response uses the newly captured ID.
Different IDs no longer depend on the same-core-ID assumption at source
level. Regress both immediate and delayed second requests with distinct IDs;
capturing response IDs does not itself enforce capability-pair ownership.
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
store-only second-address assertion.

### Deferred: Capability-Pair Contract Before Sharing the Cache Input

The initial contract is an exclusive Ibex data-port input with correctly
paired capability requests. Before allowing JTAG, DMA or another bus master
to share the data-cache OBI input, enforce ownership across both halves.
The crossbar arbitrates individual requests; it does not automatically reserve
the next granted request for the owner of a capability's first half.

For example, after accepting a capability-store first half at `A`, the cache
could accept another master's ordinary read at `A + 4` as the upper store
half. The current receive logic copies its `wdata`, ECC and tag fields without
checking that it is a matching capability write. The existing address-only
assertion passes because the address is correct, even though a read's write
data is not valid store payload. Correctly paired, exclusive Ibex data traffic
does not trigger this case. A separate I-cache competing at the downstream
memory arbiter is not another requester at this OBI input.

Follow-up work must cover first-address alignment, second address `A + 4`,
matching read/write direction and capability marker, supported byte masks and
requester ownership for both capability loads and stores. Requester ownership
must not be confused with equal transaction IDs: the two halves may have
different IDs and still belong to the same requester. Preserve the exclusive
input or prevent interleaving with explicit pair-aware arbitration; assertions
alone diagnose violations in simulation, not prevent them in hardware. Add
tests with competing requesters and malformed second halves before enabling
shared-input operation. This contract is deferred, not implemented here.

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

## Line-Transfer Interface

The cache now has `mem_req_t` / `mem_rsp_t` type parameters and `mem_req_o` /
`mem_rsp_i` ports. These are protocol-neutral, complete-line transfers to the
shared arbiter. They are not OBI requests or direct HyperBus commands.
`mem_req_o = '0` supplies combinational defaults. Refill and write-back states
override their command, stream and completion fields. The shared arbiter now
includes write packing and the midend host-command/completion path; read
unpacking and integration remain unfinished. See
[Cache Memory Arbiter](cache-mem-arbiter.md) for the implemented state sequence.
The existing hit paths are reused after a successful refill.

`cache_pkg::cache_mem_data_t` contains a complete `cap_store_t record` plus a
one-bit `last`. The record preserves both payload words, tags and stored ECC.
`cache_pkg::cache_mem_done_t` contains one error bit. The parameterized macros
in `cache_typedef.svh` construct the command and outer packets:

| Packet | Field | Meaning |
| --- | --- | --- |
| `cache_mem_req_t` | `cmd_valid`, `cmd` | Offer one complete-line operation |
| `cmd` | `write` | Zero for refill; one for dirty-line write-back |
| `cmd` | `line_addr` | Aligned logical byte address, before encoded HyperRAM mapping |
| `cmd` | `records` | Exact number of complete 80-bit records, not a last index or host-beat count |
| `cache_mem_req_t` | `w_valid`, `w.record`, `w.last` | Write-back stream in increasing record order |
| `cache_mem_req_t` | `r_ready` | Cache can accept a refill record |
| `cache_mem_req_t` | `done_ready` | Cache can accept the final operation status |
| `cache_mem_rsp_t` | `cmd_ready` | Arbiter can accept the offered command |
| `cache_mem_rsp_t` | `w_ready` | Transfer path can accept a write-back record |
| `cache_mem_rsp_t` | `r_valid`, `r.record`, `r.last` | Refill stream in increasing record order |
| `cache_mem_rsp_t` | `done_valid`, `done.error` | Final success/failure status for the complete operation |

Each channel transfers only at a clock edge with its valid and ready both high.
The producer holds valid and its payload stable until that handshake. Record
`last` marks the end of the complete line, not the end of each HyperBus burst.
No record byte mask is needed: write-back and refill transfer complete records.

The planned completion contract distinguishes data acceptance from operation
success. A successful refill completes only after all expected records have
been accepted and committed to SRAM. A write-back completes only after the
HyperBus write responses for all issued bursts have arrived. A failed operation
may complete before all line records have been transferred, but only after
issued transport activity is drained. The miss FSM must accept an error
completion while waiting for data, rather than waiting indefinitely for a
missing final record. It must not validate a partial refill or discard dirty
victim data on failure. These rules are interface requirements for the future
implementation. The current cache handles the success sequence and asserts
against an accepted error completion in either completion-wait state. This is
not hardware recovery, and it does not cover an early abort: `WAIT_REFILL_DATA`
and `WRITE_BACK_DATA` do not accept completion status. Before integration,
either extend the cache for that early-error contract or require the transfer
engine to finish the expected record stream before returning failure. These
are future-engine requirements, not a claim that the existing HyperBus midend
spontaneously stops returning read data.

Create matching types in the future enclosing cache/arbiter scope, for example:

```systemverilog
`include "cache_typedef.svh"
localparam int unsigned MaxLineRecords = MaxLineDataBytes / cache_pkg::CacheRecordDataBytes;
localparam int unsigned RecordCountWidth = (MaxLineRecords > 0) ? $clog2(MaxLineRecords + 1) : 1;
`CACHE_TYPEDEF_MEM_ALL(cache_mem, AddrWidth, RecordCountWidth)
```

`MaxLineDataBytes` is the larger of the configured instruction/data line sizes
in that enclosing scope; it is not a new data-cache parameter. This produces
`cache_mem_cmd_t`, `cache_mem_req_t` and `cache_mem_rsp_t`. Pass the latter two
as `.mem_req_t(cache_mem_req_t)` and `.mem_rsp_t(cache_mem_rsp_t)`. A common
record-count width may be wider than one cache needs. Data-cache elaboration
checks enforce matching address/data/handshake widths and enough count bits
to represent its complete line.

A logical 64-byte line has `cmd.records = 8`, requiring at least four count
bits. It becomes 20 physical 32-bit host beats only in the shared packing and
transfer logic. The current arbiter issues one host command for the complete
line; it has no `MaxBurstBeats` cap or arbiter-side segmentation. Configured
lines must fit the midend's supported transfer limits. The arbiter retains its
selected owner until the complete line operation's completion handshake. No
transaction ID is included because the initial interface allows only one
outstanding operation per cache and one selected shared owner.

## Miss, Refill and Replacement Control

### Miss Detection and Victim Selection

`CACHE_LOOKUP` sets `hit_found` when any valid way in the indexed set matches
the saved request's address tag. The miss decision is made after checking all
ways, not in an individual way's mismatch branch.

On a miss, `selected_way_d` first takes `replace_way_q[set_index]` as its
fallback. The scan then selects the first invalid way if one exists;
`all_valid` prevents later invalid ways from replacing that selection. A valid
dirty victim must be written back first. An invalid or clean victim can go
directly to refill. This decision uses `selected_way_d`, because the selection
does not reach `selected_way_q` until the next clock edge.

Dirty misses now enter the write-back states described below. The command uses
the victim's stored address tag and the current set index, not the new saved
OBI request's tag. Refill subsequently uses the new saved OBI address. Both
paths have source-level success handling, but the shared transfer engine and
end-to-end verification are still missing.

### Refill State Sequence

| State | Current success-path behavior |
| --- | --- |
| `SEND_REFILL_CMD` | Offer `cmd.write = 0`, the saved OBI address with its lower `OffsetBits` cleared, and `cmd.records = RecordsPerLine`. Hold the command and `cmd_valid` until `cmd_ready`. On acceptance, reset `line_record_index_d` to zero and enter `WAIT_REFILL_DATA`. |
| `WAIT_REFILL_DATA` | Assert `r_ready`. Each `r_valid && r_ready` handshake writes `r.record` directly to the selected way's SRAM with all ten storage-byte enables active. Increment the index after nonfinal records; after accepting the expected final record, enter `WAIT_REFILL_DONE`. |
| `WAIT_REFILL_DONE` | Assert `done_ready` and wait for `done_valid`. On success, install the new address tag, set valid, clear dirty, advance this set's replacement pointer and return to `CACHE_LOOKUP`. An accepted error triggers a simulation assertion; hardware recovery is not implemented. |

`cmd.records` is the requested count; `line_record_index_q` is a zero-based
index of the next record to receive. They are different quantities. The
internal index starts at zero for every accepted refill command and advances
only on a data handshake. With the default 16-byte logical line, indices zero
and one select its two 80-bit records.

`r_valid` is not a one-cycle pulse contract. It may stay high for consecutive
records when the receiver remains ready. With valid high and ready low, the
producer must retain the same record. Detect completion inside the handshake
that actually accepts the final record, not merely when the counter has
reached its last index. The source currently uses this count to terminate
reception; `r.last` exists in the stream struct but is not checked. A simulation
assertion comparing `r.last` with the expected final index is a possible
follow-up without adding a hardware wait state.

The SRAM address is a combinational selection, not a new address register:

```text
Hit/default: SetIndex * RecordsPerLine + floor(BlockOffset / RecordDataBytes)
Refill:      SetIndex * RecordsPerLine + line_record_index_q
```

The default expression remains at the start of `always_comb`; the accepted
refill record overrides it in `WAIT_REFILL_DATA`. Use the current `_q` index
for the write address, not the incremented `_d` value. The wrapper addresses
complete 80-bit records, so the refill index is not multiplied by eight or
ten. No extra SRAM-address pipeline cycle is introduced.

### Metadata Installation and Request Replay

The refill does not overwrite the saved OBI address, byte-enable, direction,
capability-access marker, ID or buffered incoming store word. In particular,
incoming refill records go straight to SRAM rather than through `cap_store_q`,
which may still hold the original store's first word.

Only after the full line has been stored and a successful completion accepted
does the selected metadata entry receive `addr_tag` from the saved OBI address,
`valid = 1` and `dirty = 0`. This is the cache address tag, not either
capability tag inside the record. These metadata updates and the state change
commit at the same edge. In the following `CACHE_LOOKUP`, the original request
hits the newly installed line and reuses the existing ordinary/capability
read or store path. It is not accepted a second time through `IDLE`.

This is write-allocate: a store miss also fetches the complete line before
replaying the store, whose hit path then marks it dirty. Skipping a record
that will be overwritten is not implemented. A 32-bit or partial store still
needs untouched data from its record; even a complete capability overwrite
would require both words to be buffered and the transfer/packing contract to
support omitting that record. Extra command boundaries could offset the saved
bytes.

### Separate Completion Wait: Initial Baseline and Measurement

Keep `WAIT_REFILL_DONE` for the first implementation. The current interface
separates the accepted data stream from final operation status; receiving the
expected number of records alone does not establish that `done.error` is zero.
The producer must hold completion valid and status until the cache accepts it.

If completion is available on entry, this state occupies one cycle after the
last record write. If it arrives later, the wait can be multiple cycles.
Hit-path scheduling is unchanged. For an otherwise `N`-cycle miss, one extra
cycle adds `1 / N` to that miss's latency: 1% at 100 cycles, 0.5% at 200 and
0.2% at 500. These are arithmetic examples, not measured HyperRAM latencies
or predictions of whole-program slowdown. Retaining the shared arbiter owner
while waiting can also delay the other cache.

Measure total miss latency, cycles spent in this state, completion availability
relative to the last record, shared-owner blocking and total workload cycles
before deciding whether this separation is worth optimizing. A future design
could accept the final record and successful completion together and install
metadata at that edge, avoiding a separate success-path wait. That requires
compatible producer/consumer handshakes, error handling, timing and arbiter
ownership release; it is not achieved by simply dropping the completion
check. Counter-only read completion would be a different interface contract,
not the current baseline.

Error recovery remains open: with assertion evaluation enabled, an accepted
error in `WAIT_REFILL_DONE` triggers `assert_refill_success` and stops simulation
with `$fatal`, reporting set and way. The synthesis-excluded assertion adds no
hardware recovery. Without it,
the state consumes an error completion but has no invalidation, OBI-error
response or exit for that case.
An earlier error completion is not accepted while waiting for records and can
leave the draft waiting indefinitely if the remaining records never arrive.
A failed partial refill must not leave the victim usable under its old tag.
Keeping the done state is therefore not a claim of completed error handling.

## Dirty Write-Back Control Flow

### Victim Ownership and Command

Write-back is needed only for a valid dirty victim. Keep the selected way,
its old metadata and the original pending OBI request unchanged while it is
active. No new OBI request is granted, no write-back SRAM operation modifies
the line, and buffered incoming store data remains in `cap_store_q`. Write-back
reads all records from the victim, independently of the pending access offset.

The line command carries `write = 1` and `records = RecordsPerLine`. Its
logical byte address is the old metadata address tag followed by the actual
set bits and zero line-offset bits. With `NumSets = 1`, omit the set field:
`set_index` still has a one-bit storage type but must not contribute an extra
address bit. Refill does not have that issue because it aligns the saved OBI
address directly. Logical-to-physical encoded mapping is the shared engine's
job, not this command's.

| State | Current success-path behavior |
| --- | --- |
| `SEND_WRITEBACK_CMD` | Hold the victim-line command and `cmd_valid` stable until `cmd_ready`. At the command handshake, issue the SRAM read for record 0, mark its pending result and set the next read index to 1. Enter `WRITE_BACK_DATA`. |
| `WRITE_BACK_DATA` | Feed returning SRAM records into the FIFO and present its output to the memory path. Issue another SRAM read only when the conservative capacity test passes and the last read has not been issued. On the handshake of the FIFO output with `last = 1`, enter `WAIT_WRITEBACK_DONE`. |
| `WAIT_WRITEBACK_DONE` | Assert `done_ready`, issue no SRAM read or write-data transfer, and wait for `done_valid`. On success enter `SEND_REFILL_CMD`; an accepted error triggers `assert_writeback_success`. |

Sending the last record is not confirmation that HyperRAM has been updated.
The future shared engine may still be buffering or serializing records and
must collect all required HyperBus write responses before reporting success.
It must retain completion status until the cache accepts it. Only then may
the cache start the replacement refill. The arbiter may serve the I-cache
between these two complete operations; the write-back FIFO does not control
shared ownership or burst segmentation.

The current code leaves the victim's dirty bit unchanged even at successful
write-back completion. Refill installation later replaces its address tag and
clears dirty. The cache remains blocked in between. No OBI response is generated
by write-back itself: the original request completes through the hit path after
refill. Recovery after a failed or partially stored refill is still open.

### SRAM Read Results and the Two Last Markers

The SRAM has one synchronous read cycle and no result-valid output. A started
write-back read sets `wb_read_valid_d`; `wb_read_valid_q` marks its result in
the following cycle. Likewise, `wb_read_last_d` is computed from the index of
the read being issued, and `wb_read_last_q` accompanies that returned record.
The first command-handshake read is record 0, not the next-index value 1.

In write-back, `line_record_index_q` identifies the next SRAM read to issue.
Increment it only when issuing that read. In refill the same register instead
identifies the next incoming record to store. These uses do not overlap.

After the last SRAM read, `wb_read_last_q` stays high because its default
next value holds it. This blocks further reads even if the index wraps or the
FIFO still has space. The next accepted write-back command reinitializes that
marker for its first read. Do not clear it merely when one FIFO input is accepted.

The FIFO stores each record's `last` together with its data. These markers
serve two different points in the pipeline:

| Marker | Meaning and use |
| --- | --- |
| `wb_read_last_q` | The last SRAM read has returned; stop issuing additional reads. |
| `wb_fifo_out.last` with output valid/ready | The last queued record was accepted by the memory path; finish the send phase. |

The last SRAM result can arrive while an older record is at the FIFO head.
Stopping reads must not wait for that last record to reach the output, and
finishing the send phase must not happen merely because it entered the FIFO.

### FIFO Handshakes and Fall-Through

The cache instantiates the existing `stream_fifo`/`fifo_v3`, not a new custom
queue. `WritebackFifoDepth` defaults to 2. Each entry is one 80-bit encoded
record plus its one-bit `last`: 81 bits, not 80 payload bits and not a 32-bit
HyperBus beat. The marker is internal control and is not serialized into the
80-bit backing record.

The input is the selected way's SRAM result, `wb_read_last_q`, and
`wb_read_valid_q`. In `WRITE_BACK_DATA`, the output connections are:

| Connection | Responsibility |
| --- | --- |
| `mem_req_o.w_valid = wb_fifo_out_valid` | Advertise a record independently of downstream readiness. |
| `mem_req_o.w = wb_fifo_out` | Keep the offered record and its marker present while waiting. |
| `wb_fifo_out_ready = mem_rsp_i.w_ready` | Return the memory path's readiness so the FIFO advances on the same handshake. |

FIFO output readiness defaults to zero outside this state. Internally, the
FIFO removes an entry only on `ready && valid`; high readiness with no valid
output does not remove anything. The cache's output-handshake `if` observes
that same transfer to check `last`; it does not perform a separate data copy.

With `FALL_THROUGH = 1`, an empty FIFO can present a valid SRAM result at its
output in the same cycle. If the memory path is ready, it passes through with
no extra FIFO register cycle. Otherwise it is stored at the edge. Older queued
records always come first. The SRAM read cycle still exists, and the direct
path adds combinational mux/control delay that must be checked in timing.

### Read-Ahead Capacity and Supported Depths

A synchronous SRAM result cannot be backpressured after its read is issued.
Reserve space before issuing the request; testing only the FIFO's current
input readiness would ignore the result already arriving that cycle.

The current conservative read-enable condition is:

```systemverilog
int'(wb_fifo_usage) + 1 < WritebackFifoDepth &&
wb_fifo_in_ready && !wb_read_last_q
```

The extra one reserves capacity for the arriving result, even on cycles
without a valid pending result. `wb_fifo_in_ready` also rejects a full FIFO:
the FIFO's truncated usage output wraps to zero at full power-of-two depths.
For example, with depth 2, one stored record plus one arriving record prevents
another read. This policy does not subtract a simultaneous output transfer,
so it may pause SRAM reads unnecessarily and must not be described as the
maximum-throughput scheduling policy.

This control requires `WritebackFifoDepth >= 2`. The parameter currently has
no cache-side lower-bound check; depth 1 can block after the first read, and
depth 0 is not a supported way to disable the FIFO. Add that elaboration guard
before exposing FIFO-depth sweeps. A no-FIFO comparison needs a separate
correct handshake implementation, not simply a depth-zero parameter.

No finite FIFO allows unlimited SRAM read-ahead through an arbitrarily long
downstream stall. A full queue must stop new reads. The FIFO is assumed empty
at a new write-back; after a correct last-output handshake, no queued or pending
record may remain to leak into the next operation. Reset clears its control
and contents, but coordinated reset of an outstanding memory operation remains
an integration requirement.

### FIFO Area Versus Performance: Measurement Required

The FIFO is a performance hypothesis, not a proven necessary or area-optimal
component. Its RTL uses register storage: depth 2 declares 162 entry bits,
depth 4 declares 324, and depth 8 declares 648, plus read/write pointers,
occupancy state, muxes and control. The two delayed SRAM-result flags add two
state bits; the existing line index is shared with refill. These are logical
state counts, not synthesized flipflop counts or physical area estimates.

Buffering can hide short downstream stalls by reading subsequent SRAM records
before older records are consumed. It cannot accelerate the physical HyperBus
data rate, make a long stall disappear, or guarantee `w_ready` every cycle.
The midend already has a host-write FIFO, and a separate packer may need
storage too; evaluate the whole buffering chain before retaining redundant
queues. This write-back FIFO does not make the cache nonblocking.

Compare supported depths such as 2, 4 and 8 against a deliberately implemented
no-FIFO baseline using the SRAM output as a held one-record source. Such a
source can also sustain one record per cycle with continuous readiness if
read/consume scheduling is correct; the FIFO's intended advantage is read-ahead
under variable readiness, not an automatic doubling of peak throughput.
Keep cache geometry, packing, burst limits, clocks and workloads identical.

| Measure | Decision it supports |
| --- | --- |
| Mapped standard-cell area, register count and routing/timing | Physical cost of each depth and of fall-through versus registered output |
| Occupancy distribution, peak use and time spent full | Whether additional entries are actually used |
| SRAM-read pause cycles, including conservative-rule bubbles | Whether queue depth or the read-enable policy limits progress |
| Memory-path ready cycles without a valid record during an active write-back | Whether the FIFO reduces downstream data starvation |
| Write-back latency, physical HyperBus utilization and actual burst gaps | Whether earlier SRAM reads improve transport rather than only moving waiting elsewhere |
| Dirty-eviction count, miss stall cycles and workload runtime | End-to-end benefit relative to area, including I-cache contention |

Retain or deepen the FIFO only if measurements justify its cost. If depth 2
is sufficient, larger queues waste area; if the simpler no-FIFO source performs
equally well, removing this queue is a valid optimization. No such comparison,
synthesis result or integrated cache benchmark exists at this snapshot.

## Local Round-Robin Pointers and Area Trade-Off

Each set has its own `replace_way_q` candidate. After a successful refill,
the next candidate is `selected_way_q + 1`, except that the last way wraps
explicitly to zero. Other sets retain their candidates. This also keeps the
pointer at zero for `NumWays = 1`, where the minimum one-bit index type would
make unchecked overflow unsuitable. Hits and failed refills do not advance
the pointer. Invalid-way preference still takes priority over the candidate.

For two ways, successful installation in way zero makes way one the next
candidate; installation in way one makes way zero next. This prevents every
full-set replacement from always selecting the same fixed way. It is not LRU:
the policy does not record which line was most recently hit, and better miss
rates are not guaranteed for every workload.

For more than one way, the local state is
`NumSets * ceil(log2(NumWays))` bits. With the current 8 KiB / 16-byte / two-way
defaults, that is 256 bits, nominally 256 flipflops before synthesis
optimization. At the same capacity and ways with 64-byte lines, it is 64 bits.
`replace_way_d` is combinational next-state logic, not another storage array.
A one-way cache needs no meaningful replacement state; its declared pointer
is constant zero in the functional policy and may be optimized away.

An alternative is one global round-robin pointer per cache, shared by all its
sets. With two ways this needs one stored bit rather than 256 at the current
defaults, but requests to other sets then influence a set's next victim.
For example, alternating misses in two full sets can repeatedly select the
same way in each set despite the global pointer alternating. Local pointers
avoid that cross-set dependence. Neither policy is an established area or
performance optimum, and the global alternative is not implemented yet.

Keep local pointers as the initial baseline, then compare local and global
replacement at identical cache capacity, line size, ways and workloads.
Measure miss rate, dirty evictions, HyperBus traffic, stall/runtime cycles,
standard-cell area, clock/reset load and timing. Flipflop bits are not directly
comparable to SRAM bits in physical area. This replacement decision is
separate from round-robin arbitration between the I-cache and D-cache.

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

`ecc_merge_partial32()` calls `ibex_mem_ecc_pkg::mem_ecc_encode()`, shared with
the Ibex LSU write path. This codec extends the original inverted 39/32 matrix
with the capability-tag column `7'h43`. There is no copied data parity matrix
or substitution of a different Hamming code just because its width matches.

The output contains 32 payload bits, one tag and seven ECC bits; the helper
extracts bits [39:33]. For tag zero, ECC matches the original encoder,
including `7'h2A` for zero data. All other producers and response paths must
use the same contract before `MemECC` is enabled.

### MMIO and Bitmap Response Integrity

`croc_pkg::mmio_rsp_with_ecc()` copies a subordinate response and supplies ECC
for its actual 32-bit response data with tag zero. It changes no grant, valid,
ID, error or payload fields and adds no registers or protocol states.
`croc_domain.sv` applies it before the peripheral demultiplexer to SoC control,
UART, GPIO, timer, CLINT, iDMA configuration, debug memory and HyperBus
configuration responses. Peripheral and main-crossbar error responders are
covered too. The current user-domain error responders use the same helper.
This covers reads, store acknowledgements and error response payloads alike.

Boot-ROM responses already generate their ECC locally and bypass the helper.
I-cache, D-cache and JTAG memory responses also bypass it: their stored ECC
must not be regenerated from observed read data. A future user-domain encoded
memory must likewise return its own ECC instead of using this MMIO helper.

`revc_bitmap_memory.sv` encodes both registered response words with tag zero.
Its new `data_rdata_intg_o` output connects to the bitmap's OBI response; its
`trvk_revbm_rdata_intg_o` output reaches `ibex_top` through `croc_domain` and
`core_wrap`. Tag-zero encoding remains compatible with TRVK's existing
32-data-bit bitmap checker. Response latency and bitmap arbitration are
unchanged, and no bitmap ECC storage or extra flipflops were added.

These encoders protect response transfers only from their encoding boundary.
They do not detect corruption of peripheral registers, bitmap storage or
bitmap response registers before encoding, and do not validate write-request
ECC. Protecting stored bitmap state requires a separate stored-ECC or parity
design. These integration changes have not been built or simulated;
`MemECC` remains disabled.

### DMA Write Integrity

At the DMA manager boundary in `croc_domain.sv`, the shared codec encodes the
final `idma_obi_write_req.a.wdata` with tag zero. The crossbar request keeps
the existing data, address, byte enables, ID and handshake; only its optional
fields are supplied with ECC, tag zero and `is_cap_access = 0`. The generic
DMA backend is unchanged. Partial stores use the D-cache's existing ECC merge,
and no additional pipeline stage or buffer is introduced.

This is write-side encoding, not DMA source validation: the DMA still does
not check read-response ECC or preserve it through its byte buffer. A faulty
source can therefore receive fresh, consistent ECC when copied. End-to-end
DMA read integrity requires a separate checking/error-handling design.

The data-integrity alert assertion in `ibex_top.sv` now uses the shared
40-bit decoder with the tag and response data after TRVK, matching the LSU.
The instruction-integrity assertion retains its 32-data-bit decoder, matching
the I-cache response adaptation. Neither change has been built or simulated.

### Merge Equation

Let `O` be the observed old 32-bit payload, `N` the incoming payload, and
`eO` and `eN` their supplied ECC fields. Their tags are `tO` and `tN`.
Let `E(data, tag)` mean the seven ECC bits from the shared encoder. For every byte:

```text
Result byte = byte_enable ? incoming byte : old byte
Unused byte = byte_enable ? old byte      : incoming byte

Result tag = tN
Unused tag = tO
eResult = eO XOR eN XOR E(Unused, tO)
```

`Unused` contains the bytes not selected into the result. Its reversed
selection is intentional, not a second data result or a stored extra word.
For the halfword example above, `Result = 0x1122AABB` and
`Unused = 0x00003344`. The unused term includes the old tag so its contribution
cancels out, leaving the incoming tag's contribution in the result ECC.

The inverted encoding is affine: it is a linear parity mapping plus a fixed
inversion constant. Using the original encoder for the third term preserves
that constant. Arbitrarily XORing only the two ECC fields, or using a
non-inverted encoder for the third term, would not implement this equation.

For analysis, define the seven-bit syndrome as:

```text
S(data, tag, ecc) = ecc XOR E(data, tag)

S(Result, tN, eResult) = S(O, tO, eO) XOR S(N, tN, eN)
```

This follows from `Result XOR Unused = O XOR N`. The hardware does not compute
or test these syndromes. It implements byte selection, one encoding operation
and XORs. It has no decoder, correction action or ECC-error branch.

Blindly setting `eResult = E(Result, tN)` would instead make every observed result
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
This checked the earlier data-only merge identity, not the tag-aware extension,
SystemVerilog compilation, RTL simulation, formal equivalence, core integration
or timing. No checked-in RTL regression for this helper exists yet.

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
| Separate refill completion wait | Keeps full-line reception and final success/failure status distinct | At least one state cycle after the final record; longer if completion is late; measure miss and workload impact |
| Fall-through write-back FIFO | Allows finite SRAM read-ahead and same-cycle forwarding when empty | 81 bits per entry plus queue control; compare measured area/runtime with a no-FIFO source |
| Conservative FIFO capacity reservation | Prevents unbackpressurable SRAM results from overflowing the queue | Ignores simultaneous output consumption and can introduce avoidable read bubbles |
| Separate write-back completion wait | Prevents replacement refill before confirmed write success | Completion/owner waiting costs cycles; actual recovery remains unimplemented |
| Per-set round-robin replacement | Independent replacement progress per set with invalid-way preference | `NumSets * WayIndexWidth` declared bits; compare a smaller global pointer against miss rate and traffic |
| Pure `function automatic` helper | Reuses the original code definition and synthesizes combinationally | Not zero-area software; repeated simultaneous calls may duplicate logic |
| No CPU store buffer or overlapping misses initially | Smaller request-control state and simpler ordering | The write-back FIFO does not hide an eviction from the requesting CPU; blocking latency remains |

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
checks restrict geometry sweeps to supported combinations. FIFO depth still
needs its lower-bound check. Performance sweeps need error/recovery handling,
the shared memory path, SoC integration and functional verification of refill
and write-back.
The current 32-bit codec and 80-bit record are not automatic 64-bit CPU support.

### Geometry Elaboration Checks

A temporary pyslang 3.0.0 harness elaborated 38 legal cache configurations,
including capacities from 4 to 32 KiB, 16/32/64-byte lines, one/two/four ways,
single-set configurations, an eight-way case and a matching 64-bit address
interface with 32-bit data, plus a shared wider memory-record counter.
Generated way counts, record depths, address widths
and exact macro storage capacities were checked against the requested geometry.
All 64 wrapper depths from 256 through 16,384 records in steps of 256 also
elaborated. Sixteen invalid cache configurations and five invalid wrapper
configurations were rejected with the expected parameter diagnostics.
The cache/arbiter packet widths were also checked, including rejection of
mismatched memory addresses and a counter too narrow for the full line count.

This was an isolated structural check using the actual cache sources and ECC
package, with `tc_sram_impl` replaced by a port-compatible stub. It does not
verify SRAM behavior, hit responses, a full Bender/SoC build, synthesis, timing
or RTL simulation. The temporary harness is not a checked-in regression.
The checks were rerun on 8 November with the current refill/write-back FSM,
the actual `stream_fifo` and `fifo_v3`, and the relocated simulation assertions.
FIFO-depth behavior and area are not established by geometry elaboration.

### Write-Back Control Model Check

A separate temporary cycle model explored 3,077 reachable control states across
25 combinations: 2/4/8/16/64 records per line and FIFO depths 2/3/4/5/8, with
both downstream-ready choices at each state. It modeled the one-cycle pending
SRAM read, fall-through queue, conservative capacity condition, sticky last-read
marker and ordered output handshakes. In that model, records were neither lost
nor duplicated, the queue did not overflow, no extra read followed the last
record, and progress remained possible with a ready receiver.

This is an algorithm-level check, not execution or formal proof of the RTL.
It did not exercise physical SRAM data, the new `$fatal` branches, HyperBus,
reset/error recovery or timing. No clocked cache RTL regression or integrated
performance measurement has run.

## Remaining Work and Verification Gates

The ordinary and capability read/store-hit paths now have source-level
datapaths and response sequencing. Isolated geometry elaboration has passed as
described above; interface behavior, timing and fault assumptions have not been
verified in simulation. Refill, dirty write-back and local replacement now
have source-level success paths. Transfer-error assertions stop simulation,
but recovery and the shared transfer engine remain incomplete.

Before functional cache testing:

- Build with the real SRAM implementation and test the implemented hit paths,
  including OBI timing, captured IDs and exactly one response per accepted
  request. Capability-read and capability-store completion use different flags
  and sequences.
- Verify the partial-store write strobes/dirty update and the assertion that
  excludes empty masks; define a hardware policy if such masks must be handled.
- Verify refill command stability, continuous/gapped `r_valid`, handshake-only
  indexing, SRAM record addressing and metadata installation before request
  replay. Check that incoming store data survives the refill.
- Verify the victim's old write-back address, including a single-set geometry,
  first-read timing, increasing record order and preservation of the pending
  OBI request/store data. Test short and long downstream stalls, full and empty
  FIFO boundaries, fall-through, stable offered data and delayed completion.
- Verify that the sticky last-read marker prevents every additional SRAM read,
  that only the last output handshake leaves the send phase, and that no FIFO
  entry or pending read remains before another operation. Test consecutive
  dirty evictions and add the FIFO-depth lower-bound check before sweeps.
- Complete early and final transfer-error handling, partial-refill invalidation
  and OBI failure responses without discarding modified lines. Exercise both
  completion-error assertions with simulation assertions enabled; they do not
  test recovery or diagnose an early-abort deadlock. Test retained/delayed
  completion status and coordinated reset.
- Check invalid-way priority, per-set replacement independence, explicit wrap
  including one-way caches, and advancement only after successful refill.
- Define initialization of encoded data/tag/ECC and protection of address tags,
  valid and dirty state. Payload ECC does not protect lookup metadata.
- Define the capability-pair input contract and conflicting JTAG/DMA accesses,
  plus I-cache/data-cache consistency and maintenance.
- Finalize and connect the shared data-plus-tag codec in the core and cache;
  remove the remaining zero ECC stubs.
- Register the modules with Bender and connect the cache only after focused
  module tests pass.

The geometry, refill and write-back additions do not change the documented
hit-path scheduling. The miss-path control has not been functionally verified
in RTL. No full SoC build or RTL simulation has been run for these changes.

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
performance be compared across cache configurations. Include write-back FIFO
depth and its no-FIFO alternative in that measured area/performance comparison.
