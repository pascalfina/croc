# Cache Design Constraints

Date: 7 November 2026

Status: architectural baseline, not a claim of implemented or verified RTL.
See [Cache Implementation Status](cache-implementation-status.md) for the current
source-level behavior, incomplete paths, SRAM mapping and ECC fault model.
This document supersedes the earlier proposal where it used the Ibex I-cache,
the shared 65-bit ECC scheme, or one stored capability tag plus a reserved bit.
The current record has two 40-bit words, each with its own stored tag.

## Architecture

- Implement our own instruction cache and data cache.
- Keep the internal Ibex instruction cache disabled.
- The instruction cache is read-only and has no dirty state.
- The data cache must support capability tags, byte enables and ordinary data.
- Use write-back as the data-cache baseline; define allocation and maintenance
  behavior before implementation.
- Use write-allocate initially: a store miss refills the full line and then
  replays the saved store through the existing hit path.
- Store backing data, capability tags and backing ECC in HyperRAM.
- Use SRAM for the cache payload arrays. Plan their actual macro mapping,
  including ECC storage, rather than relying on generic RTL arrays.
- Include ECC in the first implementation, not as a later addition.
- Keep ECC checking in the core for the initial design. The cache stores and
  forwards encoded words; its partial-store path updates ECC without decoding
  or correcting data. The fault-model limitations below are part of this choice.
- Support burst transfers in the first cache implementation. Use one shared
  transaction arbiter between the cache request paths and the protected
  HyperRAM transfer engine.

## Two Different Tags

| Name | Meaning | Granularity |
| --- | --- | --- |
| Cache address tag | Identifies which memory block occupies a cache slot | One per cacheline |
| Capability tag | Indicates whether the stored 64-bit value is a valid capability | One per aligned 8 logical bytes |

The current record stores a tag with each of its two 32-bit words. Ibex combines
the two returned tags with AND when reconstructing a capability. These two
stored tags represent one capability-validity decision, not two capabilities.

Every cache needs address tags, even in a system with only one cache. They are
unrelated to CHERIoT capability validity. Both caches need cache address tags;
only the data-cache view needs to return capability tags to the core.

## 80-Bit Backing Record

One aligned 8-byte logical data region maps to one 80-bit physical record:

| Component | Bits | ECC coverage |
| --- | ---: | --- |
| Lower payload word | 32 | Intended to be protected together with its tag |
| Lower capability tag | 1 | Intended to be included in ECC-L |
| ECC-L | 7 | Target: SECDED for 33 input bits |
| Upper payload word | 32 | Intended to be protected together with its tag |
| Upper capability tag | 1 | Intended to be included in ECC-H |
| ECC-H | 7 | Target: SECDED for 33 input bits |
| **Total** | **80** | **10 physical bytes for 8 logical bytes** |

For a capability, the lower word holds the pointer address and the upper word
holds capability metadata. For ordinary data or instruction bytes, both words
are simply payload. The record is not restricted to capability values.

There is no reserved bit in this representation. The source struct packs the
lower word as data [31:0], tag [32], ECC [39:33], and the upper word as data
[71:40], tag [72], ECC [79:73].

The target is two independent 40-bit SECDED codewords, each protecting 32 data
bits plus one tag. However, the current Ibex encoder and
`ecc_merge_partial32()` protect only 32 data bits with seven ECC bits; they do
not protect the tag. A common 33-bit codec, including its bit ordering and
initialization values, still has to be implemented consistently in core and
cache. Merely enabling `MemECC` does not supply this extension. The initial
policy is detection in the core, not correction in the cache.

The backing format applies to both instruction and data views of the same
memory. Instruction fetch does not interpret a capability tag as execution
permission. The instruction path's checking and adaptation to the shared
encoded backing format must also be specified; its current 32-bit Ibex checker
must not be assumed to check a future data-plus-tag codeword unchanged.

## Partial Stores and ECC Fault Model

A full 32-bit store replaces its complete 40-bit stored word and forwards the
incoming ECC. A partial store preserves some existing bytes, so the cache first
reads the record, merges bytes and updates ECC for that combination. The helper
uses the original inverted Ibex encoder function rather than a second encoding
matrix. It performs no ECC check or correction.

