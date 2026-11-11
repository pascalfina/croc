// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Authors:
// - Philippe Sauter <phsauter@iis.ee.ethz.ch>
//
// This module wraps the processor core and adapts it to the Croc SoC interface.
// The default core is CVE2 (https://github.com/openhwgroup/cve2).
// For other cores, modify the internal instantiation and the port connections as needed.
//
// Replacing the core:
// The SoC provides two separate OBI master ports (instruction fetch and data access).
// Cores with a single shared memory bus can tie off one of the two and only use the other.
//
// Key interface signals to adapt for other cores:
//   fetch_enable_i - Allows the SoC to gate instruction fetch (e.g. hold core until 
//                    software is loaded). Cores without this signal should ignore it.
//   core_busy_o    - Activity hint; drive 1'b0 if the core does not expose it.
//   irqs_i [15:0]  - Fast interrupts (RISC-V IRQ 16..31). Mapping to a core's interrupt
//                    input depends on the core:
//                      CVE2/Ibex: irq_fast_i[15:0] directly
//                      cv32e40p:  irq_i[31:16]
//                    timer_irq_i and software_irq_i correspond to the standard RISC-V
//                    CLINT timer (IRQ 7) and software (IRQ 3) interrupts.
//   debug_req_i    - Debug module request. Cores without a debug interface should leave
//                    this unconnected and remove the debug module from the address map.
//                    Attention! Think carefully how it will be programmed and started.
//                    CVE2 receives the debug halt/exception addresses as runtime inputs
//                    (dm_halt_addr_i / dm_exception_addr_i). Some cores hardcode these
//                    addresses instead; in that case adjust PeriphDebug's start_addr in
//                    croc_pkg.sv so the debug module ROM base matches what the core
//                    expects to jump to on halt.
// CV-X-IF co-processors: CVE2 supports instruction offloading via the Core-V Extension Interface. 
//   If you want to attach a custom accelerator using CV-X-IF,
//   instantiate it directly inside this wrapper (enable XInterface and connect x_* ports here).
//   Do not route CV-X-IF through the SoC hierarchy; the types are CVE2-specific and the tight
//   coupling belongs at the core boundary, not in user_domain.

module core_wrap
  import croc_pkg::*;
