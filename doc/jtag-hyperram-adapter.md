# JTAG HyperRAM Adapter

Updated: 10 November 2026. This describes the implemented adapter and its current
SoC connections, not a completed firmware boot or cache-coherence sign-off.

## Why It Is Needed

The D-cache is write-back. A JTAG loader writing through it can receive successful
OBI responses while the program bytes still reside only in dirty cachelines.
The separate read-only I-cache refills from HyperRAM, not from the D-cache. It
could therefore fetch old or uninitialized instructions after loading. A JTAG
readback through the D-cache would not establish that HyperRAM contains the new
program either: it could read the same dirty cacheline.

[`jtag_hyperram_adapter.sv`](../rtl/cache/jtag_hyperram_adapter.sv) gives the loader
an uncached path to the shared HyperBus arbiter. It translates 32-bit OBI accesses
into the encoded record stream expected by the arbiter. It is not a JTAG TAP or
debug controller: JTAG is already decoded by the existing debug module, whose
system-bus-access interface generates the OBI requests.

The I-cache remains read-only. Program loading does not require adding stores,
dirty bits or write-back logic to it.

## Connections and Address Routing

The CPU-visible HyperRAM address range remains
`0x80000000 <= address < 0x90000000`. No overlapping address-map rule or separate
loader address window is added. The existing decoder still selects
`XbarHyperbus`; input-specific remapping chooses the final subordinate.

| Requester / crossbar input | HyperRAM subordinate | Arbiter port |
| --- | --- | ---: |
| CPU data / input 2 | `XbarHyperbus = 4`, D-cache | 0 |
| CPU instructions / input 3 | `XbarICache = 5`, I-cache | 1 |
| JTAG debug system bus / input 1 | `XbarJtagHyperram = 6`, adapter | 2 |

Other managers' HyperRAM accesses still reach the D-cache. JTAG accesses to
HyperBus configuration registers, SoC control and other peripherals retain
their ordinary address-decoder result; they do not enter the adapter.

[`croc_pkg.sv`](../rtl/croc_pkg.sv) includes the new subordinate in the seven-output
crossbar. [`obi_xbar.sv`](../rtl/obi/obi_xbar.sv) applies the second remap using
`Remap2Enable`, input 1, `Remap2From = XbarHyperbus` and
`Remap2To = XbarJtagHyperram`. The original instruction remap stays enabled.
The crossbar's existing demux/mux response tracking remains responsible for the
return path; responses are not selected from the address of a newer request.

[`croc_domain.sv`](../rtl/croc_domain.sv) connects the adapter's OBI side with
`sbr_obi_req_t` / `sbr_obi_rsp_t`, and its memory side with the same
`mem_req_t` / `mem_rsp_t` used by the caches. `cache_mem_arbiter.NumPorts` is 3.
The arbiter connects directly to the existing HyperBus midend, backend and PHY;
the old HyperBus OBI frontend is not in this path. The required module files are
listed in the root [`Bender.yml`](../Bender.yml).

## Buffer and Stored Format

`BlockDataBytes` counts logical payload bytes, excluding tags and ECC. Its
default is 16 bytes: four 32-bit OBI words. The adapter holds one such aligned
block in `write_buffer_q`, containing its logical `base_addr`, `word_valid` bits
and an array of `cache_pkg::cap_word_t` words.

Each stored word contains 32 data bits, one capability tag and seven ECC bits.
Two stored words form one 80-bit `cap_store_t` record. Thus the default buffer
represents 16 logical bytes in two records, or 20 physical bytes. The arbiter
packs these records into five 32-bit host beats under one host command.

The adapter passes the aligned **logical** block address in `cmd.line_addr`.
Only the arbiter performs the 8-logical-byte to 10-physical-byte address
expansion. For equal logical/physical bases at `0x80000000`, logical block
`0x80000010` starts at physical host address `0x80000014`. Applying this expansion
in the adapter as well would map the address twice.

