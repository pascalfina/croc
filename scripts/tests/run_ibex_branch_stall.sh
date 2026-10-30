#!/usr/bin/env bash
# Copyright 2026 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

set -euo pipefail
ulimit -c 0

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/croc-branch-stall.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT

# DII_SIM disables a debug print that references the absent full-core hierarchy.
"${VERILATOR:-verilator}" --binary --timing --assert -DDII_SIM -j 2 \
    -Wno-fatal -Wno-PINMISSING -Wno-TIMESCALEMOD \
    --top-module tb_ibex_branch_stall --Mdir "$build_dir" \
    -I"$root/ibex/vendor/lowrisc_ip/ip/prim/rtl" \
    -I"$root/ibex/vendor/lowrisc_ip/dv/sv/dv_utils" \
    "$root/ibex/rtl/ibex_pkg.sv" \
    "$root/ibex/rtl/ibex_cheriot_pkg.sv" \
    "$root/ibex/rtl/ibex_decoder.sv" \
    "$root/ibex/rtl/ibex_controller.sv" \
    "$root/ibex/rtl/ibex_id_stage.sv" \
    "$root/scripts/tests/ibex_branch_stall.sv" >"$build_dir/build.log" 2>&1 || {
    cat "$build_dir/build.log"
    exit 1
}

"$build_dir/Vtb_ibex_branch_stall"
