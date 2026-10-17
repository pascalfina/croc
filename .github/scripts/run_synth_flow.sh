#!/bin/bash
# Copyright (c) 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Authors:
# - Philippe Sauter <phsauter@iis.ee.ethz.ch>
#
# Two-phase Yosys synthesis flow:
#   Phase 1: Synthesize without iDMA, PROJ_NAME=croc
#   Phase 2: Synthesize with iDMA,    PROJ_NAME=croc_idma

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CROC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

cd "$CROC_ROOT"

echo "============================================="
echo "Phase 1: iDMA disabled — synthesis (croc)"
echo "============================================="

# The checked-in default currently enables iDMA. Override it explicitly for
# the baseline netlist so the two synthesis results are genuinely distinct.
"$SCRIPT_DIR/set_croc_config.sh" iDMAEnable=0

cd yosys
./run_synthesis.sh --synth
cp out/netlist_debug.v out/croc_yosys_debug.v

echo ""
tail -n 40 reports/croc_area.rpt

cd "$CROC_ROOT"

echo ""
echo "============================================="
echo "Phase 2: iDMA enabled — synthesis (croc_idma)"
echo "============================================="

# Enable iDMA
"$SCRIPT_DIR/set_croc_config.sh" iDMAEnable=1

cd yosys
PROJ_NAME=croc_idma ./run_synthesis.sh --synth
cp out/netlist_debug.v out/croc_idma_yosys_debug.v

echo ""
tail -n 40 reports/croc_idma_area.rpt

cd "$CROC_ROOT"

# Restore defaults
"$SCRIPT_DIR/set_croc_config.sh"

echo ""
echo "============================================="
echo " Synthesis completed"
echo "============================================="