For the current 32-bit codec, the update preserves the XOR of the two input
syndromes. If one input is valid, an existing nonzero syndrome in the other input
remains nonzero. If both inputs are faulty, equal syndromes can cancel and
corrupted output data can pass the core's later check. This is deterministic
silent corruption outside the supported single-faulty-input assumption, not
SystemVerilog undefined behavior. It also applies if an earlier fault remains
stored until a later faulty partial-store request arrives.

This limitation must remain explicit in verification and any reliability claim.
Checking both inputs locally would change the chosen fault model and hardware
cost; it is not part of the initial cache path. See the implementation-status
document for the update equation, an example and remaining integration work.

## Packing and Burst Constraints

Keep the complete 80-bit records contiguous in physical memory. Do not round
each individual record up to three 32-bit host words: that would waste bandwidth
and increase storage overhead unnecessarily.

The current HyperBus host interface is 32 bits wide. A single record occupies
2.5 host words, but two adjacent records occupy exactly five complete words.
One host word therefore spans the boundary between two records. The packer and
unpacker must explicitly support that boundary; partial updates must preserve
the neighboring record.

For the initial supported cache configurations:

- `LineDataBytes` counts logical payload bytes, excluding capability tags and ECC.
- Use power-of-two line sizes of at least 16 logical bytes.
- Align logical line bases to `LineDataBytes`.
- Align the physical backing-region base to the 32-bit host width.
- Pack all records of a line without inter-record gaps or per-record word padding.
- Require an integer number of complete host beats for each line transfer.

Derived sizes for the current format and host width:

```text
RecordsPerLine    = LineDataBytes / 8
PhysicalLineBits  = RecordsPerLine * 80
PhysicalLineBytes = RecordsPerLine * 10
HostBeatsPerLine  = PhysicalLineBits / 32
```

| Logical line size | Records | Physical transfer size | 32-bit host beats |
| ---: | ---: | ---: | ---: |
| 16 bytes | 2 | 20 bytes | 5 |
| 32 bytes | 4 | 40 bytes | 10 |
| 64 bytes | 8 | 80 bytes | 20 |
| 128 bytes | 16 | 160 bytes | 40 |

A 64-byte logical line therefore requires an 80-byte physical transfer. Burst
lengths must use physical sizes, not logical line sizes. A single incrementing
burst is the target when controller, chip-range and timing limits allow it;
otherwise split the transfer while preserving its ordering and error handling.

Implement incrementing burst transport from the start. The cache refill and
write-back interfaces must describe complete line operations, including their
physical transfer length. Do not turn a line into independent single-word
commands as the default implementation. Buffer reception independently of CPU
word responses.

Full host-word utilization does not mean 100% payload efficiency: 64 / 80 = 80%
of the record bits are payload. Physical storage overhead is 25%; command,
latency, refresh, backpressure and unnecessary line fetches cause additional
performance costs.

## Refill Completion and Performance Baseline

The draft data cache uses `SEND_REFILL_CMD`, `WAIT_REFILL_DATA` and a separate
`WAIT_REFILL_DONE`. The command addresses the requested logical line, not the
evicted line, and requests `RecordsPerLine` full 80-bit records. The internal
record index starts at zero when the command is accepted and advances only on
`r_valid && r_ready`. Address the SRAM with
`SetIndex * RecordsPerLine + RecordIndex`; this is a record address, not a byte
address. Keep the saved OBI request and incoming store data intact.

Retain the separate completion state as the initial baseline. After all records
are committed and successful completion is accepted, install the new address
tag, set valid, clear dirty, advance replacement state and return directly to
`CACHE_LOOKUP`. The existing hit path completes the original read/store without
accepting it again. The source contains this success path; error handling,
dirty write-back and the shared transfer engine are not complete or verified.

The completion state occupies one cycle if status is already available when
entered; a late status adds more waiting cycles. It does not change hit-path
scheduling. One extra cycle adds `1 / N` to an otherwise `N`-cycle miss, not
necessarily to the whole program runtime. For example, the increase is 1% for
100-cycle misses and 0.2% for 500-cycle misses. These are illustrative ratios,
not measured performance. Shared-arbiter ownership held during completion
waiting can also delay the other cache.

Measure completion-wait cycles, total miss latency, contention and workload
runtime before removing or merging this state. A future implementation may
complete on the last-record edge when data and final success status can be
accepted together. The producer, error rules and owner-release contract must
support that change; the independent channels do not guarantee simultaneity.
Counter-only refill completion is not the chosen initial contract. The
`r.last` field is currently redundant with the expected record count for cache
control and can be checked against that count in simulation.