`word_valid` marks buffered words to be written. It is not a byte mask, SRAM
address tag, or persistent read-cache valid array. Reset clears the buffer and
its valid bits; an OBI response does not clear them.

## Writes and Byte Enables

An OBI request is accepted only on `obi_req_i.req && obi_rsp_o.gnt`. The complete
address channel, including `aid`, is captured in `obi_a_q`. The adapter handles
one OBI request at a time and grants new requests only in `IDLE`.

A full-word write replaces the selected buffered word without first reading
HyperRAM. Repeated writes to the same slot replace that slot. A write to a
different block first commits the old buffer, then inserts the saved new request
into the now-free buffer. The new word remains in `obi_a_q` while that old-block
write is in progress; it is not discarded or accidentally written to the old
address.

For a partial write, `a.be` selects the data byte lanes. The adapter does not
shift data a second time. If the target word is already buffered, the old bytes
are available locally. Otherwise it reads the aligned block from HyperRAM and
retains the target word before merging. Only enabled bytes are replaced; the
other bytes of that 32-bit word remain unchanged. This old-word read is not
needed for full-word input.

After merging, the adapter regenerates ECC for the complete 32-bit result using
`prim_secded_pkg::prim_secded_inv_39_32_enc`. Every JTAG-written word receives
capability tag zero, even if the data resembles a capability. The adapter is a
program/data loader, not a facility for manufacturing tagged capabilities. It
does not use incoming OBI capability tags or ECC to create the stored word.

The current encoder protects the 32 data bits, not the capability tag. The
adapter neither checks nor corrects old-word ECC before a partial update. Core
ECC wiring and tag coverage remain separate integration work.

### Committing a Buffer

A buffer is written when all its words are valid, when a new write targets a
different block, or before servicing an explicit read. The command always
announces `RecordsPerBlock`, including records with missing words. There is no
optimization that shortens a sparse buffer into a smaller transfer.

`mem_req_o.w_strb` prevents those missing words from changing memory. For each
record, the lower word's valid bit is replicated across its five physical byte
strobes; the upper word's bit controls the other five. The arbiter packs these
strobes alongside the data and forwards them as host `w.strb`. A masked word
preserves all its existing data, tag and ECC bytes, even though the burst still
transfers its positions. An entirely masked record is allowed in this fixed-size
transfer.

`w_valid`, record data, mask and `w.last` stay stable until `w_ready` accepts
them. The record index advances only on that handshake. Accepting the final
record does not complete the HyperRAM write: the adapter waits for
`done_valid && done_ready` and examines `done.error` before clearing valid bits.

## Posted Responses and the Loader Barrier

Writes to an unfilled buffer receive an early OBI response, allowing the debug
module to send more words. This response means **the adapter buffered the word**,
not that the HyperRAM write has completed. The word that fills a buffer is
answered only after that buffer's write completion.

The last buffer may contain only one, two or three words. It must not be left
pending when the CPU starts. A read provides the explicit completion barrier:

1. The adapter commits any pending write buffer, using its word-valid masks.
2. It waits for successful write completion from the arbiter/midend.
3. It issues the requested block read and receives all records and final status.
4. It returns the selected 32-bit word with its stored tag/ECC and the read's ID.
5. Only after that successful read response may the loader release the CPU.

[`croc_vip.jtag_load_hex`](../rtl/test/croc_vip.sv) performs an aligned read of
the last loaded word after sending all bytes of a nonempty image. This drains
the final posted buffer before the loading task returns. A read of another
HyperRAM block also drains earlier buffered writes; it is not necessary to read
the same block. Other loaders must perform an equivalent successful read before
starting execution. There is no new flush register or flush port.

Explicit reads are real memory operations, including JTAG readback. They must
not be interpreted as writes or answered with fabricated zero data.

## State Sequence

