#!/bin/bash
# Runs the cache benchmark once on the memory system of this branch, as the
# reference for the cache sweeps of cheriot/tag-hyperram.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

show_help() {
    cat <<EOF
Usage: $0 [name]

Builds the cache benchmark (make -C sw cache-benchmark) and the RTL simulation,
runs the benchmark once and stores the result in
cache_eval/bounds/<name>_<YYYYmmdd_HHMMSS>/:
    performance.csv   cycles per phase, same columns as the sweep CSVs
    info.txt          branch, commit and uncommitted changes
    sim.log           simulation output

Default name: the current branch with / replaced by -.
EOF
}

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    show_help
    exit 0
fi

branch=$(git branch --show-current)
name=${1:-${branch//\//-}}
out="cache_eval/bounds/${name}_$(date +%Y%m%d_%H%M%S)"
hex=sw/bin/cheriot-rtos-bench/cache_benchmark.hex
mkdir -p "$out"

{
    echo "date:   $(date '+%Y-%m-%d %H:%M:%S')"
    echo "branch: $branch"
    echo "commit: $(git rev-parse --short HEAD)"
    echo "uncommitted changes:"
    git status --short --untracked-files=no | sed 's/^/    /'
} > "$out/info.txt"
echo "[INFO][Cache bound] Results go to $out"

make -C sw cache-benchmark
(cd verilator && ./run_verilator.sh --no-trace --build)
# A failing simulation is reported in performance.csv below.
(cd verilator && ./run_verilator.sh --run "../$hex") 2>&1 | tee "$out/sim.log" || true

bench_value() {
    grep -oE "BENCH $1 -?[0-9a-fx]+" "$out/sim.log" | tail -n 1 | awk '{print $3}' || true
}

phases=(init stream copy stride random chase capabilities code)
total=$(bench_value total)
checksum=$(bench_value checksum)
cycles=()
for phase in "${phases[@]}"; do
    cycles+=("$(bench_value "$phase")")
done

status=0
if grep -q "Simulation finished: SUCCESS" "$out/sim.log" && [[ -n "$total" && -n "$checksum" ]]; then
    result=ok
else
    result=failed
    status=1
    echo "[ERROR][Cache bound] Benchmark failed, see $out/sim.log" >&2
fi

{
    echo "total_cycles,$(IFS=,; echo "${phases[*]}"),checksum,status"
    echo "${total:-},$(IFS=,; echo "${cycles[*]}"),${checksum:-},$result"
} > "$out/performance.csv"

echo
cat "$out/performance.csv"
echo "[INFO][Cache bound] Results written to $out/performance.csv"

exit "$status"
