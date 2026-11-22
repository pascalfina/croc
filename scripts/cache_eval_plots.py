#!/usr/bin/env python3
"""Plot cache evaluations of scripts/run_cache_eval.sh.

For one evaluation, writes plots/<sweep>_performance.png (cycles per phase),
plots/<sweep>_area.png (standard cells and SRAM) and
plots/<sweep>_area_vs_cycles.png into its directory. compare_cache_eval.py
calls plot_comparison() for two evaluations. The area-against-cycles plots
also show the best and worst case from cache_eval/bounds/, measured with
scripts/run_cache_bound.sh on other branches. Needs matplotlib, which the
container provides and scripts/setup_plot_venv.sh installs into .venv.
"""

import argparse
import sys
from pathlib import Path
from typing import Dict, List, Sequence, Tuple

from compare_cache_eval import (EVAL_ROOT, PHASES, Key, Row, load_eval, number, read_csv,
                                resolve_eval, use_plot_python)


# Reference palette of the data-viz guidelines, light mode.
SURFACE = "#fcfcfb"
INK = "#0b0b0b"
INK_SECONDARY = "#52514e"
MUTED = "#898781"
GRID = "#e1e0d9"
AXIS = "#c3c2b7"
SERIES = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#6250d6", "#e34948"]
ACCENT = SERIES[0]
DPI = 150
NAMING = "s = number of sets, b = data bytes per line, without ECC and tag bits"

# Results of scripts/run_cache_bound.sh in cache_eval/bounds/<name>_<timestamp>/.
BOUNDS = (
    ("cheriot-base", "best case: all memory in on-chip SRAM", SERIES[2]),
    ("cheriot-tag-sram", "worst case: no caches, tags in on-chip SRAM", SERIES[1]),
)

Groups = List[Tuple[int, float, float]]
Bound = Tuple[str, float, str]


def load_bounds() -> List[Bound]:
    """Return the latest successful run of each bound as (label, cycles, color)."""

    bounds = []
    for name, label, color in BOUNDS:
        for csv_path in sorted((EVAL_ROOT / "bounds").glob(f"{name}_*/performance.csv"), reverse=True):
            row = read_csv(csv_path)[0]
            if row.get("status") == "ok":
                bounds.append((label, float(row["total_cycles"]), color))
                break
    return bounds


def draw_bounds(ax, bounds: List[Bound]) -> None:
    for label, cycles, color in bounds:
        ax.axhline(cycles / 1e6, color=color, linewidth=2, linestyle="--", zorder=1, label=f"{label} ({cycles / 1e6:.2f} M)")


def pyplot():
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    plt.rcParams.update({
        "figure.facecolor": SURFACE, "axes.facecolor": SURFACE, "savefig.facecolor": SURFACE,
        "axes.edgecolor": AXIS, "axes.linewidth": 0.8, "axes.labelcolor": INK_SECONDARY,
        "axes.spines.top": False, "axes.spines.right": False,
        "axes.grid": True, "axes.grid.axis": "y", "axes.axisbelow": True,
        "grid.color": GRID, "grid.linewidth": 0.8, "grid.linestyle": "-",
        "xtick.color": AXIS, "ytick.color": AXIS,
        "xtick.labelcolor": INK_SECONDARY, "ytick.labelcolor": INK_SECONDARY,
        "font.size": 9, "text.color": INK, "legend.frameon": False,
    })
    return plt


def sweeps(rows: Dict[Key, Row]) -> List[Tuple[str, int]]:
    return sorted({key[:2] for key in rows})


def cache_bytes(key: Key) -> int:
    return key[1] * key[2] * key[3]