## Transaction Arbiter and Ownership FSM

The instruction-cache and data-cache memory request paths share the protected
memory controller and HyperBus host interface. A state machine must select one
request and retain its owner until that complete memory operation finishes.
The instruction-cache path only issues reads. The data-cache path issues both
refill reads and dirty-line write-backs.

### Arbitration Granularity

- One request describes one complete line read or line write-back, not one beat.
- Accept a request only when no previous owner or undrained response remains.
- Latch the selected owner, operation, address and physical host-beat count at
  acceptance. Derive sizes from that owner's cache configuration; the two caches
  may have different line lengths.
- Owner is `NONE`, `ICACHE` or `DCACHE`. Only the selected path may supply write
  data or receive the operation's read data and completion status.
- Keep ownership across all host bursts needed for this request. Splitting a
  line at a supported range or transfer limit must not allow the other cache to
  insert commands between its segments.
- Internal segmentation by the HyperBus midend does not end the owned request.
- Use round-robin selection when both paths are eligible at an operation
  boundary. Arbitration is not repeated for each beat or segment.
- A dirty eviction write-back and its subsequent refill are separate complete
  memory requests. The other cache may be served between them; the D-cache must
  preserve the state needed to resume its miss handling.

The lock is local ownership of request routing and response tracking. It does
not mean keeping the external chip-select asserted indefinitely: required
recovery times, refresh opportunities and legal burst boundaries still apply.

### FSM Responsibilities

The following are logical states; final RTL state names and any equivalent
merging of states are implementation details.

| State | Required behavior | Transition |
| --- | --- | --- |
| `IDLE` | Choose an eligible cache request, acknowledge it and latch its owner and descriptor. Do not acknowledge the other request. | Accepted request -> `ISSUE_COMMAND` |
| `ISSUE_COMMAND` | Present the next host-burst command. Hold command fields and valid stable until the midend accepts it. Retain owner. | Command accepted -> `RECEIVE_READ` or `SEND_WRITE` |
| `RECEIVE_READ` | Route accepted read beats to the owner's refill path. Count beats, check `last` and accumulate errors. The receive buffer must not depend on CPU word consumption. | Segment complete -> next `ISSUE_COMMAND`, or `COMPLETE` after all segments and required format processing |
| `SEND_WRITE` | Supply only the owner's encoded write data. Hold each beat stable under backpressure and assert `last` on the segment's final beat. | Final write beat accepted -> `WAIT_WRITE_RESPONSE` |
| `WAIT_WRITE_RESPONSE` | Wait for the matching write response and record its status. Sending the final data beat alone is not completion. | Response accepted -> next `ISSUE_COMMAND`, or `COMPLETE` after all required responses |
| `COMPLETE` | Return the accumulated result to the owner. Keep completion stable until accepted. All outstanding transport activity must already be drained. | Completion accepted -> release owner and return to `IDLE` |
| `FAULT` | Block new owners and preserve the failed request's diagnostic state. Never reassign responses from an uncertain outstanding transaction. | Coordinated reset/recovery only |

If format processing and burst reception run concurrently, completion still
waits until the complete encoded line is stored and no transport error remains.
With checking deferred to the core, a valid cacheline is not a certificate that
its ECC has already been checked. A dirty bit may be cleared only after the full
write-back is confirmed successful, with concurrent modification prevented or
explicitly tracked.

### Progress and Error Rules

- Advance beat counters only on valid/ready handshakes, never on elapsed cycles.
- Track both remaining line beats and the current host burst's expected beats.
  Check `last` against the accepted host command, not an assumed cycle count.
- Do not release ownership on command acceptance, a temporary lack of valid
  data, backpressure, or a change in either cache's pending request.
- A 64-byte logical line has 20 host beats. If split into two host bursts of
  10 beats, keep the same owner across both commands and their responses.
- A successful transport read completes only after all expected encoded beats
  have been received, format processing has finished and the final result is
  accepted by the owner. Architectural data-integrity checking remains the
  core's responsibility.
- A successful write completes only after all write beats and all required write responses
  have been accepted, and the final result is accepted by the owner.
- On a reported transfer/ECC error, retain the error and drain accepted commands
  before returning failure. Unissued remaining segments may be cancelled on
  failure; a failed read must not validate a partial line. Never route a late
  response to the next owner.
