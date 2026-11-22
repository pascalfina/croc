#!/bin/bash
# Copyright (c) 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Authors:
# - Philippe Sauter <phsauter@iis.ee.ethz.ch>
#
# Yosys synthesis flow with iDMA disabled.
# No netlist test uses the iDMA, so it is left out to keep the netlist small.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CROC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

cd "$CROC_ROOT"

echo "============================================="
echo "iDMA disabled — synthesis (croc)"
echo "============================================="

# Explicitly select the configuration used by the current netlist tests.
"$SCRIPT_DIR/set_croc_config.sh" iDMAEnable=0

cd yosys
./run_synthesis.sh --synth
cp out/netlist_debug.v out/croc_yosys_debug.v

echo ""
tail -n 40 reports/croc_area.rpt

cd "$CROC_ROOT"

# Restore defaults
"$SCRIPT_DIR/set_croc_config.sh"

echo ""
echo "============================================="
echo " Synthesis completed"
echo "============================================="
