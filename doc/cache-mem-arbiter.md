# Cache Memory Arbiter

Snapshot: 8 November 2026.

This document describes the current
[`cache_mem_arbiter.sv`](../rtl/cache/cache_mem_arbiter.sv): port arbitration,
ownership, logical-to-physical address mapping, the write packing buffer and
write completion. It documents implemented RTL separately from remaining work.
The read path is still a placeholder. This is not full-SoC, synthesis, timing
or HyperRAM-model sign-off.

Related documents: [Cache Design Constraints](cache-design-constraints.md) and
[Cache Implementation Status](cache-implementation-status.md).

Integration update, 10 November 2026: `croc_domain` now uses three arbiter ports:
D-cache 0, I-cache 1 and the uncached [JTAG HyperRAM Adapter](jtag-hyperram-adapter.md)
on port 2. That page documents why the loader bypasses the write-back D-cache,
its completion barrier and its partial-word handling. The current write stream
includes `w_strb`, packed alongside data: D-cache write-back supplies all ones,
whereas JTAG can mask unfilled words. The older snapshot below predates this
mask extension, read-path completion and removal of the old OBI frontend from
the SoC memory path; those older statements are not the current integration
status.

## Position and Interfaces

The module combines the shared cache arbiter and write transfer engine. Cache
line requests enter through `cache_req_i[port]`; the selected request is
translated into the existing HyperBus midend's protocol-neutral host interface.
There is no separate OBI frontend in this proposed cache-to-midend path. OBI
request handling stays on the CPU-facing side of the caches. The old HyperBus
OBI frontend remains in the existing SoC path until the new subsystem is wired.

The midend, backend, physical interface and configuration frontend are reused.
The arbiter does not drive HyperRAM pins, implement ECC checking/correction,
interpret capability contents or perform partial CPU stores. It preserves the
encoded records produced by the cache and writes complete host words.

| Interface | Direction relative to arbiter | Purpose |
| --- | --- | --- |
| `cache_req_i[port]` | Input | Cache commands, write records and readiness for read/completion responses |
| `cache_rsp_o[port]` | Output | Command/write readiness, read records and final completion |
| `host_req_o` | Output | Midend command/write streams and readiness for midend responses |
| `host_rsp_i` | Input | Midend readiness, read data and write completion |
| `drain_i` | Input | Stop admitting new cache operations, without cancelling an accepted one |
| `idle_o` | Output | The arbiter is in `IDLE`, with no owned operation |

Cache packet definitions live in
[`cache_typedef.svh`](../rtl/cache/cache_typedef.svh), and the fixed record and
completion payloads live in [`cache_pkg.sv`](../rtl/cache/cache_pkg.sv).
Host packets are defined in
[`hyperbus/typedef.svh`](../rtl/vendor/hyperbus/include/hyperbus/typedef.svh).

All cache ports use the same `mem_req_t` / `mem_rsp_t` types, including the same
record-count field width. The value of `cmd.records` can differ between ports;
the enclosing integration must choose a type wide enough for every cache's
line. Port indices run from zero through `NumPorts - 1` and are not hardwired
to I-cache or D-cache in this module.

All channels transfer at a clock edge with valid and ready both high. The
producer must not wait for ready before offering valid data, and must hold
valid and payload stable while blocked. Ready may already be high before valid
arrives. Valid may remain high across consecutive accepted words; it is not a
one-cycle-pulse or rising-edge contract. The arbiter introduces no clock-domain
crossing; its cache-facing and midend-facing signals use `clk_i`.

## Parameters

| Parameter | Default | Meaning |
| --- | ---: | --- |
| `NumPorts` | 2 | Number of cache request ports |
| `AddrWidth` | 32 | Logical and mapped host address width |
| `HostDataWidth` | 32 | Midend host-word width in bits; the currently tested format uses 32 |
| `WriteBufferBits` | 96 | Capacity of the register-based write packing buffer, excluding its occupancy counter |
| `LogicalBaseAddr` | `0x80000000` | Base of the CPU-visible encoded-memory region |
| `PhysicalBaseAddr` | `0x80000000` | Base of its expanded backing region in the midend host address space |
| `mem_req_t`, `mem_rsp_t` | `logic` | Must be replaced with matching cache packet types |
| `host_req_t`, `host_rsp_t` | `logic` | Must be replaced with matching midend host packet types |

The `logic` type defaults are placeholders, not usable packet configurations.
`PortIndexWidth` is at least one bit. Beat and buffer counter widths are
elaboration-time constants, not runtime-sized state.

