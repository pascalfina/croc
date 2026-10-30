// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

module ibex_branch_stall_case #(
  parameter bit CheriotMode = 1'b1,
  parameter bit FixedTime = 1'b0
) (
  output logic done_o
);
  timeunit 1ns;
  timeprecision 1ps;
  import ibex_pkg::*;

  localparam logic [31:0] BranchPc = 32'h8000_03b6;
  localparam logic [31:0] BranchInsn = 32'hfeb5_13e3; // bne a0, a1, -26
  localparam logic [31:0] BranchTarget = 32'h8000_039c;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic instr_valid = 1'b0;
  logic [31:0] instr = 32'h0000_0013;
  logic [31:0] reg_a = 32'd1;
  logic outstanding_load = 1'b0;
  logic outstanding_store = 1'b0;
  logic lsu_response = 1'b0;
  logic ready_wb = 1'b1;
  logic pc_set, instr_done;
  pc_sel_e pc_mux;
  alu_op_e alu_operator;
  logic [31:0] alu_a, alu_b;

  always #5ns clk = ~clk;

  ibex_id_stage #(
    .RV32E(1'b1),
    .DataIndTiming(FixedTime),
    .BranchTargetALU(1'b0),
    .WritebackStage(1'b1)
  ) dut (
    .clk_i(clk),
    .rst_ni(rst_n),
    .cheriot_enable_i(CheriotMode ? IbexMuBiOn : IbexMuBiOff),
    .instr_valid_i(instr_valid),
    .instr_rdata_i(instr),
    .instr_rdata_alu_i(instr),
    .instr_rdata_c_i(16'b0),
    .instr_is_compressed_i(1'b0),
    .instr_gets_expanded_i(INSTR_NOT_EXPANDED),
    .instr_bp_taken_i(1'b0),
    .instr_exec_i(1'b1),
    .branch_decision_i(reg_a != 32'd15),
    .pc_set_o(pc_set),
    .pc_mux_o(pc_mux),
    .illegal_c_insn_i(1'b0),
    .instr_fetch_err_i(1'b0),
    .instr_fetch_err_plus2_i(1'b0),
    .instr_fetch_cheriot_acc_vio_i(1'b0),
    .instr_fetch_cheriot_bound_vio_i(1'b0),
    .pc_id_i(BranchPc),
    .ex_valid_i(1'b1),
    .lsu_resp_valid_i(lsu_response),
    .alu_operator_ex_o(alu_operator),
    .alu_operand_a_ex_o(alu_a),
    .alu_operand_b_ex_o(alu_b),
    .imd_val_we_ex_i(2'b0),
    .imd_val_d_ex_i('{default: 34'b0}),
    .priv_mode_i(PRIV_LVL_M),
    .csr_mstatus_tw_i(1'b0),
    .illegal_csr_insn_i(1'b0),
    .data_ind_timing_i(FixedTime),
    .csr_pcc_perm_sr_i(1'b1),
    .lsu_req_done_i(1'b0),
    .lsu_addr_incr_req_i(1'b0),
    .lsu_addr_last_i(32'b0),
    .csr_mstatus_mie_i(1'b0),
    .irq_pending_i(1'b0),
    .irqs_i('0),
    .irq_nm_i(1'b0),
    .lsu_load_err_i(1'b0),
    .lsu_load_resp_intg_err_i(1'b0),
    .lsu_store_err_i(1'b0),
    .lsu_store_resp_intg_err_i(1'b0),
    .lsu_err_is_cheriot_i(1'b0),
    .debug_req_i(1'b0),
    .debug_single_step_i(1'b0),
    .debug_ebreakm_i(1'b0),
    .debug_ebreaku_i(1'b0),
    .trigger_match_i(1'b0),
    .result_ex_i(32'b0),
    .csr_rdata_i(32'b0),
    .rf_rdata_a_i(reg_a),
    .rf_rdata_b_i(32'd15),
    .rf_waddr_wb_i(5'b0),
    .rf_wdata_fwd_wb_i(32'b0),
    .rf_write_wb_i(1'b0),
    .ready_wb_i(ready_wb),
    .outstanding_load_wb_i(outstanding_load),
    .outstanding_store_wb_i(outstanding_store),
    .instr_id_done_o(instr_done),
    .cheriot_ex_valid_i(1'b1),
    .cheriot_ex_err_i(1'b0),
    .cheriot_ex_err_info_i(12'b0),
    .cheriot_wb_err_i(1'b0),
    .cheriot_wb_err_info_i(16'b0),
    .cheriot_branch_req_i(1'b0),
    .cheriot_branch_target_i(32'b0)
  );

  task automatic run_branch(input bit taken, input int unsigned delay_cycles,
                            input bit pending_load = 1'b0);
    int unsigned redirects;
    bit retired;
    logic [31:0] expected_target;
    redirects = 0;
    retired = 1'b0;
    expected_target = taken ? BranchTarget : BranchPc + 32'd4;

    @(negedge clk);
    instr = BranchInsn;
    instr_valid = 1'b1;
    reg_a = taken ? 32'd1 : 32'd15;
    outstanding_load = (delay_cycles != 0) && pending_load;
    outstanding_store = (delay_cycles != 0) && !pending_load;
    ready_wb = (delay_cycles == 0);

    // Model WB waiting for the second capability-store response, as in the FST.
    repeat (delay_cycles) begin
      #1ns;
      if ((pc_set && pc_mux == PC_JUMP) || instr_done)
        $fatal(1, "Branch advanced before memory completion (CHERIoT=%0b, fixed=%0b)",
               CheriotMode, FixedTime);
      @(posedge clk);
      @(negedge clk);
    end

    lsu_response = (delay_cycles != 0);
    ready_wb = 1'b1;
    for (int cycle = 0; cycle < 8; cycle++) begin
      #1ns;
      if (pc_set && pc_mux == PC_JUMP) begin
        if (alu_operator != ALU_ADD || alu_a != BranchPc ||
            (alu_a + alu_b) != expected_target)
          $fatal(1, "Branch redirected before target calculation: a=%h b=%h", alu_a, alu_b);
        redirects++;
      end
      retired = instr_done;
      @(posedge clk);
      @(negedge clk);
      lsu_response = 1'b0;
      outstanding_load = 1'b0;
      outstanding_store = 1'b0;
      if (retired) break;
    end
    if (!retired || redirects != int'(taken || FixedTime))
      $fatal(1, "Branch completion mismatch: retired=%0b redirects=%0d", retired, redirects);

    instr_valid = 1'b0;
    instr = 32'h0000_0013;
    repeat (2) begin
      #1ns;
      if (pc_set && pc_mux == PC_JUMP) $fatal(1, "Repeated branch redirect after retirement");
      @(posedge clk);
      @(negedge clk);
    end
  endtask

  initial begin
    done_o = 1'b0;
    repeat (2) @(negedge clk);
    rst_n = 1'b1;
    repeat (4) @(negedge clk);

    run_branch(1'b1, 16);
    run_branch(1'b1, 1);
    run_branch(1'b0, 16);
    run_branch(1'b1, 8, 1'b1);
    run_branch(1'b0, 8, 1'b1);
    run_branch(1'b1, 0);
    run_branch(1'b0, 0);
    repeat (3) run_branch(1'b1, 2);

    $display("Branch-stall cases passed: CHERIoT=%0b, fixed-time=%0b", CheriotMode, FixedTime);
    done_o = 1'b1;
  end
endmodule

module tb_ibex_branch_stall;
  timeunit 1ns;
  timeprecision 1ps;
  logic [3:0] done;

  for (genvar i = 0; i < 4; i++) begin : gen_cases
    ibex_branch_stall_case #(
      .CheriotMode((i & 1) != 0),
      .FixedTime((i & 2) != 0)
    ) i_case (.done_o(done[i]));
  end

  initial begin
    wait (&done);
    $display("Ibex branch-stall regression: PASS");
    $finish;
  end

  initial begin
    #100us;
    $fatal(1, "Branch-stall regression timed out");
  end
endmodule