#(
) (
    input logic clk_i,
    input logic rst_ni,
    input logic test_enable_i,

    // Interrupts
    // irqs_i maps to RISC-V fast interrupts (IRQ 16..31); see header comment for remapping
    input logic [15:0] irqs_i,
    input logic timer_irq_i,
    input logic software_irq_i,

    input logic [31:0] boot_addr_i,

    // Instruction memory interface (OBI)
    output logic        instr_req_o,
    input  logic        instr_gnt_i,
    input  logic        instr_rvalid_i,
    output logic [31:0] instr_addr_o,
    input  logic [31:0] instr_rdata_i,
    input  logic [ 6:0] instr_rdata_intg_i,
    input  logic        instr_err_i,

    // Data memory interface (OBI)
    output logic        data_req_o,
    input  logic        data_gnt_i,
    input  logic        data_rvalid_i,
    output logic        data_we_o,
    output logic [ 3:0] data_be_o,
    output logic [31:0] data_addr_o,
    output logic [31:0] data_wdata_o,
    output logic [ 6:0] data_wdata_intg_o,
    input  logic [31:0] data_rdata_i,
    input  logic [ 6:0] data_rdata_intg_i,
    input  logic        data_err_i,

    // Debug Interface
    input logic debug_req_i,

    // CPU Control Signals
    // fetch_enable_i: gates instruction fetch; ignore if core has no such signal
    input logic fetch_enable_i,
    input logic cheriot_enable_i,

    // core_busy_o: power-management hint to the SoC; drive 1'b0 if not available
    output logic core_busy_o,

    output logic data_tag_o,
    output logic data_is_cap_access_o,
    input  logic data_tag_i,

    output logic        trvk_revbm_req_o,
    input  logic        trvk_revbm_gnt_i,
    input  logic        trvk_revbm_rvalid_i,
    output logic [31:0] trvk_revbm_addr_o,
    input  logic [31:0] trvk_revbm_rdata_i,
    input  logic [ 6:0] trvk_revbm_rdata_intg_i,
    input  logic        trvk_revbm_err_i

);

  // CVE2: debug halt/exception vectors are provided as runtime inputs.
  // Cores that hardcode these addresses internally do not need these params.
  // Remove the localparams and connections below when replacing with such a core.
  // Make sure to check PeriphDebug's start_addr in croc_pkg and adjust if necesary.
  localparam bit [31:0] DebugAddrOffset = get_periph_start_addr(PeriphDebug);
  localparam bit [31:0] DebugHaltAddress = DebugAddrOffset + dm::HaltAddress[31:0];
  localparam bit [31:0] DebugExceptionAddress = DebugAddrOffset + dm::ExceptionAddress[31:0];

  logic core_sleep;
  // Only observed by the simulation integrity monitor at the end of this module.
  ibex_pkg::crash_dump_t crash_dump;
  logic alert_minor, alert_major_internal, alert_major_bus;
  // logic trvk_revbm_req;
  // logic trvk_revbm_rvalid_q;

  assign core_busy_o = ~core_sleep;

  // // Tag-storage bring-up: every bitmap lookup returns "not revoked" after one cycle.
  // always_ff @(posedge clk_i or negedge rst_ni) begin
  //   if (!rst_ni) begin
  //     trvk_revbm_rvalid_q <= 1'b0;
  //   end else begin
  //     trvk_revbm_rvalid_q <= trvk_revbm_req;
  //   end
  // end

  // Match the 64 KiB heap after the RTOS image in sdk/boards/croc.json.
  localparam logic [31:0] HeapBaseAddr = get_croc_start_addr(XbarHyperbus) + 32'h0001_0000;
  localparam logic [31:0] RevBitmapBaseAddr = 32'h1002_0000;
  // A 1 KiB bitmap covers the 64 KiB heap at one revocation bit per 8 bytes.
  localparam int unsigned RevBitmapAddrWidth = 10;

  /// ibex integration 

  ibex_top #(
      .BaseIsa                  (ibex_pkg::BaseIsaRV32IorCHERIoT),
      .CheriotRevBitmapAddrWidth(RevBitmapAddrWidth),
      .CheriotRevBitmapBaseAddr (RevBitmapBaseAddr),
      .PMPEnable                (1'b0),
      .PMPGranularity           (0),
      .PMPNumRegions            (4),
      .MHPMCounterNum           (0),
      .MHPMCounterWidth         (40),
      .RV32E                    (1'b0),
      .RV32M                    (ibex_pkg::RV32MFast),
      .RV32B                    (ibex_pkg::RV32BNone),
      .RV32ZC                   (ibex_pkg::RV32Zca),
      .RegFile                  (ibex_pkg::RegFileFF),
      .BranchTargetALU          (1'b0),
      .WritebackStage           (1'b1),
      .ICache                   (1'b0),
      .ICacheECC                (1'b0),
      .BranchPredictor          (1'b0),
      .DbgTriggerEn             (1'b1),
      .DbgHwBreakNum            (1),
      .SecureIbex               (1'b0),
      .MemECC                   (1'b1), // enabled ecc

      .DmBaseAddr     (DebugAddrOffset),
      .DmAddrMask     (32'h0003_FFFF),
      .DmHaltAddr     (DebugHaltAddress),
      .DmExceptionAddr(DebugExceptionAddress)
  ) i_core (

      .clk_i (clk_i),
      .rst_ni(rst_ni),

      .test_en_i(test_enable_i | ~rst_ni),
      .scan_rst_ni(1'b1),
      .ram_cfg_icache_tag_i('{default: prim_ram_1p_pkg::RAM_1P_CFG_REQ_DEFAULT}),
      .ram_cfg_icache_tag_o(),
      .ram_cfg_icache_data_i('{default: prim_ram_1p_pkg::RAM_1P_CFG_REQ_DEFAULT}),
      .ram_cfg_icache_data_o(),

      .cheriot_enable_i(cheriot_enable_i ? ibex_pkg::IbexMuBiOn : ibex_pkg::IbexMuBiOff),
      .hart_id_i(32'd0 ),
      .boot_addr_i(boot_addr_i   ),

      .instr_req_o(instr_req_o),
      .instr_gnt_i(instr_gnt_i),
      .instr_rvalid_i(instr_rvalid_i),
      .instr_addr_o(instr_addr_o),
      .instr_rdata_i(instr_rdata_i),
      .instr_rdata_intg_i(instr_rdata_intg_i),
      .instr_err_i(instr_err_i),

      .data_req_o(data_req_o),
      .data_gnt_i(data_gnt_i),
      .data_rvalid_i(data_rvalid_i),
      .data_we_o(data_we_o),
      .data_be_o(data_be_o),
      .data_addr_o(data_addr_o),
      .data_wdata_o(data_wdata_o),
      .data_wdata_intg_o(data_wdata_intg_o),
      .data_tag_o(data_tag_o),
      .data_is_cap_access_o(data_is_cap_access_o),
      .data_rdata_i(data_rdata_i),
      .data_rdata_intg_i(data_rdata_intg_i),
      .data_tag_i(data_tag_i),
      .data_err_i(data_err_i),

      .trvk_heap_base_addr_i  (HeapBaseAddr),
      .trvk_revbm_req_o       (trvk_revbm_req_o),
      .trvk_revbm_gnt_i       (trvk_revbm_gnt_i),
      .trvk_revbm_rvalid_i    (trvk_revbm_rvalid_i),
      .trvk_revbm_addr_o      (trvk_revbm_addr_o),
      .trvk_revbm_rdata_i     (trvk_revbm_rdata_i),
      .trvk_revbm_rdata_intg_i(trvk_revbm_rdata_intg_i),
      .trvk_revbm_err_i       (trvk_revbm_err_i),

      .irq_software_i(software_irq_i),
      .irq_timer_i(timer_irq_i),
      .irq_external_i(1'b0),
      .irq_fast_i(irqs_i[14:0]),
      .irq_nm_i(1'b0),

      .scramble_key_valid_i(1'b0),
      .scramble_key_i      ('0),
      .scramble_nonce_i    ('0),
      .scramble_req_o      (),

      .debug_req_i        (debug_req_i),
      .crash_dump_o       (crash_dump),
      .double_fault_seen_o(),

      .fetch_enable_i        (fetch_enable_i ? ibex_pkg::IbexMuBiOn : ibex_pkg::IbexMuBiOff),
      .mcounteren_writable_i (ibex_pkg::IbexMuBiOn),
      .alert_minor_o         (alert_minor),
      .alert_major_internal_o(alert_major_internal),
      .alert_major_bus_o     (alert_major_bus),
      .core_sleep_o          (core_sleep),

      .lockstep_cmp_en_o(),

      .data_req_shadow_o(),
      .data_we_shadow_o(),
      .data_be_shadow_o(),
      .data_addr_shadow_o(),
      .data_wdata_shadow_o(),
      .data_wdata_intg_shadow_o(),

      .instr_req_shadow_o (),
      .instr_addr_shadow_o()
  );

`ifndef SYNTHESIS
  // pragma translate_off

  // Simulation-only memory-integrity monitor. Ibex's own ECC assertions use the prim_assert
  // macros, which are dummies under Verilator, so every bus codeword is decoded here with the
  // shared codec. Each report is followed by $fatal; run with +ecc_nofatal to only report.

  typedef struct packed {
    logic [31:0] addr;
    logic        we;
    logic [3:0]  be;
    logic        cap;
  } ecc_mon_data_req_t;

  ecc_mon_data_req_t ecc_mon_data_q[$];
  logic [31:0]       ecc_mon_instr_q[$];
  logic [31:0]       ecc_mon_trvk_q[$];

  bit          ecc_mon_fatal;
  int unsigned ecc_mon_errors, ecc_mon_instr_cnt, ecc_mon_data_cnt, ecc_mon_trvk_cnt;

  initial begin
    ecc_mon_fatal     = !$test$plusargs("ecc_nofatal");
    ecc_mon_errors    = 0;
    ecc_mon_instr_cnt = 0;
    ecc_mon_data_cnt  = 0;
    ecc_mon_trvk_cnt  = 0;
  end

  function automatic string ecc_mon_kind(input ibex_mem_ecc_pkg::mem_ecc_dec_t dec);
    if (dec.syndrome == ibex_mem_ecc_pkg::MemEccTagSyndrome)
      return "single-bit error on the TAG column (stored tag and ECC disagree)";
    return dec.err[1] ? "double-bit error" : "single-bit error";
  endfunction

  always @(posedge clk_i or negedge rst_ni) begin : ecc_monitor
    ibex_mem_ecc_pkg::mem_ecc_dec_t dec;
    ecc_mon_data_req_t              data_req;
    logic [31:0]                    addr;
    logic [39:0]                    expected;
    bit                             failed;

    if (!rst_ni) begin
      ecc_mon_data_q.delete();
      ecc_mon_instr_q.delete();
      ecc_mon_trvk_q.delete();
    end else begin
      failed = 1'b0;

      // OBI responses are in order: each one completes the oldest accepted request.
      if (instr_rvalid_i) begin
        ecc_mon_instr_cnt++;
        addr = '1;
        if (ecc_mon_instr_q.size() == 0) begin
          $error("@%t | [ECC-MON] Instruction response without an outstanding request", $time);
          failed = 1'b1;
        end else begin
          addr = ecc_mon_instr_q.pop_front();
        end
        // Instruction responses carry data-only ECC (tag zero), see instruction_cache.sv.
        dec = ibex_mem_ecc_pkg::mem_ecc_decode({instr_rdata_intg_i, 1'b0, instr_rdata_i});
        if (dec.err != 2'b00) begin
          $error({"@%t | [ECC-MON] Instruction fetch %s: addr=0x%08h rdata=0x%08h ecc=0x%02h ",
                  "syndrome=0x%02h bus_err=%0b pc_id=0x%08h cheriot=%0b"},
                 $time, ecc_mon_kind(dec), addr, instr_rdata_i, instr_rdata_intg_i,
                 dec.syndrome, instr_err_i, crash_dump.current_pc, cheriot_enable_i);
          failed = 1'b1;
        end
      end

      if (data_rvalid_i) begin
        ecc_mon_data_cnt++;
        data_req = '1;
        if (ecc_mon_data_q.size() == 0) begin
          $error("@%t | [ECC-MON] Data response without an outstanding request", $time);
          failed = 1'b1;
        end else begin
          data_req = ecc_mon_data_q.pop_front();
        end
        // Bus-side codeword: ECC covers the 32 data bits plus the returned capability tag.
        dec = ibex_mem_ecc_pkg::mem_ecc_decode({data_rdata_intg_i, data_tag_i, data_rdata_i});
        if (dec.err != 2'b00) begin
          $error({"@%t | [ECC-MON] Data %s response %s: addr=0x%08h be=0b%04b cap_access=%0b ",
                  "rdata=0x%08h tag=%0b ecc=0x%02h syndrome=0x%02h bus_err=%0b ",
                  "pc_id=0x%08h last_data_addr=0x%08h cheriot=%0b"},
                 $time, data_req.we ? "store" : "load", ecc_mon_kind(dec), data_req.addr,
                 data_req.be, data_req.cap, data_rdata_i, data_tag_i, data_rdata_intg_i,
                 dec.syndrome, data_err_i, crash_dump.current_pc, crash_dump.last_data_addr,
                 cheriot_enable_i);
          failed = 1'b1;
        end
      end

      if (trvk_revbm_rvalid_i) begin
        ecc_mon_trvk_cnt++;
        addr = '1;
        if (ecc_mon_trvk_q.size() == 0) begin
          $error("@%t | [ECC-MON] Revocation-bitmap response without an outstanding request",
                 $time);
          failed = 1'b1;
        end else begin
          addr = ecc_mon_trvk_q.pop_front();
        end
        dec = ibex_mem_ecc_pkg::mem_ecc_decode({trvk_revbm_rdata_intg_i, 1'b0,
                                                trvk_revbm_rdata_i});
        if (dec.err != 2'b00) begin
          $error({"@%t | [ECC-MON] Revocation-bitmap %s: addr=0x%08h rdata=0x%08h ecc=0x%02h ",
                  "syndrome=0x%02h bus_err=%0b pc_id=0x%08h"},
                 $time, ecc_mon_kind(dec), addr, trvk_revbm_rdata_i, trvk_revbm_rdata_intg_i,
                 dec.syndrome, trvk_revbm_err_i, crash_dump.current_pc);
          failed = 1'b1;
        end
      end

      // Record accepted requests after the responses of this cycle have been matched.
      if (instr_req_o && instr_gnt_i) begin
        ecc_mon_instr_q.push_back(instr_addr_o);
      end

      if (data_req_o && data_gnt_i) begin
        ecc_mon_data_q.push_back('{addr: data_addr_o, we: data_we_o, be: data_be_o,
                                   cap: data_is_cap_access_o});
        // The core's own write encoding must match the shared codec.
        if (data_we_o) begin
          expected = ibex_mem_ecc_pkg::mem_ecc_encode(data_wdata_o, data_tag_o);
          if (data_wdata_intg_o != expected[39:33]) begin
            $error({"@%t | [ECC-MON] Core write ECC mismatch: addr=0x%08h be=0b%04b ",
                    "wdata=0x%08h tag=%0b ecc=0x%02h expected=0x%02h pc_id=0x%08h"},
                   $time, data_addr_o, data_be_o, data_wdata_o, data_tag_o,
                   data_wdata_intg_o, expected[39:33], crash_dump.current_pc);
            failed = 1'b1;
          end
        end
      end

      if (trvk_revbm_req_o && trvk_revbm_gnt_i) begin
        ecc_mon_trvk_q.push_back(trvk_revbm_addr_o);
      end

      // Ibex's own detection, independent of the checks above.
      if (alert_major_bus) begin
        $error({"@%t | [ECC-MON] Ibex alert_major_bus (core detected a bus integrity error): ",
                "pc_id=0x%08h last_data_addr=0x%08h exception_pc=0x%08h exception_addr=0x%08h"},
               $time, crash_dump.current_pc, crash_dump.last_data_addr,
               crash_dump.exception_pc, crash_dump.exception_addr);
        failed = 1'b1;
      end
      if (alert_major_internal) begin
        $error("@%t | [ECC-MON] Ibex alert_major_internal: pc_id=0x%08h", $time,
               crash_dump.current_pc);
        failed = 1'b1;
      end
      if (alert_minor) begin
        $warning("@%t | [ECC-MON] Ibex alert_minor: pc_id=0x%08h", $time,
                 crash_dump.current_pc);
      end

      if (failed) begin
        ecc_mon_errors++;
        if (ecc_mon_fatal) begin
          $fatal(1, "@%t | [ECC-MON] Stopping after integrity error (+ecc_nofatal to continue)",
                 $time);
        end
      end
    end
  end

  final begin
    $display("[ECC-MON] Checked %0d instruction, %0d data and %0d bitmap responses: %0d errors",
             ecc_mon_instr_cnt, ecc_mon_data_cnt, ecc_mon_trvk_cnt, ecc_mon_errors);
  end

  // pragma translate_on
`endif

endmodule
