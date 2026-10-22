// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Authors:
// - Philippe Sauter <phsauter@iis.ee.ethz.ch>
// - Enrico Zelioli <ezelioli@iis.ee.ethz.ch>

`define TRACE_WAVE

module tb_croc_soc #(
  parameter int unsigned GpioCount = 32
);

  import tb_croc_pkg::*;

  // Signals fully controlled by the VIP
  // use VIP functions/tasks to manipulate these signals
  logic rst_n;
  logic sys_clk;
  logic ref_clk;

  logic jtag_tck;
  logic jtag_trst_n;
  logic jtag_tms;
  logic jtag_tdi;
  logic jtag_tdo;

  logic uart_rx;
  logic uart_tx;

  // Signals partially controlled by the VIP
  logic [GpioCount-1:0] gpio_in;
  logic [GpioCount-1:0] gpio_out;
  logic [GpioCount-1:0] gpio_out_en;

  // Signals controlled by the testbench

  /////////////////////////////
  //  Command Line Arguments //
  /////////////////////////////

  string binary_path;

  initial begin
    // $value$plusargs defines what to look for (here +binary=...)
    if ($value$plusargs("binary=%s", binary_path)) begin
      $display("Running program: %s", binary_path);
    end else begin
      $display("No binary path provided. Running helloworld.");
      binary_path = "../sw/bin/helloworld.hex";
    end
  end

  ////////////
  //  VIP   //
  ////////////
  // Verification IP
  // - drives clocks and resets
  // - provides helper tasks and functions for JTAG, namely:
  //   - jtag_load_hex: loads a hex file into the DUT's memory
  //   - jtag_write_reg32: write 32-bit value to DUT
  //   - jtag_read_reg32: read 32-bit value from DUT
  //   - jtag_halt / jtag_resume: control core execution
  //   - jtag_wait_for_eoc: wait for end of code execution (core writes non-zero to status register)
  // - prints UART output to console (you can also write via uart_write_byte)
  // - internal GPIO loopback for helloworld test


  croc_vip #(
    .GpioCount ( GpioCount )
  ) i_vip (
    .rst_no        ( rst_n       ),
    .sys_clk_o     ( sys_clk     ),
    .ref_clk_o     ( ref_clk     ),
    .jtag_tck_o    ( jtag_tck    ),
    .jtag_trst_no  ( jtag_trst_n ),
    .jtag_tms_o    ( jtag_tms    ),
    .jtag_tdi_o    ( jtag_tdi    ),
    .jtag_tdo_i    ( jtag_tdo    ),
    .uart_rx_o     ( uart_rx     ),
    .uart_tx_i     ( uart_tx     ),
    .gpio_out_en_i ( gpio_out_en ),
    .gpio_out_i    ( gpio_out    ),
    .gpio_in_o     ( gpio_in     )
  );

  ////////////
  //  DUT   //
  ////////////

  `ifdef TARGET_NETLIST_YOSYS
  \croc_soc$croc_chip.i_croc_soc i_croc_soc (
  `else
  croc_soc #(
    .GpioCount ( GpioCount )
  ) i_croc_soc (
  `endif
    .clk_i                  ( sys_clk     ),
    .rst_ni                 ( rst_n       ),
    .ref_clk_i              ( ref_clk     ),
    .testmode_i             ( 1'b0        ),
    .status_o               (             ),
    .jtag_tck_i             ( jtag_tck    ),
    .jtag_tdi_i             ( jtag_tdi    ),
    .jtag_tdo_o             ( jtag_tdo    ),
    .jtag_tms_i             ( jtag_tms    ),
    .jtag_trst_ni           ( jtag_trst_n ),
    .uart_rx_i              ( uart_rx     ),
    .uart_tx_o              ( uart_tx     ),
    .gpio_i                 ( gpio_in     ),
    .gpio_o                 ( gpio_out    ),
    .gpio_out_en_o          ( gpio_out_en ),
    .hyper_cs_no            ( hyper_cs_n_wire    ),
    .hyper_ck_o             ( hyper_ck_wire      ),
    .hyper_ck_no            ( hyper_ck_n_wire    ),
    .hyper_rwds_o           ( hyper_rwds_o       ),
    .hyper_rwds_i           ( hyper_rwds_i       ),
    .hyper_rwds_oe_o        ( hyper_rwds_oe      ),
    .hyper_dq_i             ( hyper_dq_i         ),
    .hyper_dq_o             ( hyper_dq_o         ),
    .hyper_dq_oe_o          ( hyper_dq_oe        ),
    .hyper_reset_no         ( hyper_reset_n_wire )
  );

  /////////////////
  // Hyper-Dram  //
  /////////////////

  // from rtl/vendor/hyperbus/test/fixture_hyperbus.sv

  localparam int unsigned NumPhys = 2; // 2 groups each has its own crtl signals
  localparam int unsigned NumConnectedChips = 1; // one hyperam module per group

  logic [NumPhys-1:0][hyperbus_pkg::HyperNumChips-1:0] hyper_cs_n_wire;
  logic [NumPhys-1:0]               hyper_ck_wire;
  logic [NumPhys-1:0]               hyper_ck_n_wire;
  logic [NumPhys-1:0]               hyper_rwds_o;
  logic [NumPhys-1:0]               hyper_rwds_i;
  logic [NumPhys-1:0]               hyper_rwds_oe;
  logic [NumPhys-1:0][7:0]          hyper_dq_i;
  logic [NumPhys-1:0][7:0]          hyper_dq_o;
  logic [NumPhys-1:0]               hyper_dq_oe;
  logic [NumPhys-1:0]               hyper_reset_n_wire;
            
  wire  [NumPhys-1:0][NumConnectedChips-1:0] pad_hyper_csn;
  wire  [NumPhys-1:0]                pad_hyper_ck;
  wire  [NumPhys-1:0]                pad_hyper_ckn;
  wire  [NumPhys-1:0]                pad_hyper_rwds;
  wire  [NumPhys-1:0]                pad_hyper_reset;
  wire  [NumPhys-1:0][7:0]           pad_hyper_dq;

 
  generate
       for (genvar i=0; i<NumPhys; i++) begin : hyperrams
          for (genvar j=0; j<NumConnectedChips; j++) begin : chips

             s27ks0641 #(
               /*.mem_file_name ( "s27ks0641.mem"    ),*/
               .TimingModel   ( "S27KS0641DPBHI020"    )
             ) dut (
               .DQ7           ( pad_hyper_dq[i][7]  ),
               .DQ6           ( pad_hyper_dq[i][6]  ),
               .DQ5           ( pad_hyper_dq[i][5]  ),
               .DQ4           ( pad_hyper_dq[i][4]  ),
               .DQ3           ( pad_hyper_dq[i][3]  ),
               .DQ2           ( pad_hyper_dq[i][2]  ),
               .DQ1           ( pad_hyper_dq[i][1]  ),
               .DQ0           ( pad_hyper_dq[i][0]  ),
               .RWDS          ( pad_hyper_rwds[i]   ),
               .CSNeg         ( pad_hyper_csn[i][0] /*j instead of 0 prob better*/ ),
               .CK            ( pad_hyper_ck[i]     ),
               .CKNeg         ( pad_hyper_ckn[i]    ),
               .RESETNeg      ( pad_hyper_reset[i]  )
             );
          end // block: chips
       end // block: hyperrams
  endgenerate


  for (genvar i = 0 ; i<NumPhys; i++) begin: pad_gen
    for (genvar j = 0; j<NumConnectedChips; j++) begin
       pad_functional_pd padinst_hyper_csno   (.OEN( 1'b0            ), .I( hyper_cs_n_wire[i][j] ), .O(                  ), .PAD( pad_hyper_csn[i][j] ), .PEN( 1'b0 ));
    end
    pad_functional_pd padinst_hyper_ck     (.OEN( 1'b0            ), .I( hyper_ck_wire[i]      ), .O(                  ), .PAD( pad_hyper_ck[i]     ), .PEN( 1'b0 ) );
    pad_functional_pd padinst_hyper_ckno   (.OEN( 1'b0            ), .I( hyper_ck_n_wire[i]    ), .O(                  ), .PAD( pad_hyper_ckn[i]    ), .PEN( 1'b0 ) );
    pad_functional_pd padinst_hyper_rwds   (.OEN(~hyper_rwds_oe[i]), .I( hyper_rwds_o[i]       ), .O( hyper_rwds_i[i]  ), .PAD( pad_hyper_rwds[i]   ), .PEN( 1'b0 ) );
    pad_functional_pd padinst_hyper_resetn (.OEN( 1'b0            ), .I( hyper_reset_n_wire[i] ), .O(                  ), .PAD( pad_hyper_reset[i]  ), .PEN( 1'b0 ) );
    pad_functional_pd padinst_hyper_dqio0  (.OEN(~hyper_dq_oe[i]  ), .I( hyper_dq_o[i][0]      ), .O( hyper_dq_i[i][0] ), .PAD( pad_hyper_dq[i][0]  ), .PEN( 1'b0 ) );
    pad_functional_pd padinst_hyper_dqio1  (.OEN(~hyper_dq_oe[i]  ), .I( hyper_dq_o[i][1]      ), .O( hyper_dq_i[i][1] ), .PAD( pad_hyper_dq[i][1]  ), .PEN( 1'b0 ) );
    pad_functional_pd padinst_hyper_dqio2  (.OEN(~hyper_dq_oe[i]  ), .I( hyper_dq_o[i][2]      ), .O( hyper_dq_i[i][2] ), .PAD( pad_hyper_dq[i][2]  ), .PEN( 1'b0 ) );
    pad_functional_pd padinst_hyper_dqio3  (.OEN(~hyper_dq_oe[i]  ), .I( hyper_dq_o[i][3]      ), .O( hyper_dq_i[i][3] ), .PAD( pad_hyper_dq[i][3]  ), .PEN( 1'b0 ) );
    pad_functional_pd padinst_hyper_dqio4  (.OEN(~hyper_dq_oe[i]  ), .I( hyper_dq_o[i][4]      ), .O( hyper_dq_i[i][4] ), .PAD( pad_hyper_dq[i][4]  ), .PEN( 1'b0 ) );
    pad_functional_pd padinst_hyper_dqio5  (.OEN(~hyper_dq_oe[i]  ), .I( hyper_dq_o[i][5]      ), .O( hyper_dq_i[i][5] ), .PAD( pad_hyper_dq[i][5]  ), .PEN( 1'b0 ) );
    pad_functional_pd padinst_hyper_dqio6  (.OEN(~hyper_dq_oe[i]  ), .I( hyper_dq_o[i][6]      ), .O( hyper_dq_i[i][6] ), .PAD( pad_hyper_dq[i][6]  ), .PEN( 1'b0 ) );
    pad_functional_pd padinst_hyper_dqio7  (.OEN(~hyper_dq_oe[i]  ), .I( hyper_dq_o[i][7]      ), .O( hyper_dq_i[i][7] ), .PAD( pad_hyper_dq[i][7]  ), .PEN( 1'b0 ) );
  end

  /////////////////
  //  Testbench  //
  /////////////////

  logic [31:0] tb_data;

  initial begin
    $timeformat(-9, 0, "ns", 12); // 1: scale (ns=-9), 2: decimals, 3: suffix, 4: print-field width

    // wait for reset
    #ClkPeriodSys;

    #1us;
    if ($isunknown(jtag_tdo)) begin
      $fatal(1, "[JTAG] Output is unknown (X) after reset");
    end

    // init jtag
    i_vip.jtag_init();

    // write test value to sram
    i_vip.jtag_write_reg32(SramBaseAddr, 32'h1234_5678, 1'b1);

    // load binary to sram
    i_vip.jtag_load_hex(binary_path);

    // wake core from WFI by writing to CLINT msip
    $display("@%t | [CORE] Waking core via CLINT msip", $time);
    i_vip.jtag_write_reg32(ClintBaseAddr, 32'h1);

    // Let the application finish its early startup before halting the hart. In
    // CHERIoT programs this includes capability-based stack setup; halting in
    // the middle of that sequence can resume after a capability instruction
    // without its writeback having retired.
    repeat (600) @(posedge sys_clk);

    // halt core
    // i_vip.jtag_halt();

    // // resume core
    // i_vip.jtag_resume();

    // wait for non-zero return value (written into core status register)
    $display("@%t | [CORE] Wait for end of code...", $time);
    i_vip.jtag_wait_for_eoc(tb_data);

    // finish simulation
    repeat(50) @(posedge sys_clk);
    $finish();
  end

  ////////////////
  //  Waveform  //
  ////////////////
  // start waveform dump at time 0, independent of stimuli
  initial begin
    `ifdef TRACE_WAVE
      `ifdef VERILATOR
        $dumpfile("croc.fst");
        $dumpvars(0, i_croc_soc);
      `else
        $dumpfile("croc.vcd");
        $dumpvars(1, i_croc_soc);
      `endif
    `endif
  end

  // flush waveform dump when simulation ends
  final begin
    `ifdef TRACE_WAVE
      $dumpflush;
    `endif
  end

endmodule