| State | Responsibility |
| --- | --- |
| `IDLE` | Grant and capture one OBI request; clear its saved error status. |
| `BUFFER_WRITE` | Dispatch reads; validate writes; commit an old block on an address change; merge the pending write or request its old word. |
| `SEND_WRITE_CMD` | Hold the buffered block's write command until accepted; reset the record index. |
| `SEND_WRITE_DATA` | Offer records and word-derived byte strobes; mark the final record; advance only when accepted. |
| `WAIT_WRITE_DONE` | Wait for final status. Clear valid bits only on success; then answer, service a read, or insert the saved new-block write. |
| `SEND_READ_CMD` | Offer the requested block's read command; reset the record index on acceptance. |
| `WAIT_READ_DATA` | Receive the announced records and capture the target word, without replacing other buffered write words. |
| `WAIT_READ_DONE` | Wait for final status; either answer the explicit read or return to the pending partial-write merge. |
| `RESPOND` | Pulse OBI `rvalid` for one cycle, return the captured `aid` as `rid`, and return to `IDLE`. |

Store responses contain zero data and its matching ECC `0x2A`; error responses
also return zero data/tag with that ECC. Successful reads return stored data,
tag and ECC rather than regenerating ECC from the read data.

## Errors, Reset and Configuration

An empty write mask or a misaligned full-word write produces an OBI error without
performing that write. Read/write completion errors are returned in `r.err`.
A failed old-word read does not merge or write the pending partial store. A failed
buffer commit retains its valid bits, and a dependent read or new-block write
does not proceed as if the commit had succeeded. There is no automatic retry;
a later explicit request can cause the retained buffer to be written again.

Posted errors cannot be retroactively attached to earlier OBI responses. A
commit failure is reported on the request that triggered the commit, which may
be the loader's final barrier read. The loader must treat failure of that read
as a failed load, not start the CPU regardless of its status.

Reset discards pending buffered writes rather than committing them. Reset must
be coordinated with the arbiter/midend. The adapter's `IDLE` is not a flush
acknowledgement: it may be idle with a partially filled write buffer.

Current support is 32-bit OBI data and a power-of-two `BlockDataBytes` of at least
16, with matching OBI field widths and a memory command wide enough to represent
the full record count. The SoC currently uses the default 16-byte block and
the caches' shared two-bit record-count field. Increasing the block beyond 16
also requires widening that shared field. The checks in
[`jtag_hyperram_adapter_param_checks.svh`](../rtl/cache/jtag_hyperram_adapter_param_checks.svh)
remain active through an include inside the module.

## Boot Assumptions and Verification Boundary

Configure HyperBus before loading. Keep the CPU halted and cache valid bits
clear during initial loading; complete the read barrier before CPU start.
Direct writes to HyperRAM do not invalidate an already populated I-cache or
update a dirty D-cache. Live code patching, DMA interaction and cache maintenance
need their own synchronization contract. This adapter does not implement
`FENCE.I`, cache snooping, instruction/data coherence, or initialization of tags
in otherwise unwritten HyperRAM.

Standalone tests live outside this repository in `../croc-jtag-tests`:

- `run_tests.sh`: adapter, actual three-port arbiter and actual midend, with a
  memory-backed backend-link responder. The 21-run matrix passed, covering
  full/partial writes, sparse masks, address changes, final barriers, IDs,
  stalls, completion errors, reset and competing arbiter ports.
- `run_routing_tests.sh`: actual Croc package and OBI crossbar, with synthetic
  subordinate responses. Six runs passed, totaling 21,600 requests/responses,
  checking both enabled and disabled JTAG remapping and response routing.

These are separate downstream-path and routing tests, not a single full-SoC
JTAG/firmware run. `croc_domain` also passed lint/elaboration with the actual
cache and IHP SRAM sources, with warnings retained. The JTAG TAP, complete boot
sequence, physical HyperRAM timing and ASIC timing/area are not signed off by
those checks.
