# Copyright (c) 2024 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Authors:
# - Philippe Sauter <phsauter@iis.ee.ethz.ch>


# Technology models for the post-Yosys netlist simulation. The active
# technology view is initialized by ../env.sh.
# Delay gate with a real delay for the HyperBus delay lines; must precede the
# PDK cell library, since Verilator keeps the first definition of a module.
../ihp13/sg13g2_dlygate4sd1_1_sim.sv
../technology/verilog/sg13g2_udp.v
../technology/verilog/sg13g2_stdcell.v
../technology/verilog/RM_IHPSG13_1P_core_behavioral_bm_bist.v
../technology/verilog/RM_IHPSG13_1P_64x64_c2_bm_bist.v
../technology/verilog/RM_IHPSG13_1P_256x48_c2_bm_bist.v
../technology/verilog/RM_IHPSG13_1P_256x64_c2_bm_bist.v
../technology/verilog/RM_IHPSG13_1P_512x32_c2_bm_bist.v
../technology/verilog/RM_IHPSG13_1P_512x64_c2_bm_bist.v
../technology/verilog/RM_IHPSG13_1P_1024x64_c2_bm_bist.v
../technology/verilog/RM_IHPSG13_1P_2048x64_c2_bm_bist.v
