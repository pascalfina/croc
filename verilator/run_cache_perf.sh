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
    SETS         set counts to combine (default: 2 4 8 16 32 64 128 256 512 1024)
    LINES        line sizes in bytes   (default: 16 32 64 128 256 512 1024)
    JOBS         parallel builds and simulations (default: number of CPUs)
    BENCH_HEX    prebuilt benchmark image; built with make if unset
    SIM_TIMEOUT  seconds per simulation (default: 21600)

Results: cache_perf/<cache>_<ways>w.csv, logs in cache_perf/<run>/.
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
read -r -a set_counts <<< "${SETS:-2 4 8 16 32 64 128 256 512 1024}"
read -r -a line_sizes <<< "${LINES:-16 32 64 128 256 512 1024}"

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

simulate() {
    local sets=$1
    local line=$2
    local name=$3
    local dir="cache_perf/$name"

    rm -rf -- "$dir"
    mkdir -p "$dir"

    VERILATOR_SKIP_FLIST=1 \
    VERILATOR_RTL_MDIR="$dir/obj_dir" \
    VERILATOR_RTL_LOG="$dir/build.log" \
    VERILATOR_RTL_ARGS="-G${prefix}Ways=$ways -G${prefix}Sets=$sets -G${prefix}LineBytes=$line -GHyperramInitBytes=$init_bytes" \
        ./run_verilator.sh --no-trace --build > /dev/null

    timeout "$sim_timeout" "$dir/obj_dir/Vtb_croc_soc" +binary="$bench_hex" > "$dir/sim.log" 2>&1
}

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

bench_value() {
    grep -oE "BENCH $2 -?[0-9]+" "$1" 2>/dev/null | tail -n 1 | awk '{print $3}'
}

phases=(init stream copy stride random chase capabilities code)
csv="cache_perf/${cache}_${ways}w.csv"
status=0
reference=""
echo "sets,line_bytes,cache_bytes,total_cycles,$(IFS=,; echo "${phases[*]}"),checksum,status" > "$csv"
printf '\n%6s %10s %11s %14s %12s %8s\n' sets line_bytes cache_bytes total_cycles checksum status
for run in "${runs[@]}"; do
    read -r sets line <<< "$run"
    name="${cache}_${ways}w_${sets}s_${line}b"
    log="cache_perf/$name/sim.log"
    bytes=$((ways * sets * line))

    total=$(bench_value "$log" total)
    checksum=$(grep -oE "BENCH checksum 0x[0-9a-fA-F]+" "$log" 2>/dev/null | tail -n 1 | awk '{print $3}')
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
        echo "[ERROR][Cache perf] $name failed, see verilator/cache_perf/$name/" >&2
    fi

    echo "$sets,$line,$bytes,${total:-},$(IFS=,; echo "${cycles[*]}"),${checksum:-},$result" >> "$csv"
    printf '%6s %10s %11s %14s %12s %8s\n' "$sets" "$line" "$bytes" "${total:-n/a}" "${checksum:-n/a}" "$result"
done
echo
echo "[INFO][Cache perf] Results written to verilator/$csv"

exit "$status"
