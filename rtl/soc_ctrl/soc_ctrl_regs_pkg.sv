// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Authors:
// - Enrico Zelioli <ezelioli@iis.ee.ethz.ch>

package soc_ctrl_regs_pkg;

  // Internal address width. 6 bits covers offsets 0x00–0x24.
  localparam int unsigned IntAddrWidth = 6;

  // Register offsets
  parameter logic [IntAddrWidth-1:0] SOC_CTRL_BOOTADDR_OFFSET   = 5'h00;
  parameter logic [IntAddrWidth-1:0] SOC_CTRL_FETCHEN_OFFSET    = 5'h04;
  parameter logic [IntAddrWidth-1:0] SOC_CTRL_CORESTATUS_OFFSET = 5'h08;
  parameter logic [IntAddrWidth-1:0] SOC_CTRL_BOOTMODE_OFFSET   = 5'h0c;
  parameter logic [IntAddrWidth-1:0] SOC_CTRL_SRAM_DLY_OFFSET   = 5'h10;
  parameter logic [IntAddrWidth-1:0] SOC_CTRL_INFO_OFFSET       = 5'h14;
  parameter logic [IntAddrWidth-1:0] SOC_CTRL_CHERIOT_ENABLE_OFFSET = 6'h18;
  parameter logic [IntAddrWidth-1:0] SOC_CTRL_EXCEPTION_CAUSE_OFFSET = 6'h1c;
  parameter logic [IntAddrWidth-1:0] SOC_CTRL_EXCEPTION_TVAL_OFFSET  = 6'h20;
  parameter logic [IntAddrWidth-1:0] SOC_CTRL_EXCEPTION_MEPC_OFFSET  = 6'h24;

endpackage
