#!/bin/bash
# Copyright (c) 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Synthesizes caches with the chip's Yosys flow and reports their area.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
source ../env.sh

show_help() {
    cat <<EOF
Usage: $0 [data|instruction] [ways]

Synthesizes every combination of sets and line size whose SRAM holds 256 to
16384 records. Defaults: data cache, 2 ways.

Environment variables:
    SETS    set counts to combine (default: 2 4 8 16 32 64 128 256 512 1024)
    LINES   line sizes in bytes   (default: 16 32 64 128 256 512 1024)
    JOBS    parallel syntheses    (default: number of CPUs)

Results: cache_area/<cache>_<ways>w.csv, logs and reports in cache_area/<run>/.
EOF
}

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    show_help
    exit 0
fi

cache=${1:-data}
ways=${2:-2}
jobs=${JOBS:-$(nproc)}
read -r -a set_counts <<< "${SETS:-2 4 8 16 32 64 128 256 512 1024}"
read -r -a line_sizes <<< "${LINES:-16 32 64 128 256 512 1024}"

if [[ "$cache" != data && "$cache" != instruction ]]; then
    show_help >&2
    exit 1
fi

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
    echo "[ERROR][Cache area] No supported combination of sets and line size" >&2
    exit 1
fi

./run_synthesis.sh --flist

synthesize() {
    local sets=$1
    local line=$2
    local name=$3
    local dir="cache_area/$name"

    rm -rf -- "$dir"
    mkdir -p "$dir"
    {
        cat src/croc.flist
        echo "+define+CACHE_AREA_INSTRUCTION=$([[ "$cache" == instruction ]] && echo 1 || echo 0)"
        echo "+define+CACHE_AREA_WAYS=$ways"
        echo "+define+CACHE_AREA_SETS=$sets"
        echo "+define+CACHE_AREA_LINE_BYTES=$line"
        echo "src/cache_area_top.sv"
    } > "$dir/cache.flist"

    SV_FLIST="$dir/cache.flist" OUT_DIR="$dir/out" TMP_DIR="$dir/tmp" REP_DIR="$dir/reports" \
    TOP_DESIGN=cache_area_top PROJ_NAME="$name" \
        yosys -c scripts/yosys_synthesis.tcl > "$dir/yosys.log" 2>&1
}

chip_area() {
    local area
    area=$(grep "Chip area" "$1" 2>/dev/null | tail -n 1 | awk '{print $NF}')
    echo "${area:-n/a}"
}

echo "[INFO][Cache area] ${#runs[@]} syntheses, $jobs in parallel"
running=0
for run in "${runs[@]}"; do
    read -r sets line <<< "$run"
    name="${cache}_${ways}w_${sets}s_${line}b"
    echo "[INFO][Cache area] Synthesizing $name"
    synthesize "$sets" "$line" "$name" &
    running=$((running + 1))
    if (( running >= jobs )); then
        wait -n || true
        running=$((running - 1))
    fi
done
wait || true

csv="cache_area/${cache}_${ways}w.csv"
status=0
echo "sets,line_bytes,cache_bytes,records,total_um2,stdcell_um2,sram_um2" > "$csv"
printf '\n%6s %10s %11s %8s %14s %14s %14s\n' \
    sets line_bytes cache_bytes records total_um2 stdcell_um2 sram_um2
for run in "${runs[@]}"; do
    read -r sets line <<< "$run"
    name="${cache}_${ways}w_${sets}s_${line}b"
    total=$(chip_area "cache_area/$name/reports/${name}_area.rpt")
    stdcell=$(chip_area "cache_area/$name/reports/${name}_area_logic.rpt")
    sram=$(awk -v t="$total" -v s="$stdcell" \
        'BEGIN { if (t + 0 > 0 && s + 0 > 0) printf "%.1f", t - s; else print "n/a" }')
    if [[ "$total" == n/a ]]; then
        echo "[ERROR][Cache area] $name failed, see yosys/cache_area/$name/yosys.log" >&2
        status=1
    fi
    bytes=$((ways * sets * line))
    records=$((bytes / 8))
    echo "$sets,$line,$bytes,$records,$total,$stdcell,$sram" >> "$csv"
    printf '%6s %10s %11s %8s %14s %14s %14s\n' \
        "$sets" "$line" "$bytes" "$records" "$total" "$stdcell" "$sram"
done
echo
echo "[INFO][Cache area] Results written to yosys/$csv"

exit "$status"