- Unexpected response ordering or beat counts, a stuck transfer or an uncertain
  partial write must enter `FAULT`. Do not simply unlock
  the bus on a timeout and start another request. Preserve dirty data on failure.
- Reset/recovery must also reset or quiesce the downstream path before a new
  owner is admitted; clearing the owner register alone is insufficient.

This FSM prevents interleaved transfers and misrouted responses. It does not by
itself establish instruction/data consistency or order conflicting cached
accesses; those requirements still need their own specified mechanism.

## Cache Metadata in Standard Cells

Use standard-cell registers, normally flipflops, for cache address tags and
line-status bits in the initial design. Standard cells are a cell-library
category, not a synonym for flipflops, but register storage here means flipflops
or another deliberately chosen register implementation, not an SRAM macro.

| Per-line state | Instruction cache | Write-back data cache |
| --- | --- | --- |
| Cache address tag | Required | Required |
| Valid bit | Required | Required |
| Dirty bit | Not needed | Required |

The valid bit means the complete line is available and usable. The dirty bit
means the data-cache copy differs from backing memory and needs write-back
before eviction. Set valid only after the complete encoded line has been stored
and required transport checks have completed. Under the core-only checking
policy, valid does not mean the cached codewords have passed an ECC check.

These cache address tags and valid/dirty bits are not part of the 80-bit backing
record. Capability tags remain part of the protected cached data representation.
Replacement-policy state is also cache-local state, not backing payload.

Using flipflops does not itself provide error protection. Define protection for
cache address tags and valid/dirty state as well as local cache data before RTL
implementation; dirty-line corruption must never be handled by silently
discarding the line.

### Replacement State: Local Versus Global Round-Robin

Initially prefer an invalid way; when all ways are valid, use a per-set
round-robin candidate. Advance only the affected set's pointer after a
successful refill to the way after the installed line, wrapping explicitly
from the last way to zero. Do not advance on hits or failed refills. With one
way the candidate stays zero. Round-robin is not LRU and does not track hit
recency.

For `NumWays > 1`, local candidates require
`NumSets * ceil(log2(NumWays))` stored bits. The current 8 KiB, 16-byte-line,
two-way defaults have 256 sets and require 256 replacement bits. At the same
capacity and associativity, 64-byte lines require 64 bits. The `_d` next-state
array is combinational, not a second set of flipflops. Actual cell area and
optimization must be obtained from synthesis, not inferred from bit count or
compared directly with SRAM bit area.

Keep this local policy for the initial implementation, but leave its area
versus effectiveness open for measurement. One global pointer per cache would
need only `ceil(log2(NumWays))` stored bits and less replacement-state
clock/reset load. In return, misses in other sets influence victim selection:
interleaved accesses can repeatedly evict the same way within an individual
set. Local candidates avoid that coupling but are not guaranteed to improve
every workload. The global policy is an unimplemented alternative, not an
existing configuration parameter.

Compare policies at identical payload capacity, line size, ways and workloads.
Collect miss rates, dirty evictions, HyperBus traffic, stall/runtime cycles,
standard-cell area and timing; include conflicting and interleaved-set access
patterns. This is cache replacement policy, not the independent I-cache versus
D-cache transaction-arbitration policy.

## Generic Cache SRAM

The draft implementation is `rtl/cache/cache_data_sram.sv`. As of 7 November
2026, its macro instances, write masks, registered read selection and 80-bit
output are connected, and a generate loop instantiates one wrapper per way in
the draft data cache. Neither module is registered as a module source in the
normal Bender build or connected as a cache in the SoC. Isolated parameter
elaboration with an SRAM-interface stub has passed; no full SoC build or RTL
simulation has been performed for this work. See the implementation-status
document for the checked configurations and limits.

### Interface and Capacity

Instantiate one wrapper per cache way. `NumWords` counts complete 80-bit
records, not bytes. Each record represents 8 logical payload bytes and occupies
10 storage bytes including two capability tags and fourteen ECC bits.

```text
RecordsPerLine  = LineDataBytes / 8
NumWords        = CacheDataBytes / (NumWays * 8)
SramWordAddress = SetIndex * RecordsPerLine + RecordIndexWithinLine
AddrWidth       = max(1, ceil(log2(NumWords)))
```

