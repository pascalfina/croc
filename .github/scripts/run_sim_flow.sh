#!/bin/bash
# Copyright (c) 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Authors:
# - Philippe Sauter <phsauter@iis.ee.ethz.ch>
#
# Verilator simulation flow for RTL or post-Yosys netlists. Programs run from
# the cached HyperRAM, so only HyperRAM-linked CHERIoT-RTOS programs are
# simulated: every image in sw/bin/cheriot-rtos/, i.e. the upstream regression
# suite (test-suite-*) and all Croc programs of CHERIOT_RTOS_PROJECTS in
# sw/Makefile.
# The bare-metal programs (helloworld, sw/test, sw/cheriot) and the legacy
# tag-SRAM test are still compiled to catch build regressions, but not
# simulated. The tag-SRAM test probes HyperRAM up to 4 MiB and the old tag-SRAM
# bank layout, beyond the testbench's reduced HyperRAM initialisation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CROC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

show_help() {
    cat <<EOF
Usage: $0 [--rtl | --software | --shard INDEX/COUNT | --netlist]

    --rtl                Build software and the RTL simulator, run all tests (default)
    --software           Build the software only
    --shard INDEX/COUNT  Build the RTL simulator and run every COUNT-th test,
                         starting at INDEX (0-based); expects built software
    --netlist            Run the hello_world smoke test on the post-Yosys netlist
EOF
}

mode="rtl"
shard_index=0
shard_count=1

case "${1:-}" in
    ""|--rtl)
        ;;
    --software)
        mode="software"
        ;;
    --shard)
        mode="shard"
        if [[ ! "${2:-}" =~ ^([0-9]+)/([1-9][0-9]*)$ ]]; then
            echo "[ERROR] --shard expects INDEX/COUNT, e.g. 0/6" >&2
            exit 1
        fi
        shard_index=${BASH_REMATCH[1]}
        shard_count=${BASH_REMATCH[2]}
        if (( shard_index >= shard_count )); then
            echo "[ERROR] Shard index $shard_index must be below $shard_count" >&2
            exit 1
        fi
        ;;
    --netlist)
        mode="netlist"
        ;;
    -h|--help)
        show_help
        exit 0
        ;;
    *)
        echo "[ERROR] Unknown argument: $1" >&2
        show_help >&2
        exit 1
        ;;
esac

# Each RTL test may use up to 90 minutes; the cache stress test alone takes
# about 45 minutes. The enclosing GitHub job still has a six-hour limit.
rtos_test_timeout=5400

cd "$CROC_ROOT"

build_software() {
    echo "============================================="
    echo "Build software"
    echo "============================================="
    # Bare-metal programs are still compiled to catch build regressions.
    make -C sw
    # CHERIoT binaries are built only in the CHERIoT-enabled container.
    make -C sw cheriot
    make -C sw cheriot-tag-sram
    make -C sw cheriot-rtos
    make -C sw cheriot-rtos-tests
}

# Collects every built RTOS image into all_tests, sorted. Locally, remove
# sw/bin/cheriot-rtos/ first if it may still hold images of deleted programs.
collect_rtos_tests() {
    local hexdir="$CROC_ROOT/sw/bin/cheriot-rtos"
    local hex
    local found=()

    for hex in "$hexdir"/*.hex; do
        [[ -f "$hex" ]] && found+=("$hex")
    done
    if ! printf '%s\n' "${found[@]}" | grep -q '/test-suite-[^/]*\.hex$'; then
        echo "[ERROR] No upstream test-suite HEX files in $hexdir" >&2
        exit 1
    fi
    mapfile -t all_tests < <(printf '%s\n' "${found[@]}" | sort)
}

# Runs the given HEX files through run_tests.sh from a temporary directory of
# links, so that any subset can be selected. Must be called from verilator/.
run_hex_files() {
    local simulation_binary=$1
    local timeout=$2
    shift 2

    local selection status=0
    selection="$(mktemp -d)"
    local hex
    for hex in "$@"; do
        ln -s "$hex" "$selection/"
    done

    "$SCRIPT_DIR/run_tests.sh" \
        --sim "$simulation_binary" \
        --hexdir "$selection" \
        --filter '*' \
        --timeout "$timeout" || status=$?
    rm -rf -- "$selection"
    return "$status"
}

if [[ "$mode" == "software" ]]; then
    build_software
    exit 0
fi

if [[ "$mode" == "netlist" ]]; then
    export CROC_PDK=sg13cmos5l

    default_netlist="yosys/out/croc_yosys_debug.v"
    smoke_test="sw/bin/cheriot-rtos/hello_world.hex"
    for required_file in "$default_netlist" "$smoke_test"; do
        if [[ ! -f "$required_file" ]]; then
            echo "[ERROR] Missing netlist simulation input: $required_file" >&2
            exit 1
        fi
    done
    cp "$default_netlist" yosys/out/netlist_debug.v

    cd verilator
    ./run_verilator.sh --no-trace --build-netlist

    echo ""
    echo "============================================="
    echo "Netlist smoke test"
    echo "============================================="
    # The netlist keeps the hardware default of 4 MiB HyperRAM initialisation
    # and is substantially slower than RTL simulation.
    run_hex_files obj_dir_netlist_yosys/Vtb_croc_soc 18000 "$CROC_ROOT/$smoke_test"
    exit 0
fi

# Always restore the checked-in default after a configuration-specific run.
trap '"$SCRIPT_DIR/set_croc_config.sh"' EXIT
"$SCRIPT_DIR/set_croc_config.sh"

if [[ "$mode" == "rtl" ]]; then
    build_software
fi

collect_rtos_tests
selected_tests=()
for i in "${!all_tests[@]}"; do
    if (( i % shard_count == shard_index )); then
        selected_tests+=("${all_tests[$i]}")
    fi
done
if [[ ${#selected_tests[@]} -eq 0 ]]; then
    echo "[ERROR] Shard $shard_index/$shard_count selects no tests" >&2
    exit 1
fi

echo "============================================="
echo "Build RTL simulator"
echo "============================================="
cd verilator
# CI keeps simulator logs, but does not need an interactive waveform.
./run_verilator.sh --no-trace --build

echo ""
echo "============================================="
echo "CHERIoT-RTOS tests (shard $shard_index/$shard_count)"
echo "============================================="
run_hex_files obj_dir_rtl/Vtb_croc_soc "$rtos_test_timeout" "${selected_tests[@]}"

cd "$CROC_ROOT"

echo ""
echo "============================================="
echo " Simulation completed"
echo "============================================="
