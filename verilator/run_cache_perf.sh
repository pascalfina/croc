#!/bin/bash
# Copyright (c) 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Runs the cache benchmark in the RTL simulation for each cache configuration
# and reports the cycles from the benchmark's start to its end.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

show_help() {
    cat <<EOF
Usage: $0 [data|instruction] [ways]

Simulates every combination of sets and line size whose SRAM holds 256 to
16384 records; the other cache keeps the default configuration. Defaults: data
cache, 2 ways.

Environment variables:
    CACHE_SETS   set counts to combine (default: 2 4 8 16 32 64 128 256 512 1024)
    CACHE_LINES  line sizes in bytes   (default: 16 32 64 128 256 512 1024)
    JOBS         parallel builds and simulations (default: number of CPUs)
    VERILATOR_JOBS  compiler jobs per build (default: 1, as JOBS builds run at once)
    BENCH_HEX    prebuilt benchmark image; built with make if unset
    SIM_TIMEOUT  seconds per simulation (default: 21600)
    RESULT_DIR   result directory (default: a new cache_perf/<YYYYmmdd_HHMMSS>/,
                 cache_perf/latest points to the newest one)

Results: <RESULT_DIR>/<cache>_<ways>w.csv, logs in <RESULT_DIR>/<config>/.
Rows of configurations that a call does not run stay in the CSV; each call
appends its code state to <cache>_<ways>w_info.txt.
EOF
}

is_power_of_two() {
    (( $1 > 0 && ($1 & ($1 - 1)) == 0 ))
}

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    show_help
    exit 0
fi

cache=${1:-data}
ways=${2:-2}
jobs=${JOBS:-$(nproc)}
sim_timeout=${SIM_TIMEOUT:-21600}
# Not SETS/LINES: the shell sets LINES to the terminal height.
read -r -a set_counts <<< "${CACHE_SETS:-2 4 8 16 32 64 128 256 512 1024}"
read -r -a line_sizes <<< "${CACHE_LINES:-16 32 64 128 256 512 1024}"
# All builds start together; one compiler per build keeps the memory use at
# JOBS compilers instead of JOBS times run_verilator.sh's default of 4.
export VERILATOR_JOBS=${VERILATOR_JOBS:-1}

case "$cache" in
    data)        prefix=DCache ;;
    instruction) prefix=ICache ;;
    *)           show_help >&2; exit 1 ;;
esac

invalid=0
if ! is_power_of_two "$ways"; then
    echo "[ERROR][Cache perf] ways must be a power of two: $ways" >&2
    invalid=1
fi
for sets in "${set_counts[@]}"; do
    if ! is_power_of_two "$sets"; then
        echo "[ERROR][Cache perf] sets must be a power of two: $sets" >&2
        invalid=1
    fi
done
for line in "${line_sizes[@]}"; do
    if ! is_power_of_two "$line" || (( line < 16 || line > 1024 )); then
        echo "[ERROR][Cache perf] line size must be a power of two from 16 to 1024 bytes: $line" >&2
        invalid=1
    fi
done
(( invalid == 0 )) || exit 1

runs=()
for sets in "${set_counts[@]}"; do
    for line in "${line_sizes[@]}"; do
        records=$(( ways * sets * line / 8 ))
        if (( records % 256 == 0 && records <= 16384 )); then
            runs+=("$sets $line")
        fi
    done
done