`CacheDataBytes` remains the total usable payload capacity across all ways.
For an 8 KiB, two-way cache, each wrapper therefore contains 512 records,
addressed with 9 bits. Do not multiply the SRAM word address by 10: this
interface is word-addressed, unlike the byte-addressed HyperRAM interface.

The wrapper has one logical read/write port. A valid `req_i` is accepted at the
clock edge without a separate grant. With `we_i = 1`, the ten-bit `be_i`
selects which bytes of the 80-bit `wdata_i` record are written; disabled bytes
are preserved. `we_i = 0` starts a synchronous read. There is no `ready`, `rvalid` or
error output; the cache controller must track read completion. Keep `req_i`
low during reset. Reset clears the read-selection registers, not SRAM contents;
cacheline valid bits and record initialization remain the caller's responsibility.

### Packed SRAM Layout

Do not allocate a separate 32-bit macro word for each record's remaining
16 bits: that would leave 16 extra macro bits unused per record. Instead, the
wrapper uses two parallel 64-bit storage parts:

| Part | Word count | Stored bits |
| --- | ---: | --- |
| Main (`part == 0`) | `NumWords` | Record bits `[63:0]` |
| Packed remainder (`part == 1`) | `NumWords / 4` | Four records' `[79:64]` slices per word |

For record address `a`, the main address is `a`, the remainder address is
`a >> 2`, and the 16-bit slot is `a[1:0]`. For example, records 4, 5, 6 and 7
share remainder word 1, using slots 0, 1, 2 and 3 respectively.

On a write, the main part receives `be_i[7:0]`. The remainder part replicates
the 16-bit input slice across its 64-bit write bus and shifts `be_i[9:8]`
into the selected two-byte slot. The other three records' remainder slices
are preserved without an additional read-modify-write operation. A part with
no enabled write bytes is not requested.

The cache masks are `10'h01F` for the lower 40-bit word, `10'h3E0` for the
upper word, and `10'h3FF` for a full record. These are storage-byte masks,
not the four-bit CPU byte-enable. Selecting the upper mask does not shift
data into the upper half: the cache must place its 40-bit value there too.

This is a physical bit-slice mapping of an opaque 80-bit record. It does not
define the record's ECC bit ordering, compute or check ECC, interpret capability
tags, or assemble split CPU capability stores. Those remain cache/codec duties.
The internal SRAM packing need not match HyperRAM's serialized layout.

### Macro Selection

Each part is independently decomposed into 64-bit-wide `tc_sram_impl` instances.
The existing IHP implementation supports depths of 2048, 1024, 512, 256 and
64 words. Choose the largest fitting depth first, then decompose the remainder.
The instance counts are elaboration-time constants, not runtime division or a
search performed on memory requests.

| `NumWords` records | Main-part macros | Remainder-part macros |
| ---: | --- | --- |
| 256 | 1 x 256 | 1 x 64 |
| 512 | 1 x 512 | 2 x 64 |
| 1024 | 1 x 1024 | 1 x 256 |
| 2048 | 1 x 2048 | 1 x 512 |
| 4096 | 2 x 2048 | 1 x 1024 |

All macro widths in this table are 64 bits. For supported sizes, total macro
bit capacity is exactly `NumWords * 64 + (NumWords / 4) * 64 = NumWords * 80`.
There is no additional unused macro bit capacity beyond the defined record
format. This does not eliminate the format's 25% storage overhead or the macro
periphery and control-logic area. Largest-first decomposition is a mapping
rule, not a guarantee of globally optimal physical area.

Use `tc_sram_impl` rather than directly instantiating IHP cells. The existing
build targets select its generic simulation or technology-specific implementation.

### Read Timing and Supported Sweeps

Both parts are read in parallel with one synchronous SRAM cycle of latency.
At the read-request edge, each part saves its selected macro as a one-bit-per-macro
vector, and the wrapper saves the original address's two slot bits. Combinational
multiplexers then select the corresponding macro outputs and the correct 16-bit
slot. Reassemble the result as 64 main bits plus 16 remainder bits. Do not use
the current request address to select an earlier read response, and do not add
another data register without changing the latency contract.

- Require `NumWords > 0` and `NumWords % 256 == 0`. Both parts can then be
  completely covered by the supported macros, without silent rounding or loss
  of remainder storage. Reject unsupported configurations at elaboration.
- Only addresses below `NumWords` may activate macros. The current RTL gates
  invalid requests off; an assertion should also diagnose them.
