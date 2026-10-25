#!/usr/bin/env python3
"""Estimate CHERIoT-RTOS trusted-stack depth from a linker report.

The CHERIoT linker emits a JSON compartment report next to the firmware ELF.
The report contains the compartment-export imports, which are enough to build
an over-approximate compartment dependency graph.  This is a diagnostic aid,
not a proof: dynamic callbacks and cycles need manual review.
"""

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Set, Tuple


Graph = Dict[str, Set[str]]
PathAndCycles = Tuple[List[str], Set[Tuple[str, ...]]]


def find_report(path: Path) -> Path:
    """Resolve a linker report from either a report path or an ELF path."""

    if path.suffix == ".json":
        return path

    candidates = [path.with_suffix(".json"), Path(str(path) + ".json")]
    for candidate in candidates:
        if candidate.is_file():
            return candidate

    names = ", ".join(str(candidate) for candidate in candidates)
    raise FileNotFoundError(
        "no linker report found; expected one of: " + names +
        ". Pass the generated .json report explicitly."
    )


def load_report(path: Path) -> Dict[str, object]:
    report_path = find_report(path)
    try:
        with report_path.open(encoding="utf-8") as report_file:
            report = json.load(report_file)
    except json.JSONDecodeError as error:
        raise ValueError("invalid JSON in {}: {}".format(report_path, error))

    if not isinstance(report, dict) or not isinstance(report.get("compartments"), dict):
        raise ValueError("{} is not a CHERIoT compartment report".format(report_path))
    return report


def build_graph(report: Dict[str, object]) -> Graph:
    compartments = report["compartments"]
    assert isinstance(compartments, dict)
    names = set(str(name) for name in compartments)
    graph: Graph = {name: set() for name in names}

    for source, value in compartments.items():
        if not isinstance(value, dict):
            continue
        imports = value.get("imports", [])
        if not isinstance(imports, list):
            continue
        for item in imports:
            if not isinstance(item, dict):
                continue
            if item.get("kind") != "CompartmentExport":
                continue
            target = item.get("compartment_name")
            if target in names:
                graph[str(source)].add(str(target))

    return graph


def thread_roots(report: Dict[str, object]) -> List[str]:
    threads = report.get("threads", [])
    roots: List[str] = []
    if not isinstance(threads, list):
        return roots

    for thread in threads:
        if not isinstance(thread, dict):
            continue
        entry = thread.get("entry_point")
        if not isinstance(entry, dict):
            continue
        compartment = entry.get("compartment_name")
        if isinstance(compartment, str) and compartment not in roots:
            roots.append(compartment)
    return roots


def longest_simple_path(root: str, graph: Graph) -> PathAndCycles:
    best = [root]
    cycles: Set[Tuple[str, ...]] = set()

    def visit(path: List[str]) -> None:
        nonlocal best
        if len(path) > len(best):
            best = list(path)

        current = path[-1]
        for target in sorted(graph.get(current, ())):
            if target in path:
                start = path.index(target)
                cycles.add(tuple(path[start:] + [target]))
                continue
            visit(path + [target])

    visit([root])
    return best, cycles


def parse_xmake_frames(path: Path) -> List[int]:
    pattern = re.compile(r"\btrusted_stack_frames\s*=\s*(\d+)")
    values: List[int] = []
    for match in pattern.finditer(path.read_text(encoding="utf-8")):
        values.append(int(match.group(1)))
    return values


def format_path(path: Iterable[str]) -> str:
    return " -> ".join(path)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Estimate trusted_stack_frames from a CHERIoT-RTOS linker "
            "compartment report."
        )
    )
    parser.add_argument(
        "input",
        type=Path,
        help="linker report (.json), or an ELF with a neighbouring .json report",
    )
    parser.add_argument(
        "--xmake",
        type=Path,
        help="optional xmake.lua used to compare configured frame counts",
    )
    parser.add_argument(
        "--reserve",
        type=int,
        default=1,
        help="extra frames recommended above the static estimate (default: 1)",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="return failure when a known configured value is below the recommendation",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="also return failure when a reachable dependency cycle is found",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.reserve < 0:
        print("error: --reserve must be non-negative", file=sys.stderr)
        return 2

    try:
        report = load_report(args.input)
        report_path = find_report(args.input)
    except (FileNotFoundError, OSError, ValueError) as error:
        print("error: {}".format(error), file=sys.stderr)
        return 2

    graph = build_graph(report)
    roots = thread_roots(report)
    if not roots:
        print("error: linker report contains no thread entry compartments", file=sys.stderr)
        return 2

    print("Trusted-stack analysis")
    print("  report: {}".format(report_path))
    print("  reserve: {} frame(s)".format(args.reserve))

    maximum_depth = 0
    all_cycles: Set[Tuple[str, ...]] = set()
    for index, root in enumerate(roots, 1):
        path, cycles = longest_simple_path(root, graph)
        depth = len(path) - 1
        maximum_depth = max(maximum_depth, depth)
        all_cycles.update(cycles)
        print("  thread {}: {}".format(index, format_path(path)))
        print("    estimated cross-compartment depth: {}".format(depth))

    recommendation = max(1, maximum_depth + args.reserve)
    print("  static minimum estimate: {} frame(s)".format(maximum_depth))
    print("  recommended trusted_stack_frames: {}".format(recommendation))

    if all_cycles:
        print("  warning: reachable compartment dependency cycle(s) found")
        for cycle in sorted(all_cycles):
            print("    cycle: {}".format(format_path(cycle)))
        print("  warning: a finite maximum cannot be proven from this report")

    configured: Optional[List[int]] = None
    if args.xmake is not None:
        try:
            configured = parse_xmake_frames(args.xmake)
        except OSError as error:
            print("error: cannot read {}: {}".format(args.xmake, error), file=sys.stderr)
            return 2
        if not configured:
            print("warning: no trusted_stack_frames value found in {}".format(args.xmake))
        else:
            configured_max = max(configured)
            print("  configured in xmake.lua: {}".format(", ".join(str(v) for v in configured)))
            if configured_max < recommendation:
                print("  result: WARNING, configured value is below the recommendation")
            else:
                print("  result: configured value covers the static estimate plus reserve")

    if args.strict and all_cycles:
        return 1
    if args.check and configured and max(configured) < recommendation:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