if [[ ${#runs[@]} -eq 0 ]]; then
    echo "[ERROR][Cache perf] No combination of sets and line size fits 256 to 16384 SRAM records" >&2
    exit 1
fi

if [[ -z "${BENCH_HEX:-}" ]]; then
    make -C ../sw cheriot-rtos \
        CHERIOT_RTOS_PROJECTS=cheriot-rtos/cache_benchmark \
        CHERIOT_RTOS_BINDIR=bin/cheriot-rtos-bench
    bench_hex=../sw/bin/cheriot-rtos-bench/cache_benchmark.hex
else
    bench_hex=$BENCH_HEX
fi

if [[ ! -f "$bench_hex" ]]; then
    echo "[ERROR][Cache perf] Missing benchmark image: $bench_hex" >&2
    exit 1
fi

./run_verilator.sh --flist-rtl

# The benchmark's working set ends at 0x8006_0000.
init_bytes=$(( 0x60000 ))

# Without RESULT_DIR each call gets a new directory, so that runs of older code
# stay for comparison.
if [[ -n "${RESULT_DIR:-}" ]]; then
    result_dir=$RESULT_DIR
    mkdir -p "$result_dir"
else
    result_dir="cache_perf/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$result_dir"
    ln -sfn "$(basename "$result_dir")" cache_perf/latest
fi
shown_dir=$(realpath -m --relative-to=.. "$result_dir")
{
    echo "date:   $(date '+%Y-%m-%d %H:%M:%S')"
    echo "sets:   ${set_counts[*]}"
    echo "lines:  ${line_sizes[*]}"
    echo "commit: $(git -C .. rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "uncommitted changes:"
    git -C .. status --short --untracked-files=no 2>/dev/null | sed 's/^/    /'
    echo
} >> "$result_dir/${cache}_${ways}w_info.txt"
echo "[INFO][Cache perf] Results go to $shown_dir"

simulate() {
    local sets=$1
    local line=$2
    local name=$3
    local dir="$result_dir/$name"

    rm -rf -- "$dir"
    mkdir -p "$dir"

    VERILATOR_SKIP_FLIST=1 \
    VERILATOR_RTL_MDIR="$dir/obj_dir" \
    VERILATOR_RTL_LOG="$dir/build.log" \
    VERILATOR_RTL_ARGS="-G${prefix}Ways=$ways -G${prefix}Sets=$sets -G${prefix}LineBytes=$line -GHyperramInitBytes=$init_bytes" \
        ./run_verilator.sh --no-trace --build > /dev/null

    # --foreground keeps the simulator in this script's process group, so that
    # the interrupt trap reaches it.
    timeout --foreground "$sim_timeout" "$dir/obj_dir/Vtb_croc_soc" +binary="$bench_hex" > "$dir/sim.log" 2>&1
}

# Background jobs ignore SIGINT, so Ctrl-C has to stop the builds and
# simulations explicitly.
trap 'trap - INT TERM; echo "[INFO][Cache perf] Interrupted, stopping all builds and simulations" >&2; kill 0' INT TERM

echo "[INFO][Cache perf] ${#runs[@]} configurations, $jobs in parallel"
running=0
for run in "${runs[@]}"; do
    read -r sets line <<< "$run"
    name="${cache}_${ways}w_${sets}s_${line}b"
    echo "[INFO][Cache perf] Building and simulating $name"
    simulate "$sets" "$line" "$name" &
    running=$((running + 1))
    if (( running >= jobs )); then
        wait -n || true
        running=$((running - 1))
    fi
done
wait || true

# A failed build leaves no log; the missing value must not abort the summary.
bench_value() {
    grep -oE "BENCH $2 -?[0-9]+" "$1" 2>/dev/null | tail -n 1 | awk '{print $3}' || true
}

phases=(init stream copy stride random chase capabilities code)
csv="$result_dir/${cache}_${ways}w.csv"
status=0
reference=""
rows=()
printf '\n%6s %10s %11s %14s %12s %8s\n' sets line_bytes cache_bytes total_cycles checksum status
for run in "${runs[@]}"; do
    read -r sets line <<< "$run"
    name="${cache}_${ways}w_${sets}s_${line}b"
    log="$result_dir/$name/sim.log"
    bytes=$((ways * sets * line))

    total=$(bench_value "$log" total)
    checksum=$(grep -oE "BENCH checksum 0x[0-9a-fA-F]+" "$log" 2>/dev/null | tail -n 1 | awk '{print $3}' || true)
    cycles=()
    for phase in "${phases[@]}"; do
        cycles+=("$(bench_value "$log" "$phase")")
    done

    if grep -q "Simulation finished: SUCCESS" "$log" 2>/dev/null && [[ -n "$total" && -n "$checksum" ]]; then
        result=ok
        if [[ -z "$reference" ]]; then
            reference=$checksum
        elif [[ "$checksum" != "$reference" ]]; then
            result=checksum_mismatch
            status=1
        fi
    else
        result=failed
        status=1
        echo "[ERROR][Cache perf] $name failed, see $shown_dir/$name/" >&2
    fi

    rows+=("$sets,$line,$bytes,${total:-},$(IFS=,; echo "${cycles[*]}"),${checksum:-},$result")
    printf '%6s %10s %11s %14s %12s %8s\n' "$sets" "$line" "$bytes" "${total:-n/a}" "${checksum:-n/a}" "$result"
done

# Keeps the rows of earlier calls for configurations this call did not run.
{
    echo "sets,line_bytes,cache_bytes,total_cycles,$(IFS=,; echo "${phases[*]}"),checksum,status"
    {
        printf '%s\n' "${rows[@]}"
        if [[ -f "$csv" ]]; then
            printf '%s\n' "${rows[@]}" | awk -F, 'NR == FNR { ran[$1 "," $2] = 1; next }
                FNR > 1 { gsub(/[ \r]/, ""); if (!(($1 "," $2) in ran)) print }' - "$csv"
        fi
    } | sort -t, -k1,1n -k2,2n
} > "$csv.new"
mv -- "$csv.new" "$csv"
echo
echo "[INFO][Cache perf] Results written to $shown_dir/$(basename "$csv")"

exit "$status"