def layout(keys: Sequence[Key]) -> Tuple[Dict[Key, float], Groups]:
    """Order configurations by cache size, then sets, with a gap between sizes."""

    positions: Dict[Key, float] = {}
    groups: Groups = []
    x = 0.0
    for key in sorted(keys, key=lambda k: (cache_bytes(k), k[2])):
        if groups and groups[-1][0] != cache_bytes(key):
            x += 1.0
        if not groups or groups[-1][0] != cache_bytes(key):
            groups.append((cache_bytes(key), x, x))
        groups[-1] = (groups[-1][0], groups[-1][1], x)
        positions[key] = x
        x += 1.0
    return positions, groups


def config_axis(ax, positions: Dict[Key, float], groups: Groups, size_labels: bool = True) -> None:
    """Label each configuration and mark the cache sizes above the plot."""

    ax.set_xticks(list(positions.values()))
    ax.set_xticklabels([f"{k[2]}s_{k[3]}b" for k in positions], rotation=90, fontsize=7)
    ax.set_xlim(-0.8, max(positions.values()) + 0.8)
    for (_, _, end), (_, start, _) in zip(groups, groups[1:]):
        ax.axvline((end + start) / 2, color=GRID, linewidth=0.8, zorder=0)
    if size_labels:
        for size, start, end in groups:
            ax.text((start + end) / 2, 1.01, f"{size // 1024} KiB", transform=ax.get_xaxis_transform(),
                    ha="center", va="bottom", color=INK_SECONDARY, fontsize=8)


def log_axis(ax, axis: str = "y") -> None:
    """Log scale with plain tick labels; linear when the data spans less than a decade."""

    import math
    from matplotlib.ticker import FuncFormatter, LogLocator, NullFormatter
    getattr(ax, f"set_{axis}scale")("log")
    low, high = getattr(ax, f"get_{axis}lim")()
    decades = math.log10(high / low)
    if decades < 1.0:
        getattr(ax, f"set_{axis}scale")("linear")
        return
    subs = (1.0, 2.0, 3.0, 5.0, 7.0) if decades < 1.5 else (1.0, 2.0, 5.0) if decades < 2.5 else (1.0,)
    target = getattr(ax, f"{axis}axis")
    target.set_major_locator(LogLocator(subs=subs))
    target.set_major_formatter(FuncFormatter(lambda v, _: f"{v:g}"))
    target.set_minor_formatter(NullFormatter())


def title(ax, text: str, sweep: Tuple[str, int], above_sizes: bool = False) -> None:
    """Center the title over the plot, above the cache-size labels if it has them."""

    ax.set_title(f"{text}, {sweep[0]} cache, {sweep[1]} ways", fontsize=12, color=INK,
                 pad=24 if above_sizes else 12)


def pareto(points: List[Tuple[float, float, Key]]) -> List[Tuple[float, float, Key]]:
    """Keep the points that no other point beats in both area and cycles."""

    front = []
    for area, cycles, key in sorted(points):
        if not front or cycles < front[-1][1]:
            front.append((area, cycles, key))
    return front