`WriteBufferBits` is a module parameter, not a package constant. Its packed
struct is generated locally by `CACHE_TYPEDEF_WRITE_BUFFER_T` using the shared
macro definition. Separate instances can therefore have different capacities
without editing `cache_pkg.sv`.

## Port Arbitration and Ownership

### Accepting One Request

Only `IDLE` accepts commands. If `drain_i` is low, the scan starts at
`rr_start_port_q` and visits each port once in circular order. The first port
with `cmd_valid = 1` wins. Combinational `found_port` prevents later candidates
from replacing that selection; no count of requesting ports is needed.

Only the winner receives `cmd_ready = 1`. At that command handshake, the RTL
stores its port in `selected_port_q`, captures `cmd.write`, `cmd.line_addr` and
`cmd.records` in `cache_data_q`, clears `count_beat_q` and enters
`ISSUE_COMMAND`. All other response fields default to zero.

The acceptance logic uses the selected loop candidate, not the previous value
of `selected_port_q`. The selected-owner register changes at the accepting
clock edge.

### Locking an Entire Operation

The owner is retained for the complete line operation. Only that cache can
supply write records or receive completion. Other ports cannot insert commands
between host words, during a source-data gap, while the midend is stalled or
while completion is waiting for the selected cache.

The current engine issues **one host command for the entire line**, not one
command per record or per word. There is no `MaxBurstBeats` parameter and no
arbiter-side splitting into several host commands. Any segmentation performed
inside the midend does not release ownership. Locking the owner does not mean
holding external chip-select continuously; physical bus timing remains the
responsibility of the existing HyperBus controller.

A dirty eviction and the following refill are separate cache commands. The
other cache may be selected between them. The D-cache retains its pending miss
state across that handover.

Only one shared operation is outstanding, so one owner register and one
line-local beat counter are sufficient. No per-port suspended-transfer counters
or transaction IDs are used in this interface.

### Round-Robin Handover

After the selected cache accepts write completion, the RTL advances
`rr_start_port_d` to `selected_port_q + 1` and returns to `IDLE`. It advances
after either success or a reported write error, not after command acceptance
or the final data beat. While completion is blocked, the pointer stays put.

For two continuously requesting ports, completed operations alternate between
port 0 and port 1. Reset initializes the start pointer to zero. If only one
port requests service, the circular scan skips inactive ports and selects it.

At a power-of-two port count greater than one, register truncation wraps the
last port's successor to zero. With other positive counts, including a single
port, the stored successor may equal `NumPorts`; the existing subtraction in
the `IDLE` scan normalizes each candidate back into the port range. The stored
start pointer must therefore not be treated as an unchecked array index
elsewhere.

Fairness is per completed operation, not per cycle or beat. It depends on the
selected cache supplying its records, the midend completing the write and the
cache eventually accepting completion. An indefinitely stalled owner blocks
all other ports. There is no timeout or preemption.

## Logical Addresses and Physical Transfers

CPU-visible addresses count payload bytes. A cache record represents eight
logical bytes but occupies 80 stored bits, or ten physical bytes, because it
also carries capability tags and ECC. `cmd.line_addr` is an aligned logical
byte address; `cmd.records` counts complete records.

The address helper computes:

```text
LogicalByteOffset   = CacheLineAddress - LogicalBaseAddr
RecordIndex         = LogicalByteOffset / 8
PhysicalLineAddress = PhysicalBaseAddr + RecordIndex * 10
HostAddress         = PhysicalLineAddress + BeatIndex * 4
```

The last multiplier is `HostBeatBytes`; four is its current value. These are
addresses in the midend host address space, not DRAM row/column or pin-level
addresses. The existing controller handles chip selection and physical access.

For the usual equal bases:

| Logical line base | Mapped physical line base |
| --- | --- |
| `0x80000000` | `0x80000000` |
| `0x80000010` | `0x80000014` |
| `0x80000020` | `0x80000028` |

The beat index is reset for every newly accepted cache command. The next logical
line already maps to its own physical base; carrying the previous operation's
beat count forward would skip backing bytes. The current single-command path
issues its host command with beat index zero; the helper's beat-offset argument
does not imply that additional commands are issued for subsequent words.

```text
PhysicalLineBits  = cmd.records * 80
PhysicalLineBytes = cmd.records * 10
TotalHostBeats    = PhysicalLineBits / 32
```

