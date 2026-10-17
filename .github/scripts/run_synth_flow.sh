#!/bin/bash
# Copyright (c) 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Authors:
# - Philippe Sauter <phsauter@iis.ee.ethz.ch>
#
# Yosys synthesis flow with iDMA enabled.
# The netlist simulation still accepts both historical artifact names; both
# names are generated from this single iDMA-enabled synthesis result.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CROC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

cd "$CROC_ROOT"

echo "============================================="
echo "iDMA enabled — synthesis (croc_idma)"
echo "============================================="

# Explicitly select the configuration used by the current netlist tests.
"$SCRIPT_DIR/set_croc_config.sh" iDMAEnable=1

cd yosys
PROJ_NAME=croc_idma ./run_synthesis.sh --synth
cp out/netlist_debug.v out/croc_idma_yosys_debug.v
# Keep the legacy artifact name available for the netlist simulation flow.
cp out/netlist_debug.v out/croc_yosys_debug.v

echo ""
tail -n 40 reports/croc_idma_area.rpt

cd "$CROC_ROOT"

# Restore defaults
"$SCRIPT_DIR/set_croc_config.sh"

echo ""
echo "============================================="
echo " Synthesis completed"
echo "============================================="
