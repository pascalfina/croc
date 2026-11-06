# Cache Design Constraints

Date: 6 November 2026

Status: architectural baseline for the next implementation, not implemented or
verified RTL. This document supersedes the earlier proposal where it used the
Ibex I-cache or the shared 65-bit ECC scheme. Exact RTL interfaces, encoding bit
positions and SRAM-macro mapping are not yet frozen.

## Architecture

- Implement our own instruction cache and data cache.
- Keep the internal Ibex instruction cache disabled.
- The instruction cache is read-only and has no dirty state.
- The data cache must support capability tags, byte enables and ordinary data.
- Use write-back as the data-cache baseline; define allocation and maintenance
  behavior before implementation.
- Store backing data, capability tags and backing ECC in HyperRAM.
- Use SRAM for the cache payload arrays. Plan their actual macro mapping,
  including ECC storage, rather than relying on generic RTL arrays.
- Include ECC in the first implementation, not as a later addition.
- Support burst transfers in the first cache implementation. Use one shared
  transaction arbiter between the cache request paths and the protected
  HyperRAM transfer engine.

## Two Different Tags

| Name | Meaning | Granularity |
| --- | --- | --- |
| Cache address tag | Identifies which memory block occupies a cache slot | One per cacheline |
| Capability tag | Indicates whether the stored 64-bit value is a valid capability | One per aligned 8 logical bytes |

Every cache needs address tags, even in a system with only one cache. They are
unrelated to CHERIoT capability validity. Both caches need cache address tags;
only the data-cache view needs to return capability tags to the core.

## 80-Bit Backing Record

One aligned 8-byte logical data region maps to one 80-bit physical record:

| Component | Bits | ECC coverage |
| --- | ---: | --- |
| Lower payload word | 32 | Protected by ECC-L |
| ECC-L | 7 | SECDED for the lower 32-bit payload word |
| Upper payload word | 32 | Protected together with the capability tag by ECC-H |
| Capability tag | 1 | Included in ECC-H's protected input |
| ECC-H | 7 | SECDED for the upper payload word plus tag: 33 input bits |
| Reserved, written as zero | 1 | Not assumed to be ECC-protected; carries no state |
| **Total** | **80** | **10 physical bytes for 8 logical bytes** |

For a capability, the lower word holds the pointer address and the upper word
holds capability metadata. For ordinary data or instruction bytes, both words
are simply payload. The record is not restricted to capability values.

This uses two separate ECC codewords: 32 + 7 = 39 bits and 33 + 7 = 40 bits.
Each independently corrects one bit error and detects two bit errors. No third
ECC code is needed just for the capability tag. The remaining bit is reserved.
Exact code-bit ordering and physical serialization must be fixed before RTL
implementation and used consistently by encode, decode, initialization and tests.

The backing format applies to both instruction and data views of the same
memory. Instruction fetch does not interpret a capability tag as execution
permission, but the corresponding backing ECC must still be checked.

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
| `RECEIVE_READ` | Route accepted read beats to the owner's refill path. Count beats, check `last` and accumulate errors. The receive buffer must not depend on CPU word consumption. | Segment complete -> next `ISSUE_COMMAND`, or `COMPLETE` after all segments and required ECC processing |
| `SEND_WRITE` | Supply only the owner's encoded write data. Hold each beat stable under backpressure and assert `last` on the segment's final beat. | Final write beat accepted -> `WAIT_WRITE_RESPONSE` |
| `WAIT_WRITE_RESPONSE` | Wait for the matching write response and record its status. Sending the final data beat alone is not completion. | Response accepted -> next `ISSUE_COMMAND`, or `COMPLETE` after all required responses |
| `COMPLETE` | Return the accumulated result to the owner. Keep completion stable until accepted. All outstanding transport activity must already be drained. | Completion accepted -> release owner and return to `IDLE` |
| `FAULT` | Block new owners and preserve the failed request's diagnostic state. Never reassign responses from an uncertain outstanding transaction. | Coordinated reset/recovery only |

If ECC processing and burst reception run concurrently, completion still waits
for the required ECC result. A cacheline must not become valid just because the
last physical beat has arrived. A dirty bit may be cleared only after the full
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
- A successful read completes only after all expected beats have been received, required
  ECC checks have finished and the final result is accepted by the owner.
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
before eviction. Set valid only after the required data and ECC checks complete.

These cache address tags and valid/dirty bits are not part of the 80-bit backing
record. Capability tags remain part of the protected cached data representation.
Replacement-policy state is also cache-local state, not backing payload.

Using flipflops does not itself provide error protection. Define protection for
cache address tags and valid/dirty state as well as local cache data before RTL
implementation; dirty-line corruption must never be handled by silently
discarding the line.

## Parameter Sweeps

Make the following independently configurable for the I-cache and D-cache:

- Usable data capacity in bytes.
- Logical line size in bytes.
- Number of ways.

Derive record count, physical transfer size, host-beat count, set count and
address-tag width from those parameters. Reject unsupported combinations rather
than truncating values. Capacity must be divisible by line size times ways; the
initial indexed design uses power-of-two set counts and ways.

Keep the 80-bit backing format and ECC grouping fixed during cache-geometry
sweeps. Changing this format is a separate experiment and requires compatible
address mapping, initialization and test data.

The previous 4 KiB I-cache / 8 KiB D-cache / 16-byte lines / two ways remain
possible measurement starting points, not fixed requirements or proven optima.

## Required Follow-Up Decisions

- Freeze ECC bit ordering, reserved-bit placement and byte serialization.
- Specify split capability-store commit, consistent capability reads and all
  conflicting accesses, including JTAG and DMA.
- Specify instruction/data consistency, including `FENCE.I` and code modification.
- Specify cache allocation, replacement, flush/drain and write-back error handling.
- Specify initialization of valid data/tag/ECC records before partial writes.
- Choose local cache-array and standard-cell metadata protection and SRAM mapping.
- Verify packing across record and line boundaries, ECC fault injection and
  independently varied I-cache/D-cache geometries before performance sweeps.
- Verify simultaneous cache requests, fair handover, backpressure on every
  channel, multi-burst ownership, write-response delay and error/reset handling.