| Logical payload per line | Records | Physical bytes | Host beats |
| ---: | ---: | ---: | ---: |
| 16 bytes | 2 | 20 | 5 |
| 32 bytes | 4 | 40 | 10 |
| 64 bytes | 8 | 80 | 20 |
| 128 bytes | 16 | 160 | 40 |

`host_req_o.cmd.beats` is this positive count, not count minus one. The command
uses `HyperBurstIncr`, `HyperAtomicNone` and `cmd.size = 2`, meaning four bytes
per beat. The current 32-bit width refers to the host interface, not a claim
that physical HyperBus data pins are always 32 bits wide.

## Write State Sequence

| State | Behavior and exit |
| --- | --- |
| `IDLE` | Report idle. Unless draining, select one command, capture owner/descriptor and clear the line beat counter. Command handshake enters `ISSUE_COMMAND`. |
| `ISSUE_COMMAND` | Offer the mapped full-line host command and hold it stable until accepted. A write enters `SEND_WRITE`; the common write block can accept a record and send its first word on the command-acceptance edge. |
| `SEND_WRITE` | Continue accepting owner records and offering complete host words through the common write block. When registered `count_beat_q == total_host_beats`, enter `WAIT_WRITE_RESPONSE`. |
| `WAIT_WRITE_RESPONSE` | Forward the midend's write completion and error to the owner, with readiness passed back from that cache. Only their completion handshake releases the owner, advances round-robin and returns to `IDLE`. |
| `RECEIVE_READ` | Currently a placeholder, not an implemented refill path. |

The common write block is inside the same `always_comb`, after `endcase`.
It is active in `SEND_WRITE`, or for a write in `ISSUE_COMMAND` when the host
command handshakes. Command/state logic and write data logic therefore do not
need duplicate implementations or a separate first-word retry flag.

While the host command is blocked in `ISSUE_COMMAND`, this implementation does
not yet accept cache write records. Once the command is accepted, the state
advances even if the cache has no record or the midend cannot accept a write
word on that edge. The following send state handles both cases normally.

The send-to-response transition tests the registered beat count. It is not
performed on the same edge as the final data handshake: there is a following
`SEND_WRITE` cycle before entering the response state. Completion can then be
forwarded without an additional `COMPLETE` state or completion-data register.

## Register Buffer and Packing

### Storage and Admission

`write_buffer_t` contains `data[WriteBufferBits-1:0]` and `valid_bits`, a binary
count of occupied bits. `valid_bits` is **not a per-bit validity mask**. Reset
clears the entire struct to zero. Remaining valid bits always occupy the low
end of `data`.

The cache receives `w_ready` only when:

```text
ValidBits <= WriteBufferBits - CacheRecordBits
```

On `cache_req_i[owner].w_valid && cache_rsp_o[owner].w_ready`, the incoming
80-bit `w.record` is inserted starting at the old occupancy offset. Existing
low bits are retained, and occupancy increases by 80. The variable part-select
has a constant 80-bit width; only its starting position varies.

Insertion uses a count-width-to-index-width cast. At a power-of-two capacity,
the occupancy counter needs to represent the full capacity, whereas a data-bit
index only needs to represent capacity minus one. The free-space check makes
the cast safe before an insertion.

The capacity decision uses registered occupancy before any simultaneous host
consumption. This is deliberately conservative: it does not borrow space from
a word that might be accepted on the same edge.

### Sending a Host Word

After appending an accepted record to `write_buffer_d`, the common block checks
whether that working value contains at least `HostDataWidth` valid bits. If so,
it offers the lowest 32 bits as `host_req_o.w.data`, asserts `w_valid` and sets
all `w.strb` bits. The stream contains complete encoded line data; CPU partial
store masks have already been handled inside the cache.

`w_valid` does not wait for `w_ready`. Only a successful host write handshake
shifts the buffer right by 32 bits, subtracts 32 from occupancy and increments
`count_beat_q`. Without that handshake, the offered word remains available.
Appending above existing valid bits must not change a blocked low word.

Using `_d` after insertion allows the first host word to pass through in the
same cycle as the incoming cache record, without first waiting for `_q`.
For the first record of a write:

- If the host word is accepted immediately, retain its remaining 48 bits.
- If the host is not ready, retain all 80 bits and offer the same low word in
  `SEND_WRITE`.
- If no cache record is available, no host write word is offered yet.

### Crossing a Record Boundary

After two words from an 80-bit record have been sent, only 16 bits remain.
Those cannot be padded and sent as a separate word. The next record must be
appended above them; together they provide the next complete host word.

