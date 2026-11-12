#!/usr/bin/env bash
# Copyright (c) 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Runs the CHERIoT-RTOS images on the post-Yosys netlist, several tests in
# parallel. The netlist simulator is built once (without waveform tracing) and
# every test then runs as a separate process of the same binary.
# Run inside the CHERIoT container (scripts/start_cheriot_badile.sh), after
# yosys/run_synthesis.sh --synth and make -C sw cheriot-rtos cheriot-rtos-tests.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERILATOR_DIR="$ROOT_DIR/verilator"
HEX_DIR="$ROOT_DIR/sw/bin/cheriot-rtos"
NETLIST="$ROOT_DIR/yosys/out/netlist_debug.v"
SIM="$VERILATOR_DIR/obj_dir_netlist_yosys/Vtb_croc_soc"

jobs=8
timeout=43200  # 12 h per test; netlist tests can take many hours
filter='*'
build=auto
out_dir="$VERILATOR_DIR/netlist_run"
status_interval=60

show_help() {
    cat <<EOF
Usage: $0 [-j JOBS] [--filter GLOB] [--timeout SECONDS] [--build | --no-build]
          [--out DIR] [--status SECONDS]

    -j JOBS            Number of tests run in parallel (default: $jobs)
    --filter GLOB      Only run images matching GLOB.hex (default: all)
    --timeout SECONDS  Per-test timeout (default: $timeout)
    --build            Always rebuild the netlist simulator
    --no-build         Never rebuild; use the existing simulator
    --out DIR          Directory for the per-test logs (default: verilator/netlist_run)
    --status SECONDS   Interval of the progress report; 0 disables it (default: $status_interval)

By default the simulator is rebuilt only if it is missing or older than
yosys/out/netlist_debug.v.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -j)          jobs="$2";    shift 2 ;;
        --filter)    filter="$2";  shift 2 ;;
        --timeout)   timeout="$2"; shift 2 ;;
        --build)     build=yes;    shift ;;
        --no-build)  build=no;     shift ;;
        --out)       out_dir="$(realpath -m "$2")"; shift 2 ;;
        --status)    status_interval="$2"; shift 2 ;;
        -h|--help)   show_help; exit 0 ;;
        *)           echo "[ERROR] Unknown argument: $1" >&2; show_help >&2; exit 1 ;;
    esac
done

now() { date +%H:%M:%S; }
info() { echo "[$(now)] $*"; }

# Formats a duration in seconds as h:mm:ss.
fmt_duration() {
    printf '%d:%02d:%02d' $(($1 / 3600)) $(($1 % 3600 / 60)) $(($1 % 60))
}

# The host may provide an unrelated verilator (e.g. /usr/sepp/bin), so check
# for the container's tool installation instead.
if [[ ! -x /foss/tools/bin/verilator ]]; then
    echo "[ERROR] Not inside the CHERIoT container; start scripts/start_cheriot_badile.sh first" >&2
    exit 1
fi

if [[ ! -f "$NETLIST" ]]; then
    echo "[ERROR] Missing $NETLIST; run yosys/run_synthesis.sh --synth first" >&2
    exit 1
fi

