#!/usr/bin/env python3
"""Compare two cache evaluations of scripts/run_cache_eval.sh.

Joins the area and performance results of both evaluations per cache, ways,
sets and line size. The differences go to
cache_eval/comparisons/<base>_vs_<new>/comparison.csv and a summary to
report.txt next to it; a comparison of the same two evaluations is replaced.
"""

import argparse
import csv
import math
import statistics
import sys
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple


EVAL_ROOT = Path(__file__).resolve().parent.parent / "cache_eval"
PHASES = ["init", "stream", "copy", "stride", "random", "chase", "capabilities", "code"]
AREAS = ["total_um2", "stdcell_um2", "sram_um2"]

Key = Tuple[str, int, int, int]
Row = Dict[str, str]


def resolve_eval(name: str) -> Path:
    """Resolve an evaluation name such as 20261113_162446 or latest, or a path."""

    path = Path(name)
    if not path.is_dir():
        path = EVAL_ROOT / name
    if not path.is_dir():
        sys.exit(f"[ERROR][Cache compare] No evaluation {name}")
    return path.resolve()


def read_csv(path: Path) -> List[Row]:
    """Read a sweep CSV, also when an editor padded it or saved it with CRLF."""

    with path.open(newline="") as f:
        return [{k.strip(): v.strip() for k, v in row.items()} for row in csv.DictReader(f)]


def load_eval(path: Path) -> Dict[Key, Row]:
    """Merge the area and performance rows of every sweep in an evaluation."""

    rows: Dict[Key, Row] = {}
    for part in ("area", "performance"):
        for csv_path in sorted((path / part).glob("*w.csv")):
            cache, ways = csv_path.stem.rsplit("_", 1)
            for row in read_csv(csv_path):
                key = (cache, int(ways[:-1]), int(row["sets"]), int(row["line_bytes"]))
                if part == "performance":
                    row["perf_status"] = row.pop("status")
                rows.setdefault(key, {}).update(row)
    return rows


def code_state(path: Path, sweep: str) -> str:
    """Describe the commits and uncommitted RTL files an evaluation measured."""

    states = []
    for part in ("area", "performance"):
        info = path / part / f"{sweep}_info.txt"
        if not info.is_file():
            continue
        commits, rtl = [], []
        for line in info.read_text().splitlines():
            if line.startswith("commit:"):
                commits.append(line.split(":", 1)[1].strip())
            elif line.startswith("    ") and "rtl/" in line:
                rtl.append(Path(line.split()[-1]).name)
        state = ", ".join(dict.fromkeys(commits))
        if rtl:
            state += " + uncommitted " + ", ".join(dict.fromkeys(rtl))
        states.append(f"{part} {state}")
    return "; ".join(states) or "no info files"


def number(row: Optional[Row], column: str) -> Optional[float]:
    """Return a column as a number, or None for missing or failed runs."""

    if row is None or column not in row:
        return None
    if (column in PHASES or column == "total_cycles") and row.get("perf_status") != "ok":
        return None
    try:
        return float(row[column])
    except ValueError:
        return None


def ratio(a: Optional[float], b: Optional[float]) -> Optional[float]:
    return a / b if a is not None and b else None


def change_pct(base: Optional[float], new: Optional[float]) -> Optional[float]:
    return (new - base) / base * 100 if base and new is not None else None