For records A and B in increasing address order, the five host words are:

| Beat | Physical byte offset | `host_req_o.w.data[31:0]` |
| ---: | ---: | --- |
| 0 | 0 | `A[31:0]` |
| 1 | 4 | `A[63:32]` |
| 2 | 8 | `{B[15:0], A[79:64]}` |
| 3 | 12 | `B[47:16]` |
| 4 | 16 | `B[79:48]` |

No bits are discarded or inserted between records. Tags and ECC participate in
this byte stream exactly as stored in `cap_store_t`; they are not separate host
transactions. Payload efficiency remains 80%, even though every host word is
fully used, because the other 20% carries tags and ECC.

`w.last` is generated as `count_beat_q == total_host_beats - 1`. It marks the
last host word, not the last cache record. The existing midend write adapter
uses the supplied marker, so a known `cmd.beats` does not eliminate this field
from the present interface. Cache-side `w.last` is not currently checked or
used by the arbiter; the producer must supply exactly `cmd.records` records.

## Completion and Backpressure

There are three different events:

1. A cache record is accepted into the arbiter's register buffer.
2. A 32-bit host word is accepted by the midend.
3. The midend returns final write status, and the selected cache accepts it.

Only the third event releases ownership. A buffer becoming empty, the last
host word being accepted or the beat counter reaching its limit does not by
itself establish successful write completion.

In `WAIT_WRITE_RESPONSE`, the RTL connects:

```systemverilog
cache_rsp_o[selected_port_q].done_valid = host_rsp_i.wrsp_valid;
cache_rsp_o[selected_port_q].done.error =
    (host_rsp_i.wrsp.resp != hyperbus_pkg::HyperRespOkay);
host_req_o.wrsp_ready = cache_req_i[selected_port_q].done_ready;
```

These are same-cycle connections, not three additional pipeline stages.
Completion availability travels from midend to cache; acceptance readiness
travels from cache to midend. Ready does not request that an operation start
or that a completion be generated. It can be asserted before valid arrives.

| Midend `wrsp_valid` | Cache `done_ready` | Result |
| ---: | ---: | --- |
| 0 | 1 | Cache is ready, but there is no completion; remain waiting |
| 1 | 0 | Completion is offered to the cache, but neither side consumes it; owner remains locked |
| 1 | 1 | Both sides accept the same completion at the clock edge; advance round-robin and enter `IDLE` |

The current midend already contains `i_host_wrsp_fifo` for holding completion
responses. This is not the arbiter's write buffer and not the D-cache's
write-back read-ahead FIFO. A nonempty response FIFO means final status is
available; an empty response FIFO means no status is currently available. Its
`valid_o` is derived from nonemptiness, not from downstream readiness. There is
no new response FIFO to instantiate in the arbiter.

All non-`HyperRespOkay` statuses produce `done.error = 1`. The error is meaningful
only with `done_valid`. The arbiter does not retry, correct ECC, change cache
metadata or perform cache error recovery. It returns to `IDLE` after an
accepted error completion too. The current D-cache asserts on an accepted
write-back error in simulation; actual cache recovery remains separate work.

## Drain and Reset

`drain_i` blocks command acceptance only in `IDLE`. An accepted operation
continues to send records, wait for final status and wait for the cache's
completion acceptance even if drain becomes high. Drain does not cancel a
command or force an early owner release.

`idle_o` is high whenever the FSM is in `IDLE`, including while drain is high.
It is low throughout an owned operation, including completion backpressure.
It describes this arbiter, not an independent proof that every downstream
controller or cache has been reset or flushed.

Reset clears the FSM, saved descriptor, selected port, round-robin start,
line beat count and write buffer. No downstream response flush/recovery
protocol is implemented here. Reset must be coordinated with caches and the
midend so that an old response cannot be assigned to a later request.

## Buffer Sweeps and Hardware Trade-Offs

The current 80-/32-bit packing requires at least 96 buffer bits: 16 remaining
bits plus the next complete 80-bit input record. A smaller buffer can get stuck
with too few bits to send and too little room to append. The module emits an
elaboration diagnostic for `WriteBufferBits < 96`; no power-of-two capacity is
required.

| `WriteBufferBits` | Occupancy bits | Declared data + occupancy state |
| ---: | ---: | ---: |
| 96 | 7 | 103 bits |
| 128 | 8 | 136 bits |
| 160 | 8 | 168 bits |
| 320 | 9 | 329 bits |

