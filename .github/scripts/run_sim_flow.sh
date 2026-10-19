#!/bin/bash
# Copyright (c) 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Authors:
# - Philippe Sauter <phsauter@iis.ee.ethz.ch>
#
# Two-phase Verilator simulation flow for RTL or post-Yosys netlists:
#   Phase 1 (default): Run helloworld, print_config, and CHERIoT programs
#   Phase 2 (iDMA on): Run all unit tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CROC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

show_help() {
    cat <<EOF
Usage: $0 [--rtl|--netlist]

    --rtl       Build and simulate RTL (default)
    --netlist   Simulate the default and iDMA post-Yosys netlists
EOF
}

simulation_mode="rtl"
if [[ $# -gt 1 ]]; then
    show_help >&2
    exit 1
fi

# Each individual RTL test may use up to 45 minutes. The enclosing GitHub job
# still has a six-hour limit, so this does not extend the job indefinitely.
cheriot_test_timeout=2700
rtos_test_timeout=2700
legacy_test_timeout=2700

case "${1:-}" in
    ""|--rtl)
        ;;
    --netlist)
        simulation_mode="netlist"
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

cd "$CROC_ROOT"

if [[ "$simulation_mode" == "rtl" ]]; then
    # Always restore the checked-in default after a configuration-specific run.
    trap '"$SCRIPT_DIR/set_croc_config.sh"' EXIT

    build_option="--build"
    run_option="--run"
    simulation_binary="obj_dir_rtl/Vtb_croc_soc"
    simulation_log="croc_rtl.log"
else
    export CROC_PDK=sg13cmos5l

    default_netlist="yosys/out/croc_yosys_debug.v"
    idma_netlist="yosys/out/croc_idma_yosys_debug.v"
    for required_file in \
        "$default_netlist" \
        "$idma_netlist" \
        "sw/bin/helloworld.hex" \
        "sw/bin/test/print_config.hex" \
        "sw/bin/cheriot-rtos/hello_world.hex"; do
        if [[ ! -f "$required_file" ]]; then
            echo "[ERROR] Missing netlist simulation input: $required_file" >&2
            exit 1
        fi
    done

    upstream_tests=(
        ccompile extra_compiles preflight debug_cxx debug_c mmio
        unwind_cleanup softfloat stdio static_sealing crash_recovery
        compartment_calls check_pointer misc stack thread_pool
        global_constructors queue futex locks list eventgroup multiwaiter
        bitpacks time
    )
    for upstream_test in "${upstream_tests[@]}"; do
        required_file="sw/bin/cheriot-rtos/test-suite-${upstream_test}.hex"
        if [[ ! -f "$required_file" ]]; then
            echo "[ERROR] Missing netlist simulation input: $required_file" >&2
            exit 1
        fi
    done

    build_option="--build-netlist"
    run_option="--run-netlist"
    simulation_binary="obj_dir_netlist_yosys/Vtb_croc_soc"
    simulation_log="croc_netlist_yosys.log"
    # Netlist simulation is substantially slower than RTL simulation.
    cheriot_test_timeout=7200
    rtos_test_timeout=7200
    legacy_test_timeout=7200
fi

echo "============================================="
echo "Phase 1: default config — helloworld"
echo "============================================="

if [[ "$simulation_mode" == "rtl" ]]; then
    "$SCRIPT_DIR/set_croc_config.sh"
    make -C sw
    # CHERIoT binaries are built only in the CHERIoT-enabled container. They
    # are kept outside the default GCC build so legacy tests stay independent.
    make -C sw cheriot
    make -C sw cheriot-rtos
    make -C sw cheriot-rtos-tests
else
    cp "$default_netlist" yosys/out/netlist_debug.v
fi

cd verilator
# CI keeps simulator logs, but does not need an interactive waveform.
./run_verilator.sh --no-trace "$build_option"
./run_verilator.sh "$run_option" ../sw/bin/helloworld.hex
grep -q "\[UART\] Hello World from Croc!" "$simulation_log"

./run_verilator.sh "$run_option" ../sw/bin/test/print_config.hex
"$SCRIPT_DIR/check_sim.sh" "$simulation_log"
grep -q "\[JTAG\] Simulation finished: SUCCESS" "$simulation_log"

echo ""
echo "============================================="
echo "Phase 1b: default config — CHERIoT programs"
echo "============================================="

"$SCRIPT_DIR/run_tests.sh" \
    --sim "$simulation_binary" \
    --hexdir ../sw/bin/cheriot \
    --filter '*' \
    --exclude test_simple_recv_bitmap_storage \
    --expect-fail test_cheriot_exception \
    --timeout "$cheriot_test_timeout"

echo ""
echo "============================================="
echo "Phase 1c: default config — CHERIoT-RTOS upstream regression suite"
echo "============================================="

"$SCRIPT_DIR/run_tests.sh" \
    --sim "$simulation_binary" \
    --hexdir ../sw/bin/cheriot-rtos \
    --filter 'test-suite-*' \
    --timeout "$rtos_test_timeout"

cd "$CROC_ROOT"

echo ""
echo "============================================="
echo "Phase 2: iDMA enabled — unit tests"
echo "============================================="

if [[ "$simulation_mode" == "rtl" ]]; then
    "$SCRIPT_DIR/set_croc_config.sh" iDMAEnable=1
else
    cp "$idma_netlist" yosys/out/netlist_debug.v
fi

cd verilator
./run_verilator.sh --no-trace "$build_option"

"$SCRIPT_DIR/run_tests.sh" \
    --sim "$simulation_binary" \
    --timeout "$legacy_test_timeout"
cd "$CROC_ROOT"

echo ""
echo "============================================="
echo " Simulation completed"
echo "============================================="
