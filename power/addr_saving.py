#!/usr/bin/env python3
"""Estimate what the address traffic would have cost without the compression.

croc_domain.sv holds the iDMA's crossbar address constant:

    xbar_mgr_obi_req[5].a.addr = ReadEpAddr;

so the address is sent once per burst instead of once per beat, and the
per-beat address is regenerated locally inside burst_endpoint_rw:

    read_addr_d = read_addr_q + 4;

That local counter carries exactly the address sequence the crossbar did not
have to transport. Counting its transitions in the VCD gives the toggle count
the compression avoided; weighting it with the capacitance of a real routed
address wire from the SPEF turns it into an energy figure:

    E = 0.5 * C * VDD^2 * toggles

This is an ESTIMATE, not a measurement of two builds: it uses real toggle counts
and real extracted capacitance from this layout, but assumes an uncompressed
crossbar address wire would look like the routed address wires that exist.

Usage:
    addr_saving.py <croc.spef> <run.vcd>
"""

import re
import sys

VDD = 1.2                          # sg13g2 typ_1p20V

# routed address wires that exist in the layout - used for the capacitance model
CAP_PATTERNS = ("i_croc_soc/i_croc/b0_addr_", "i_croc_soc/i_croc/b1_addr_")

# the endpoint's local address counters - the sequence the crossbar was spared
TOGGLE_PATTERNS = ("endpoint_sram_bank_0.read_addr_q_",
                   "endpoint_sram_bank_0.write_addr_q_",
                   "endpoint_sram_bank_1.read_addr_q_",
                   "endpoint_sram_bank_1.write_addr_q_")


def spef_caps(path, patterns):
    """net name -> capacitance in farads, for nets matching any pattern."""
    scale = 1e-12                  # default *C_UNIT 1 PF
    name_of, caps = {}, {}
    with open(path, errors="replace") as fh:
        for line in fh:
            if line.startswith("*C_UNIT"):
                p = line.split()
                mult, unit = float(p[1]), p[2].upper()
                scale = mult * {"F": 1.0, "MF": 1e-3, "UF": 1e-6,
                                "NF": 1e-9, "PF": 1e-12, "FF": 1e-15}[unit]
            elif line.startswith("*D_NET"):
                p = line.split()
                if len(p) >= 3 and p[1].startswith("*"):
                    nm = name_of.get(p[1][1:])
                    if nm and any(nm.startswith(x) for x in patterns):
                        caps[nm] = float(p[2]) * scale
            elif line.startswith("*") and " " in line:
                m = re.match(r"\*(\d+)\s+(\S+)\s*$", line)
                if m:
                    name_of[m.group(1)] = m.group(2)
    return caps


def vcd_toggles(path, patterns):
    """net name -> transition count, plus the time window covered."""
    ids, counts = {}, {}
    t_first = t_last = None
    with open(path, errors="replace") as fh:
        for line in fh:
            if line.startswith("$var"):
                p = line.split()
                if len(p) >= 6:
                    sym, name = p[3], p[4]
                    if any(x in name for x in patterns):
                        ids[sym] = name
                        counts[name] = 0
            elif line.startswith("$enddefinitions"):
                break
        if not ids:
            return counts, None, None
        for line in fh:
            c = line[0]
            if c == "#":
                t = int(line[1:])
                if t_first is None:
                    t_first = t
                t_last = t
            elif c in "01xXzZ":
                nm = ids.get(line[1:].strip())
                if nm is not None:
                    counts[nm] += 1
    return counts, t_first, t_last


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 1
    spef, vcd = sys.argv[1], sys.argv[2]

    print(f"[1/2] capacitance model from {spef}", flush=True)
    caps = spef_caps(spef, CAP_PATTERNS)
    if not caps:
        print("  no routed address nets found - check CAP_PATTERNS")
        return 1
    c_mean = sum(caps.values()) / len(caps)
    c_min, c_max = min(caps.values()), max(caps.values())
    print(f"  {len(caps)} routed address wires")
    print(f"  mean {c_mean*1e15:7.2f} fF   (min {c_min*1e15:.2f}, max {c_max*1e15:.2f})\n")

    print(f"[2/2] toggle counts from {vcd}", flush=True)
    counts, t0, t1 = vcd_toggles(vcd, TOGGLE_PATTERNS)
    if not counts:
        print("  no endpoint address counters found in VCD - check TOGGLE_PATTERNS")
        return 1
    total = sum(counts.values())
    window_ns = (t1 - t0) if (t0 is not None and t1 is not None) else 0
    print(f"  {len(counts)} counter bits, window {t0}..{t1} ns ({window_ns/1000:.1f} us)")
    print(f"  {total} transitions\n")

    energy = 0.5 * c_mean * VDD**2 * total
    power = energy / (window_ns * 1e-9) if window_ns else 0.0

    print("=" * 64)
    print("Address traffic the compression avoided on the crossbar")
    print("=" * 64)
    print(f"  transitions           {total}")
    print(f"  capacitance per wire  {c_mean*1e15:.2f} fF   (routed address wire, from SPEF)")
    print(f"  VDD                   {VDD} V")
    print(f"  energy                {energy*1e9:.3f} nJ")
    print(f"  average power         {power*1e3:.4f} mW   over {window_ns/1000:.1f} us")
    print("=" * 64)
    print("\nEstimate: real toggle counts and real extracted capacitance from this")
    print("layout, assuming an uncompressed crossbar address wire is comparable to")
    print("the routed address wires that exist. Not a two-build measurement.")

    print("\nper counter bit:")
    for nm in sorted(counts):
        print(f"  {counts[nm]:>10}  {nm.split('.')[-1]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