Larger buffers permit earlier acceptance of additional cache records and can
absorb finite upstream gaps. They do not accelerate the physical memory or
guarantee continuous host readiness. No preload threshold is used: sending
starts as soon as one complete host word is available. A bigger buffer therefore
does not guarantee that it will be full before a later cache-data pause.

The declared state sizes exclude owner/count/FSM state and combinational logic.
Dynamic insertion and wider storage can increase selection/routing cost and
timing pressure. The same-cycle first-word path runs from the cache output
through packing to the host output. Completion also has combinational paths in
both directions. Measure synthesis area, critical paths, buffer occupancy,
host-starvation cycles, line latency and workload runtime before choosing a
larger default. Register-bit counts are not physical area measurements.

Configure an instance with `.WriteBufferBits(160)`, for example. A simulation
top can expose and forward this parameter for `-GWriteBufferBits=160` sweeps.
That top-level forwarding is required; the unconnected Croc SoC does not yet
offer this as a full-SoC build option. Every size requires re-elaboration/build,
not a runtime setting. Sweep this buffer independently of the D-cache's
`WritebackFifoDepth`; the two buffers serve different stages of the path.

## Preconditions and Remaining Work

The present write implementation assumes a valid complete-line request and
well-behaved valid/ready producers. In particular:

- `NumPorts` is positive and packet fields match their configured widths.
- Logical line bases are correctly aligned and inside the backing region.
- `cmd.records` is positive and produces a whole number of host words. With
  80-bit records and a 32-bit host, it must be even; current cache lines have
  at least two records.
- Expanded addresses do not overflow and fit the controller's configured chip
  ranges and physical memory capacity.
- The full host-beat count fits the host-command and controller transfer limits.
  A sufficiently wide local counter alone does not establish that limit.
- The cache supplies exactly the requested records in order and holds valid
  data stable until accepted. Extra or missing records are not recovered here.
- The midend holds a completion stable until the arbiter accepts it.

Except for the write-buffer minimum, these assumptions are not comprehensively
enforced by arbiter elaboration or runtime checks. Incoming record `last`,
record totals and unexpected response ordering still need protocol assertions.
There is no timeout, cancel, retry or fault-recovery state.

Only the 80-bit-record / 32-bit-host format has been validated. A different
`HostDataWidth` requires rechecking buffer capacity, integral transfer lengths,
packet widths and serialization. The current 96-bit minimum is not a general
capacity formula for other host widths.

`RECEIVE_READ` remains unimplemented. A read command can currently be accepted
and reach that state, but no read records or completion are returned. Do not
connect this draft as a working I-cache/refill backend yet. Read unpacking and
its final owner/round-robin handover must be implemented before that integration.

The module is not yet in the normal Bender module list or instantiated in the
SoC. Existing uncached HyperRAM tests do not exercise this cache path. I-cache
implementation, cache maintenance/coherence, backing initialization and
end-to-end data-plus-tag ECC integration are not supplied by this arbiter.

## Verification Scope

An isolated Verilator 5.042 test exercised the actual write datapath and
completion bridge with a C++ cache/midend driver. It covered 96/128/160/320-bit
buffers and four sequential writes per size: 16 operations, 40 records and 100
host beats per operation, for 1,600 checked 32-bit beats in total. The driver
checked record-boundary packing, command address/length, host strobes and final
`last`, cache-data gaps, host backpressure, simultaneous command/first-word
acceptance, error-status forwarding and subsequent writes without another
reset. It held cache completion readiness low for eight cycles and checked
that status remained offered and ownership was not released.

Buffer sizes 0, 80 and 95 produced the expected minimum-size diagnostic. The
negative lint checks promoted Verilator's `USERERROR` diagnostic to an error;
`-Wno-fatal` must not silently suppress that configuration check.

The driver supplied midend responses rather than instantiating the actual
midend, backend or HyperRAM model. Traffic used port 0, with the other port
checked inactive. The round-robin update was source-reviewed; competing-port
fairness and non-power-of-two port counts were not clocked RTL-tested. The
temporary harness is not a checked-in regression or a measurement of bus
performance. Existing unrelated RTL width warnings remain.

Before integration, add maintained tests for simultaneous ports, sparse request
masks, fair handover after blocked/error completion, one and three ports,
different cache line sizes, reset/drain in each phase, malformed record streams
and the actual midend/HyperRAM write path. These are additional verification
gates, not claims that the current read path or full subsystem is complete.
