#!/usr/bin/env python3
"""Count switching activity on the crossbar/SRAM address nets and weight it with
the extracted capacitance from the SPEF.

This isolates the effect the burst address compression is supposed to have:
croc_domain.sv forces the iDMA's crossbar address to a constant
(xbar_mgr_obi_req[5].a.addr = ReadEpAddr), while a CPU access drives a fresh
address every time. Comparing total power between the two runs does not show
that cleanly - the DMA moves data faster and toggles the data bus harder, so the
average power can even be higher. Counting transitions on the address nets only,
weighted by their real wire capacitance, answers the question directly:

    E_addr = 0.5 * C_net * VDD^2 * transitions        summed over the address nets

Usage:
    addr_toggles.py <croc.spef> <run.vcd> [<run2.vcd> ...]

Nets are selected by name substring; adjust NET_PATTERNS for a different bus.
"""

import re
import sys

VDD = 1.2                      # sg13g2 typ_1p20V
NET_PATTERNS = ("b0_addr_", "b1_addr_")


def spef_caps(path):
    """net name -> total capacitance in farads."""
    name_of = {}
    caps = {}
    # SPEF header gives the unit, e.g. "*C_UNIT 1 PF"
    scale = 1e-12
    with open(path, errors="replace") as fh:
        for line in fh:
            if line.startswith("*C_UNIT"):
                parts = line.split()
                if len(parts) >= 3:
                    mult = float(parts[1])
                    unit = parts[2].upper()
                    scale = mult * {"F": 1.0, "MF": 1e-3, "UF": 1e-6,
                                    "NF": 1e-9, "PF": 1e-12, "FF": 1e-15}[unit]
            elif line.startswith("*") and not line.startswith("*D_NET"):
                # name map entries look like "*10031 i_croc_soc/i_croc/b0_addr_5_"
                m = re.match(r"\*(\d+)\s+(\S+)\s*$", line)
                if m:
                    name_of[m.group(1)] = m.group(2)
            elif line.startswith("*D_NET"):
                parts = line.split()
                if len(parts) >= 3 and parts[1].startswith("*"):
                    nid = parts[1][1:]
                    name = name_of.get(nid)
                    if name and any(p in name for p in NET_PATTERNS):
                        caps[name] = float(parts[2]) * scale
    return caps


def vcd_transitions(path):
    """vcd net name -> number of value changes, plus the covered time window."""
    ids = {}                   # vcd symbol -> net name
    counts = {}
    first_t = last_t = None

    with open(path, errors="replace") as fh:
        # header: collect the symbols of the nets we care about
        for line in fh:
            if line.startswith("$var"):
                parts = line.split()
                # $var wire 1 <sym> <name> $end
                if len(parts) >= 6:
                    sym, name = parts[3], parts[4]
                    if any(p in name for p in NET_PATTERNS):
                        ids[sym] = name
                        counts[name] = 0
            elif line.startswith("$enddefinitions"):
                break

        if not ids:
            return counts, None, None

        # body: count scalar changes on those symbols
        for line in fh:
            c = line[0]
            if c == "#":
                t = int(line[1:])
                if first_t is None:
                    first_t = t
                last_t = t
            elif c in "01xXzZ":
                sym = line[1:].strip()
                name = ids.get(sym)
                if name is not None:
                    counts[name] += 1

    return counts, first_t, last_t


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1

    spef, vcds = sys.argv[1], sys.argv[2:]

    print(f"reading {spef} ...", flush=True)
    caps = spef_caps(spef)
    if not caps:
        print("no matching nets found in SPEF - check NET_PATTERNS")
        return 1
    total_c = sum(caps.values())
    print(f"  {len(caps)} address nets, total {total_c*1e15:.1f} fF, "
          f"mean {total_c/len(caps)*1e15:.1f} fF per net\n")

    results = []
    for vcd in vcds:
        print(f"scanning {vcd} ...", flush=True)
        counts, t0, t1 = vcd_transitions(vcd)
        if not counts:
            print("  no matching nets in VCD - skipped\n")
            continue

        total_tr = sum(counts.values())
        energy = sum(0.5 * caps.get(n, 0.0) * VDD**2 * c for n, c in counts.items())
        window = (t1 - t0) if (t0 is not None and t1 is not None) else 0
        results.append((vcd, total_tr, energy, window, counts))

        print(f"  window     {t0} .. {t1} ns  ({window/1000:.1f} us)")
        print(f"  transitions {total_tr}")
        print(f"  energy      {energy*1e9:.3f} nJ")
        print(f"  avg power   {energy/(window*1e-9)*1e3:.3f} mW\n" if window else "")

    if len(results) == 2:
        (n1, t1_, e1, w1, _), (n2, t2_, e2, w2, _) = results
        print("=" * 62)
        print(f"{'':22}{'transitions':>14}{'energy [nJ]':>14}{'power [mW]':>12}")
        for name, tr, e, w, _ in results:
            p = e / (w * 1e-9) * 1e3 if w else 0.0
            print(f"{name.split('/')[-1][:22]:22}{tr:>14}{e*1e9:>14.3f}{p:>12.3f}")
        print("=" * 62)
        if t1_ and t2_:
            print(f"transition ratio : {t2_/t1_:.2f}x")
        if e1:
            print(f"energy ratio     : {e2/e1:.2f}x")

    return 0


if __name__ == "__main__":
    sys.exit(main())
