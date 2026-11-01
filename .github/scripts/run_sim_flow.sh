#!/bin/bash
# Copyright (c) 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Authors:
# - Philippe Sauter <phsauter@iis.ee.ethz.ch>
#
# Verilator simulation flow for RTL or post-Yosys netlists. Programs now run
# from HyperRAM; the SRAM only stores capability tags and is no longer mapped
# at 0x1000_0000. Only HyperRAM-linked programs are therefore simulated:
#   - CHERIoT tag-SRAM test
#   - CHERIoT-RTOS upstream regression suite
# The SRAM-linked programs (helloworld, print_config, sw/test, sw/cheriot) are
# still compiled but not simulated until they are ported to HyperRAM.

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
else
    export CROC_PDK=sg13cmos5l

    default_netlist="yosys/out/croc_yosys_debug.v"
    for required_file in \
        "$default_netlist" \
        "sw/bin/cheriot_tag_sram/test_tag_sram.hex"; do
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
    # Netlist simulation is substantially slower than RTL simulation.
    cheriot_test_timeout=7200
    rtos_test_timeout=7200
fi

echo "============================================="
echo "Build"
echo "============================================="

if [[ "$simulation_mode" == "rtl" ]]; then
    "$SCRIPT_DIR/set_croc_config.sh"
    # SRAM-linked programs are still compiled to catch build regressions.
    make -C sw
    # CHERIoT binaries are built only in the CHERIoT-enabled container. They
    # are kept outside the default GCC build so legacy tests stay independent.
    make -C sw cheriot
    make -C sw cheriot-tag-sram
    make -C sw cheriot-rtos
    make -C sw cheriot-rtos-tests
else
    cp "$default_netlist" yosys/out/netlist_debug.v
fi

cd verilator
# CI keeps simulator logs, but does not need an interactive waveform.
./run_verilator.sh --no-trace "$build_option"

echo ""
echo "============================================="
echo "CHERIoT tag-SRAM test"
echo "============================================="

"$SCRIPT_DIR/run_tests.sh" \
    --sim "$simulation_binary" \
    --hexdir ../sw/bin/cheriot_tag_sram \
    --filter 'test_tag_sram' \
    --timeout "$cheriot_test_timeout"

echo ""
echo "============================================="
echo "CHERIoT-RTOS upstream regression suite"
echo "============================================="

"$SCRIPT_DIR/run_tests.sh" \
    --sim "$simulation_binary" \
    --hexdir ../sw/bin/cheriot-rtos \
    --filter 'test-suite-*' \
    --timeout "$rtos_test_timeout"

cd "$CROC_ROOT"

echo ""
echo "============================================="
echo " Simulation completed"
echo "============================================="