def save(plt, fig, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(path, dpi=DPI, bbox_inches="tight")
    plt.close(fig)


def plot_performance(plt, rows: Dict[Key, Row], sweep: Tuple[str, int], path: Path) -> None:
    keys = [k for k in rows if k[:2] == sweep]
    positions, groups = layout(keys)
    fig, ax = plt.subplots(figsize=(15, 6))
    bottom = {k: 0.0 for k in keys}
    for color, phase in zip(SERIES, PHASES):
        xs, heights, bases = [], [], []
        for key in keys:
            cycles = number(rows[key], phase)
            if cycles is not None:
                xs.append(positions[key])
                heights.append(cycles / 1e6)
                bases.append(bottom[key])
                bottom[key] += cycles / 1e6
        ax.bar(xs, heights, width=0.6, bottom=bases, color=color, edgecolor=SURFACE, linewidth=0.8, label=phase)
    for key in keys:
        if number(rows[key], "total_cycles") is None:
            ax.text(positions[key], 0, "failed", rotation=90, ha="center", va="bottom", color=MUTED, fontsize=7)
    config_axis(ax, positions, groups)
    ax.set_ylabel("cycles [M]")
    handles, labels = ax.get_legend_handles_labels()
    ax.legend(handles[::-1], labels[::-1], loc="upper left", bbox_to_anchor=(1.01, 1.0), title="phase")
    ax.set_xlabel(f"configuration ({NAMING})")
    title(ax, "Cycles per phase", sweep, above_sizes=True)
    save(plt, fig, path)


def plot_area(plt, rows: Dict[Key, Row], sweep: Tuple[str, int], path: Path) -> None:
    keys = [k for k in rows if k[:2] == sweep]
    positions, groups = layout(keys)
    fig, ax = plt.subplots(figsize=(15, 6))
    bottom = {k: 0.0 for k in keys}
    for color, column, label in ((SERIES[0], "stdcell_um2", "standard cells"), (SERIES[1], "sram_um2", "SRAM")):
        xs, heights, bases = [], [], []
        for key in keys:
            area = number(rows[key], column)
            if area is not None:
                xs.append(positions[key])
                heights.append(area / 1e6)
                bases.append(bottom[key])
                bottom[key] += area / 1e6
        ax.bar(xs, heights, width=0.6, bottom=bases, color=color, edgecolor=SURFACE, linewidth=0.8, label=label)
    for key in keys:
        if number(rows[key], "total_um2") is None:
            ax.text(positions[key], 0, "failed", rotation=90, ha="center", va="bottom", color=MUTED, fontsize=7)
    config_axis(ax, positions, groups)
    ax.set_ylabel("area [mm²]")
    handles, labels = ax.get_legend_handles_labels()
    ax.legend(handles[::-1], labels[::-1], loc="upper left", bbox_to_anchor=(1.01, 1.0))
    ax.set_xlabel(f"configuration ({NAMING})")
    title(ax, "Area", sweep, above_sizes=True)
    save(plt, fig, path)


def scatter_points(rows: Dict[Key, Row], keys: Sequence[Key]) -> List[Tuple[float, float, Key]]:
    points = []
    for key in keys:
        area, cycles = number(rows.get(key), "total_um2"), number(rows.get(key), "total_cycles")
        if area is not None and cycles is not None:
            points.append((area / 1e6, cycles / 1e6, key))
    return points


def draw_front(ax, points, color: str, label: str, names: bool) -> None:
    front = pareto(points)
    ax.plot([p[0] for p in front], [p[1] for p in front], color=color, linewidth=2,
            solid_joinstyle="round", solid_capstyle="round", zorder=3, label=label)
    ax.scatter([p[0] for p in front], [p[1] for p in front], s=40, color=color,
               edgecolors=SURFACE, linewidths=1.5, zorder=4)
    if names:
        from matplotlib import patheffects
        for area, cycles, key in front:
            ax.annotate(f"{key[2]}s_{key[3]}b", (area, cycles), xytext=(5, 4), textcoords="offset points",
                        fontsize=7, color=INK_SECONDARY, zorder=5,
                        path_effects=[patheffects.withStroke(linewidth=3, foreground=SURFACE)])


def scatter_axes(ax) -> None:
    log_axis(ax, "x")
    log_axis(ax, "y")
    ax.grid(True, axis="both")
    ax.set_xlabel("total area [mm²]")
    ax.text(1.0, -0.1, f"labels: {NAMING}", transform=ax.transAxes, ha="right", va="top",
            fontsize=8, color=INK_SECONDARY)
    ax.set_ylabel("total cycles [M]")


def plot_area_vs_cycles(plt, rows: Dict[Key, Row], sweep: Tuple[str, int], path: Path) -> None:
    points = scatter_points(rows, [k for k in rows if k[:2] == sweep])
    if not points:
        return
    fig, ax = plt.subplots(figsize=(10, 7))
    ax.scatter([p[0] for p in points], [p[1] for p in points], s=40, color=MUTED,
               edgecolors=SURFACE, linewidths=1.5, zorder=2, label="configuration")
    draw_front(ax, points, ACCENT, "Pareto front", names=True)
    draw_bounds(ax, load_bounds())
    scatter_axes(ax)
    ax.legend(loc="upper left", bbox_to_anchor=(1.01, 1.0))
    title(ax, "Area vs. cycles", sweep)
    save(plt, fig, path)


def plot_eval(eval_dir: Path) -> List[Path]:
    """Write the per-sweep plots of one evaluation into its plots directory."""

    plt = pyplot()
    rows = load_eval(eval_dir)
    out = []
    for sweep in sweeps(rows):
        prefix = eval_dir / "plots" / f"{sweep[0]}_{sweep[1]}w"
        if any("total_cycles" in rows[k] for k in rows if k[:2] == sweep):
            out.append(prefix.with_name(prefix.name + "_performance.png"))
            plot_performance(plt, rows, sweep, out[-1])
        if any("total_um2" in rows[k] for k in rows if k[:2] == sweep):
            out.append(prefix.with_name(prefix.name + "_area.png"))
            plot_area(plt, rows, sweep, out[-1])
        if scatter_points(rows, [k for k in rows if k[:2] == sweep]):
            out.append(prefix.with_name(prefix.name + "_area_vs_cycles.png"))
            plot_area_vs_cycles(plt, rows, sweep, out[-1])
    return out


def plot_comparison_scatter(plt, base: Dict[Key, Row], new: Dict[Key, Row], keys: List[Key],
                            names: Tuple[str, str], sweep: Tuple[str, int], path: Path) -> bool:
    points_base, points_new = scatter_points(base, keys), scatter_points(new, keys)
    if not points_base or not points_new:
        return False
    fig, ax = plt.subplots(figsize=(10, 7))
    moved = {p[2]: p for p in points_new}
    for area, cycles, key in points_base:
        if key in moved:
            ax.annotate("", xy=moved[key][:2], xytext=(area, cycles),
                        arrowprops={"arrowstyle": "-|>", "color": AXIS, "linewidth": 0.8, "shrinkA": 4, "shrinkB": 4})
    for points, color, label in ((points_base, MUTED, f"base {names[0]}"), (points_new, ACCENT, f"new {names[1]}")):
        ax.scatter([p[0] for p in points], [p[1] for p in points], s=40, color=color,
                   edgecolors=SURFACE, linewidths=1.5, zorder=2, label=label)
    draw_front(ax, points_base, MUTED, "base Pareto front", names=False)
    draw_front(ax, points_new, ACCENT, "new Pareto front", names=True)
    draw_bounds(ax, load_bounds())
    scatter_axes(ax)
    ax.legend(loc="upper left", bbox_to_anchor=(1.01, 1.0))
    title(ax, "Area vs. cycles", sweep)
    save(plt, fig, path)
    return True


def plot_comparison(base_dir: Path, new_dir: Path, base: Dict[Key, Row], new: Dict[Key, Row],
                    out_dir: Path) -> List[Path]:
    """Write an area-against-cycles plot per sweep that both evaluations have."""

    plt = pyplot()
    names = (base_dir.name, new_dir.name)
    out = []
    for sweep in sorted(set(sweeps(base)) & set(sweeps(new))):
        keys = [k for k in base if k[:2] == sweep and k in new]
        path = out_dir / f"{sweep[0]}_{sweep[1]}w_area_vs_cycles.png"
        if plot_comparison_scatter(plt, base, new, keys, names, sweep, path):
            out.append(path)
    return out


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("eval", help="evaluation in cache_eval/, such as 20261113_162446 or latest, or a path")
    return parser.parse_args()


def main() -> int:
    use_plot_python()
    args = parse_args()
    eval_dir = resolve_eval(args.eval)
    try:
        paths = plot_eval(eval_dir)
    except ImportError:
        sys.exit("[ERROR][Cache plots] matplotlib is missing, run scripts/setup_plot_venv.sh")
    print(f"[INFO][Cache plots] {len(paths)} plots in cache_eval/{eval_dir.name}/plots/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
