# Power & Energy — Burst DMA Methods (croc, IHP SG13G2)

Post-layout power analysis with extracted parasitics (PrimeTime PX, time-based).
Two burst-DMA optimizations, both compared against **bare croc** (no burst optimization):


---

## Small transfer — one 512 B memcpy

*What is measured:* a single iDMA memcpy of 512 B. Only the **DMA transfer window** is measured
— the CPU init/verify loops around it are excluded (a software marker starts/stops the trace
right around the transfer). Power is the average over that window; energy = power × window time.

**Method 1 (Khanh)** — burst framing. Changes in RTL from bare croc:
1. `BurstMode = OBI_BURST_BEAT_FRAMED`, add burst metadata to `idma_legalizer_rw_obi`.
2. Modify `obi_mux` to allow multiple sbr ports to stay locked together (in our case iDMA
   read and write).
3. Change `obi_rready_converter` depth 1 → 2 (to sustain back-to-back read/write).

| Config | Power (mW) | Energy (nJ) |
|---|---:|---:|
| bare croc | 6.26 | 131.1 |
| blen = 0 | 6.64 | 95.3 |
| blen = total | 6.68 | 95.8 |

**Method 2 (Pascal)** — address compression. The iDMA holds the crossbar address constant over
a burst; the endpoint regenerates the per-beat address locally 

| Config | Power (mW) | Energy (nJ) |
|---|---:|---:|
| bare croc | 6.27 | 130.7 |
| Method 2 | 6.81 | 157.9 |

*Result:* Method 1 saves energy vs its bare (−27 %, it speeds the transfer up). Method 2 costs
energy vs its bare (+28 %) — a single small transfer is its worst case, the burst overhead
dominates without a throughput gain.

---

## Large transfer — 256 B repeated 50× (≈13 kB total)

*What is measured:* one 2D iDMA transfer of 256 B repeated 50× (≈13 kB moved). Power over the
**whole program execution** (the 50 transfers dominate the window); energy = power × window time.

**Method 1 (Khanh)** — burst framing (same RTL changes as above).

| Config | Power (mW) | Energy (µJ) |
|---|---:|---:|
| Method 1 | 6.69 | 3.128 |

**Method 2 (Pascal)** — address compression (same as above).

| Config | Power (mW) | Energy (µJ) |
|---|---:|---:|
| bare croc | 6.10 | 3.361 |
| Method 2 | 6.68 | 3.233 |

*Result:* on the large transfer both methods are essentially level — Method 1 6.69 mW /
3.128 µJ, Method 2 6.68 mW / 3.233 µJ (Method 2 +3.4 % energy). Method 2 also saves −3.8 %
energy vs its own bare croc. So where Method 2 loses badly on the small transfer, it becomes
competitive on the large one.

---

## Address-bus effect (Method 2 only)

*What is measured:* the **same design run twice on one netlist** — the crossbar address held
constant (with burst) vs toggling per beat (without burst). Isolated this way there is no
place-and-route noise; the difference is purely the address activity. The address bus switches
**12 847 times without burst vs 7 with burst (−99.95 %)**.

| Metric | without burst | with burst | Δ (saved) |
|---|---:|---:|---:|
| Power (mW) | 6.7199 | 6.7180 | 0.0019 |
| Energy (µJ) | 3.2534 | 3.2524 | 0.00094 |

*Result:* the compression saves **1.9 µW / 0.94 nJ** on the address wires (Δ column) — a small,
orthogonal effect: Method 2's energy advantage on the large transfer comes almost entirely from
the burst's throughput (12 % fewer cycles), not from this address saving (≈ 0.7 % of it).
---

## What is comparable, and what is not

- **Comparable:** energy for the *same* workload (the same amount of data is moved), and each
  method against its *own* bare-croc baseline. The relative deltas (method vs its bare) are the
  robust numbers.
- **The bare-croc baselines agree** (6.26 vs 6.28 mW on the small transfer), which shows the two
  measurement setups are consistent.
- **Not fully fair:** Method 1 and Method 2 are *different designs*. Each was synthesised and
  placed-and-routed separately, so the extracted parasitics (wire lengths, capacitances) differ.
  Absolute power therefore carries some place-and-route noise and should not be read as an exact
  head-to-head.
- The two methods **optimise different things** — throughput (M1) vs address-bus energy (M2) —
  so "better/worse" depends on the metric and the workload.