def compare(base: Dict[Key, Row], new: Dict[Key, Row]) -> List[Dict[str, object]]:
    """Compute the differences for the configurations both evaluations have."""

    rows = []
    for key in sorted(set(base) & set(new)):
        b, n = base[key], new[key]
        row: Dict[str, object] = {
            "cache": key[0], "ways": key[1], "sets": key[2], "line_bytes": key[3],
            "cache_bytes": key[1] * key[2] * key[3],
        }
        for column in AREAS:
            row[f"{column}_base"] = number(b, column)
            row[f"{column}_new"] = number(n, column)
            row[f"{column}_change_pct"] = change_pct(number(b, column), number(n, column))
        row["total_cycles_base"] = number(b, "total_cycles")
        row["total_cycles_new"] = number(n, "total_cycles")
        row["speedup"] = ratio(row["total_cycles_base"], row["total_cycles_new"])
        for phase in PHASES:
            row[f"{phase}_speedup"] = ratio(number(b, phase), number(n, phase))
        # Above 1 when the new configuration needs less area times cycles.
        at_base = product(row["total_cycles_base"], row["total_um2_base"])
        at_new = product(row["total_cycles_new"], row["total_um2_new"])
        row["area_time_gain"] = ratio(at_base, at_new)
        rows.append(row)
    return rows


def product(a: Optional[float], b: Optional[float]) -> Optional[float]:
    return a * b if a is not None and b is not None else None


def csv_value(column: str, value: object) -> str:
    if value is None:
        return ""
    if not isinstance(value, float):
        return str(value)
    if column.endswith("_pct"):
        return f"{value:.2f}"
    if column.endswith(("speedup", "gain")):
        return f"{value:.4f}"
    if column.startswith("total_cycles"):
        return f"{value:.0f}"
    return f"{value:.1f}"


def stats(label: str, values: Iterable[Optional[float]], unit: str, geomean: bool = False) -> str:
    values = [v for v in values if v is not None]
    if not values:
        return f"    {label:<14} n/a"
    fmt = "{:+.2f}%" if unit == "%" else "{:.3f}x"
    line = (f"    {label:<14} min {fmt.format(min(values)):>8}  "
            f"median {fmt.format(statistics.median(values)):>8}  max {fmt.format(max(values)):>8}")
    if geomean:
        mean = math.exp(sum(math.log(v) for v in values) / len(values))
        line += f"  geomean {fmt.format(mean)}"
    return line


def config_name(key: Key) -> str:
    return f"{key[2]}s_{key[3]}b"


def best_per_size(rows: Dict[Key, Row], sweep: Tuple[str, int]) -> Dict[int, Key]:
    """Pick the configuration with the fewest cycles for each cache size."""

    best: Dict[int, Key] = {}
    for key, row in rows.items():
        cycles = number(row, "total_cycles")
        if key[:2] != sweep or cycles is None:
            continue
        size = key[1] * key[2] * key[3]
        if size not in best or cycles < number(rows[best[size]], "total_cycles"):
            best[size] = key
    return best


def describe(row: Optional[Row]) -> str:
    if row is None:
        return "-"
    cycles, area = number(row, "total_cycles"), number(row, "total_um2")
    area_text = f"{area / 1e6:.3f} mm2" if area is not None else "no area"
    config = f"{row['sets']}s_{row['line_bytes']}b"
    return f"{config:<10} {cycles:>11,.0f} cycles {area_text:>10}"


