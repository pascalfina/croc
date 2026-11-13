#!/bin/bash
# Copyright (c) 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Runs the cache area and performance sweeps into one evaluation directory and
# joins their results per configuration.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

show_help() {
    cat <<EOF
Usage: $0 [options] [data|instruction] [ways]

Synthesizes and simulates the cache configurations of yosys/run_cache_area.sh
and verilator/run_cache_perf.sh. Defaults: data cache, 2 ways, area and
performance in a new evaluation cache_eval/<YYYYmmdd_HHMMSS>/.

Options:
    --area       run only the area sweep
    --perf       run only the performance sweep
    --summary    run no sweep, only rebuild summary.csv (needs --eval)
    --eval NAME  add to the existing evaluation cache_eval/NAME
    --overwrite  run a sweep whose CSV already exists in NAME; configurations
                 run again replace their rows, the others stay

CACHE_SETS, CACHE_LINES and JOBS are passed on to both sweeps.

Results in cache_eval/<eval>/:
    area/<cache>_<ways>w.csv          area, syntheses in area/<config>/
    performance/<cache>_<ways>w.csv   cycles, simulations in performance/<config>/
    summary.csv                       both joined per configuration
cache_eval/latest points to the newest evaluation.
EOF
}

run_area=0
run_perf=0
summary_only=0
overwrite=0
eval_name=""
positional=()
while (( $# > 0 )); do
    case "$1" in
        -h|--help)   show_help; exit 0 ;;
        --area)      run_area=1 ;;
        --perf)      run_perf=1 ;;
        --summary)   summary_only=1 ;;
        --overwrite) overwrite=1 ;;
        --eval)
            if (( $# < 2 )); then
                show_help >&2
                exit 1
            fi
            eval_name=$2
            shift
            ;;
        -*) show_help >&2; exit 1 ;;
        *)  positional+=("$1") ;;
    esac
    shift
done

cache=${positional[0]:-data}
ways=${positional[1]:-2}
sweep="${cache}_${ways}w"

if [[ "$cache" != data && "$cache" != instruction ]] || (( ${#positional[@]} > 2 )); then
    show_help >&2
    exit 1
fi

if (( summary_only )); then
    run_area=0
    run_perf=0
elif (( !run_area && !run_perf )); then
    run_area=1
    run_perf=1
fi

if [[ -n "$eval_name" ]]; then
    eval_dir="cache_eval/$(basename "$eval_name")"
    if [[ ! -d "$eval_dir" ]]; then
        echo "[ERROR][Cache eval] No evaluation $eval_dir" >&2
        exit 1
    fi
elif (( summary_only )); then
    echo "[ERROR][Cache eval] --summary needs --eval" >&2
    exit 1
else
    eval_dir="cache_eval/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$eval_dir"
    ln -sfn "$(basename "$eval_dir")" cache_eval/latest
fi
# The sweeps change into their own directories.
eval_dir=$(realpath "$eval_dir")
shown_dir="cache_eval/$(basename "$eval_dir")"

for part in area performance; do
    if [[ "$part" == area ]] && (( !run_area )); then continue; fi
    if [[ "$part" == performance ]] && (( !run_perf )); then continue; fi
    if [[ -f "$eval_dir/$part/$sweep.csv" ]] && (( !overwrite )); then
        echo "[ERROR][Cache eval] $shown_dir/$part/$sweep.csv exists, pass --overwrite to run it again" >&2
        exit 1
    fi
done

status=0
if (( run_area )); then
    RESULT_DIR="$eval_dir/area" yosys/run_cache_area.sh "$cache" "$ways" || status=1
fi
if (( run_perf )); then
    RESULT_DIR="$eval_dir/performance" verilator/run_cache_perf.sh "$cache" "$ways" || status=1
fi

# Joins each sweep's area and performance rows by sets and line size; a
# configuration that only one side has leaves the other side's columns empty.
summary_rows() {
    local name=$1
    local files=()
    local file
    for file in "$eval_dir/area/$name.csv" "$eval_dir/performance/$name.csv"; do
        if [[ -f "$file" ]]; then
            files+=("$file")
        fi
    done
    local ways=${name##*_}
    awk -F, -v OFS=, -v cache="${name%_*}" -v ways="${ways%w}" -v area_csv="$eval_dir/area/$name.csv" '
        { gsub(/[ \r]/, "") }
        FNR == 1 { next }
        { key = $1 "," $2; bytes[key] = $3 }
        FILENAME == area_csv { area[key] = $4 "," $5 "," $6 "," $7; next }
        { perf[key] = $4; for (i = 5; i <= 14; i++) perf[key] = perf[key] "," $i }
        END {
            for (key in bytes) {
                a = (key in area) ? area[key] : bytes[key] / 8 ",,,"
                p = (key in perf) ? perf[key] : ",,,,,,,,,,"
                print cache, ways, key, bytes[key], a, p
            }
        }' "${files[@]}"
}

{
    echo "cache,ways,sets,line_bytes,cache_bytes,records,total_um2,stdcell_um2,sram_um2,total_cycles,init,stream,copy,stride,random,chase,capabilities,code,checksum,perf_status"
    for file in "$eval_dir"/area/*w.csv "$eval_dir"/performance/*w.csv; do
        if [[ -f "$file" ]]; then
            basename "$file" .csv
        fi
    done | sort -u | while read -r name; do
        summary_rows "$name"
    done | sort -t, -k1,1 -k2,2n -k3,3n -k4,4n
} > "$eval_dir/summary.csv"

echo "[INFO][Cache eval] $(( $(wc -l < "$eval_dir/summary.csv") - 1 )) configurations in $shown_dir/summary.csv"

exit "$status"