- The wrapper may accept back-to-back valid requests, but only one logical
  operation per cycle. Consume `rdata_o` for the corresponding read; no separate
  read-during-write or output-hold guarantee is provided.
- Sweep cache capacity, line size and ways through the derived `NumWords` value.
  Check the complete cache's geometry constraints as well as this wrapper's
  depth constraint. The 80-bit record format remains fixed.
- Compare actual macro area, selection logic, power and timing, not just bit
  utilization. Larger bank counts and multiplexers must still meet the target
  clock; constant cycle latency does not guarantee constant maximum frequency.

The wrapper now checks depth, fixed 80-bit data width and matching address
width at elaboration. The cache also checks its geometry and OBI field widths.
Before integrated use, add a runtime request-address assertion and the wrapper
source to Bender. Verify full-record round trips, preservation of all
four packed slots, macro-boundary accesses, changing addresses during reads,
back-to-back reads/writes, reset behavior and representative sweep depths in
both the generic and IHP simulation models. No such RTL verification has been
performed yet.

## Portability to 64-Bit Systems

The first implementation targets the current 32-bit Croc interfaces. Keep the
design portable to wider systems, but do not claim verified 64-bit support just
because a width parameter exists.

- Keep logical address width, CPU data width and backing host data width
  independent. A 64-bit address space does not imply a 64-bit HyperBus host port.
- Derive byte-enable widths, byte offsets, address tags, counters and address
  arithmetic from the relevant parameters. Avoid fixed 32-bit slices and masks
  in the reusable cache control and data paths.
- Keep Croc-specific OBI type definitions and HyperBus transport details at
  adaptation boundaries rather than importing them into generic cache logic.
- Separate capability/tag granularity and ECC-codec configuration from CPU word
  width. The current 8-byte payload / 80-bit record is an explicit CHERIoT-32
  format, not a universal format for every 64-bit capability architecture.
- Derive host-beat counts as `PhysicalLineBits / HostDataWidth`. Require exact
  divisibility and matching physical alignment, or explicitly implement a
  partial-beat protocol. Do not silently round or truncate.
- With the current 80-bit records and a future 64-bit host port, four records
  occupy five complete host beats. A power-of-two logical line then needs at
  least 32 bytes; a 16-byte logical line would not fill whole 64-bit beats.
- Initially reject unsupported interface/codec combinations at elaboration.
  Later width support requires verification of accesses, capability handling,
  ECC, packing and bursts, not just changing constants.

## Parameter Sweeps

Make the following independently configurable for the I-cache and D-cache:

- Usable data capacity in bytes.
- Logical line size in bytes.
- Number of ways.

Derive record count, physical transfer size, host-beat count, set count and
address-tag width from those parameters. Reject unsupported combinations rather
than truncating values. Capacity must be divisible by line size times ways; the
initial indexed design uses positive power-of-two set counts and ways. One-way
and single-set configurations are handled explicitly without zero-width
indices. Each way must contain a positive multiple of 256 records for the
current SRAM packing; for example, 4 KiB with four ways is unsupported.

Keep the 80-bit backing format and ECC grouping fixed during cache-geometry
sweeps. Changing this format is a separate experiment and requires compatible
address mapping, initialization and test data.

The previous 4 KiB I-cache / 8 KiB D-cache / 16-byte lines / two ways remain
possible measurement starting points, not fixed requirements or proven optima.

## Required Follow-Up Decisions

- Freeze the shared data-plus-tag ECC codec and backing byte serialization.
- Specify split capability-store commit, consistent capability reads and all
  conflicting accesses, including JTAG and DMA.
- Specify instruction/data consistency, including `FENCE.I` and code modification.
- Specify cache allocation, replacement, flush/drain and write-back error handling.
- Measure the separate refill-completion wait before merging it with final data
  acceptance, and compare local versus global replacement pointers for area,
  traffic and workload performance before choosing the optimized policy.
- Specify initialization of valid data/tag/ECC records before partial writes.
- Finalize local cache-array and standard-cell metadata protection; verify the
  documented SRAM mapping, latency and parameter checks.
- Verify packing across record and line boundaries, ECC fault injection and
  independently varied I-cache/D-cache geometries before performance sweeps.
- Verify simultaneous cache requests, fair handover, backpressure on every
  channel, multi-burst ownership, write-response delay and error/reset handling.