def report(base_dir: Path, new_dir: Path, base: Dict[Key, Row], new: Dict[Key, Row],
           rows: List[Dict[str, object]]) -> str:
    lines = [f"Base: cache_eval/{base_dir.name}", f"New:  cache_eval/{new_dir.name}", ""]
    for sweep in sorted({key[:2] for key in list(base) + list(new)}):
        name = f"{sweep[0]}_{sweep[1]}w"
        base_keys = {k for k in base if k[:2] == sweep}
        new_keys = {k for k in new if k[:2] == sweep}
        sweep_rows = [r for r in rows if (r["cache"], r["ways"]) == sweep]
        lines.append(f"{sweep[0]} cache, {sweep[1]} ways: {len(sweep_rows)} configurations in both")
        lines.append(f"  base code: {code_state(base_dir, name)}")
        lines.append(f"  new code:  {code_state(new_dir, name)}")
        for label, keys in (("only in base", base_keys - new_keys), ("only in new", new_keys - base_keys)):
            if keys:
                lines.append(f"  {label}: " + " ".join(config_name(k) for k in sorted(keys)))

        for side, data, keys in (("base", base, base_keys), ("new", new, new_keys)):
            for part, column in (("area", "total_um2"), ("performance", "total_cycles")):
                present = [k for k in keys if column in data[k]]
                if not present:
                    lines.append(f"  {side} has no {part} results")
                    continue
                failed = [k for k in present if number(data[k], column) is None]
                if failed:
                    lines.append(f"  {side} {part} failed: " + " ".join(config_name(k) for k in sorted(failed)))
        changed = [k for k in base_keys & new_keys
                   if base[k].get("perf_status") == new[k].get("perf_status") == "ok"
                   and base[k].get("checksum") != new[k].get("checksum")]
        if changed:
            lines.append("  WARNING: benchmark checksum differs: " + " ".join(config_name(k) for k in sorted(changed)))

        lines.append("")
        lines.append("  Speedup (base cycles / new cycles)")
        lines.append(stats("total", (r["speedup"] for r in sweep_rows), "x", geomean=True))
        for phase in PHASES:
            lines.append(stats(phase, (r[f"{phase}_speedup"] for r in sweep_rows), "x", geomean=True))
        lines.append("  Area change (new vs base)")
        for column in AREAS:
            lines.append(stats(column[:-4], (r[f"{column}_change_pct"] for r in sweep_rows), "%"))
        lines.append("  Area-time gain (base cycles * area / new cycles * area)")
        lines.append(stats("total", (r["area_time_gain"] for r in sweep_rows), "x", geomean=True))

        lines.append("")
        lines.append("  Fewest cycles per cache size")
        best_base, best_new = best_per_size(base, sweep), best_per_size(new, sweep)
        for size in sorted(set(best_base) | set(best_new)):
            b = base.get(best_base[size]) if size in best_base else None
            n = new.get(best_new[size]) if size in best_new else None
            lines.append(f"    {size // 1024:>4} KiB  base {describe(b)}   new {describe(n)}")

        lines.append("")
        lines.append(f"  {'config':>11} {'KiB':>4} {'speedup':>8} {'total area':>11} {'stdcell':>9} {'area-time':>10}")
        for r in sorted(sweep_rows, key=lambda r: (r["cache_bytes"], r["sets"])):
            cells = [csv_value("speedup", r["speedup"]), csv_value("_pct", r["total_um2_change_pct"]),
                     csv_value("_pct", r["stdcell_um2_change_pct"]), csv_value("gain", r["area_time_gain"])]
            cells = [c or "n/a" for c in cells]
            config = f"{r['sets']}s_{r['line_bytes']}b"
            lines.append(f"  {config:>11} {r['cache_bytes'] // 1024:>4} {cells[0]:>8} "
                         f"{cells[1]:>10}% {cells[2]:>8}% {cells[3]:>10}")
        lines.append("")
    return "\n".join(lines)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__.splitlines()[0],
        epilog="Evaluations are names in cache_eval/, such as 20261113_162446 or latest, or paths.",
    )
    parser.add_argument("base", help="evaluation to compare against")
    parser.add_argument("new", help="evaluation to compare with the base")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    base_dir, new_dir = resolve_eval(args.base), resolve_eval(args.new)
    if base_dir == new_dir:
        sys.exit("[ERROR][Cache compare] Base and new are the same evaluation")

    base, new = load_eval(base_dir), load_eval(new_dir)
    rows = compare(base, new)
    if not rows:
        sys.exit("[ERROR][Cache compare] The evaluations have no configuration in common")

    out_dir = EVAL_ROOT / "comparisons" / f"{base_dir.name}_vs_{new_dir.name}"
    out_dir.mkdir(parents=True, exist_ok=True)
    with (out_dir / "comparison.csv").open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(rows[0].keys())
        for row in rows:
            writer.writerow(csv_value(column, value) for column, value in row.items())
    text = report(base_dir, new_dir, base, new, rows)
    (out_dir / "report.txt").write_text(text)

    print(text)
    print(f"[INFO][Cache compare] Results in cache_eval/comparisons/{out_dir.name}/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