shopt -s nullglob
hex_files=("$HEX_DIR"/$filter.hex)
shopt -u nullglob
if [[ ${#hex_files[@]} -eq 0 ]]; then
    echo "[ERROR] No images matching '$filter.hex' in $HEX_DIR" >&2
    exit 1
fi

info "Netlist:   $NETLIST ($(date -r "$NETLIST" '+%Y-%m-%d %H:%M'))"
info "Simulator: $SIM"
info "Images:    ${#hex_files[@]} from $HEX_DIR"
info "Jobs: $jobs, timeout per test: $(fmt_duration "$timeout"), logs: $out_dir"

status_pid=""
stop_status() {
    if [[ -n "$status_pid" ]]; then
        kill "$status_pid" 2>/dev/null
        wait "$status_pid" 2>/dev/null
        status_pid=""
    fi
}

# Ctrl-C stops every running simulation, not only this script.
trap 'trap - INT TERM; info "Interrupted, stopping all simulations"; kill 0' INT TERM
trap stop_status EXIT

# Reports which object files the compiler is still working on; a single large
# file of the netlist can take well over ten minutes without any output.
build_status_loop() {
    local start=$SECONDS files done_count
    while sleep "$status_interval"; do
        files="$(ps -u "$(id -u)" -o args= \
            | grep -o -- '-o Vtb_croc_soc[^ ]*\.o' | sed 's/^-o //' | sort -u | tr '\n' ' ')"
        done_count=$(find "$VERILATOR_DIR/obj_dir_netlist_yosys" -maxdepth 1 -name '*.o' \
            -newer "$out_dir/.build_start" 2>/dev/null | wc -l)
        info "[build] running $(fmt_duration $((SECONDS - start))), objects done: $done_count, compiling: ${files:-none (verilating or linking)}"
    done
}

if [[ "$build" == yes || ( "$build" == auto && ( ! -x "$SIM" || "$NETLIST" -nt "$SIM" ) ) ]]; then
    if [[ ! -x "$SIM" ]]; then
        info "Simulator missing, building it"
    elif [[ "$build" == yes ]]; then
        info "Rebuild requested"
    else
        info "Simulator ($(date -r "$SIM" '+%Y-%m-%d %H:%M')) is older than the netlist, rebuilding"
    fi
    mkdir -p "$out_dir"
    touch "$out_dir/.build_start"
    if (( status_interval > 0 )); then
        build_status_loop &
        status_pid=$!
    fi
    build_start=$SECONDS
    export CROC_PDK=sg13cmos5l
    (cd "$VERILATOR_DIR" && ./run_verilator.sh --no-trace --build-netlist)
    build_rc=$?
    stop_status
    rm -f "$out_dir/.build_start"
    if [[ $build_rc -ne 0 ]]; then
        echo "[ERROR] Netlist simulator build failed; see verilator/croc_netlist_yosys_build.log" >&2
        exit 1
    fi
    info "Build finished in $(fmt_duration $((SECONDS - build_start)))"
else
    info "Using existing simulator ($(date -r "$SIM" '+%Y-%m-%d %H:%M'))"
fi
if [[ ! -x "$SIM" ]]; then
    echo "[ERROR] Missing simulator $SIM" >&2
    exit 1
fi

mkdir -p "$out_dir"
running_dir="$out_dir/.running"
rm -rf "$running_dir"
mkdir -p "$running_dir"
results="$out_dir/results.txt"
: > "$results"

# Runs one image and appends a single result line, so that parallel tests
# never interleave their output. A marker file in .running/ holds the start
# time for the progress report.
run_one() {
    local hex=$1
    local name log start rc result fail_line
    name="$(basename "$hex" .hex)"
    log="$out_dir/$name.log"
    start=$SECONDS
    date +%s > "$running_dir/$name"
    info "START $name"

    # --foreground keeps the simulator in this script's process group, so that
    # Ctrl-C and the interrupt trap reach it.
    (cd "$VERILATOR_DIR" && timeout --foreground "$timeout" "$SIM" "+binary=$hex") > "$log" 2>&1
    rc=$?

    if [[ $rc -eq 124 ]]; then
        result="FAIL (timeout after $(fmt_duration "$timeout"))"
    elif grep -q '\[JTAG\] Simulation finished: SUCCESS' "$log"; then
        result="PASS"
    elif fail_line="$(grep -m1 '\[JTAG\] Simulation finished: FAIL' "$log")"; then
        result="FAIL ($(sed -n 's/.*\(return code 0x[0-9a-fA-F]*\).*/\1/p' <<< "$fail_line"))"
    else
        result="FAIL (no result line, sim exit=$rc)"
    fi
    rm -f "$running_dir/$name"
    printf '[%s] %-35s %s (%s)\n' "$(now)" "$name" "$result" \
        "$(fmt_duration $((SECONDS - start)))" | tee -a "$results"
}

# Prints every running test with its runtime and the last testbench message,
# e.g. the JTAG load address or the latest UART line.
test_status_loop() {
    local total=$1 marker name started last finished passed
    while sleep "$status_interval"; do
        finished=$(wc -l < "$results")
        passed=$(grep -c ' PASS ' "$results")
        echo "---------- [$(now)] status: $finished/$total finished ($passed passed, $((finished - passed)) failed) ----------"
        for marker in "$running_dir"/*; do
            # A test may finish and remove its marker while it is listed.
            started=$(cat "$marker" 2>/dev/null) || continue
            [[ -n "$started" ]] || continue
            name="$(basename "$marker")"
            last="$(grep -E '\[(JTAG|UART|CORE)\]' "$out_dir/$name.log" 2>/dev/null \
                | grep -v 'raw:' | tail -n 1 | cut -c1-110)"
            printf '  %-32s %s  %s\n' "$name" "$(fmt_duration $(($(date +%s) - started)))" \
                "${last:-(no output yet)}"
        done
    done
}

info "Running ${#hex_files[@]} test(s), $jobs in parallel"
if (( status_interval > 0 )); then
    test_status_loop "${#hex_files[@]}" &
    status_pid=$!
fi
run_start=$SECONDS
test_pids=()
for hex in "${hex_files[@]}"; do
    # The status loop is a background job as well and must not be counted.
    while [[ $(jobs -rp | grep -vx "${status_pid:-none}" | wc -l) -ge $jobs ]]; do
        wait -n
    done
    run_one "$hex" &
    test_pids+=($!)
done
# Wait for the tests only; the status loop runs until it is stopped.
wait "${test_pids[@]}"
stop_status
rmdir "$running_dir" 2>/dev/null

passed=$(grep -c ' PASS ' "$results")
total=$(wc -l < "$results")
echo "========================================="
echo "Summary: $passed passed, $((total - passed)) failed, $total total in $(fmt_duration $((SECONDS - run_start)))"
echo "Results: $results"
if [[ $passed -ne $total ]]; then
    echo "Failed tests:"
    grep -v ' PASS ' "$results" | sort -k2
    exit 1
fi
echo "All tests passed."
