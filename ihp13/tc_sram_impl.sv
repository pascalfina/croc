// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Authors:
// - Thomas Benz <tbenz@iis.ee.ethz.ch>
// - Tobias Senti <tsenti@student.ethz.ch>
// - Paul Scheffler <paulsc@iis.ee.ethz.ch>

module tc_sram_blackbox #(
  parameter int unsigned NumWords     = 32'd0,
  parameter int unsigned DataWidth    = 32'd0,
  parameter int unsigned ByteWidth    = 32'd0,
  parameter int unsigned NumPorts     = 32'd0,
  parameter int unsigned Latency      = 32'd0,
  parameter              SimInit      = "none",
  parameter bit          PrintSimCfg  = 1'b0,
  parameter              ImplKey      = "none"
) ();
endmodule

`define TC_SRAM_IHP13_CUT(cut) \
  cut i_cut ( \
    .A_CLK       ( clk_i   ), \
    .A_DLY       ( dly_i   ), \
    .A_ADDR      ( addr_i  ), \
    .A_BM        ( bm_i    ), \
    .A_MEN       ( req_i   ), \
    .A_WEN       ( we_i    ), \
    .A_REN       ( ~we_i   ), \
    .A_DIN       ( wdata_i ), \
    .A_DOUT      ( rdata_o ), \
    .A_BIST_CLK  ( 1'b0    ), \
    .A_BIST_ADDR ( '0      ), \
    .A_BIST_DIN  ( '0      ), \
    .A_BIST_BM   ( '0      ), \
    .A_BIST_MEN  ( 1'b0    ), \
    .A_BIST_WEN  ( 1'b0    ), \
    .A_BIST_REN  ( 1'b0    ), \
    .A_BIST_EN   ( 1'b0    )  \
  );

module tc_sram_ihp13_macro #(
  parameter int unsigned Width     = 32'd64,
  parameter int unsigned Words     = 32'd64,
  // DEPENDENT PARAMETERS, DO NOT OVERWRITE!
  parameter int unsigned AddrWidth = $clog2(Words)
) (
  input  logic                 clk_i,
  input  logic                 dly_i,
  input  logic                 req_i,
  input  logic                 we_i,
  input  logic [AddrWidth-1:0] addr_i,
  input  logic [Width-1:0]     wdata_i,
  input  logic [Width-1:0]     bm_i,
  output logic [Width-1:0]     rdata_o
);

  if      (Width == 64 && Words ==   64) begin : gen_64x64   `TC_SRAM_IHP13_CUT(RM_IHPSG13_1P_64x64_c2_bm_bist)   end
  else if (Width == 64 && Words ==  256) begin : gen_256x64  `TC_SRAM_IHP13_CUT(RM_IHPSG13_1P_256x64_c2_bm_bist)  end
  else if (Width == 64 && Words ==  512) begin : gen_512x64  `TC_SRAM_IHP13_CUT(RM_IHPSG13_1P_512x64_c2_bm_bist)  end
  else if (Width == 64 && Words == 1024) begin : gen_1024x64 `TC_SRAM_IHP13_CUT(RM_IHPSG13_1P_1024x64_c2_bm_bist) end
  else if (Width == 64 && Words == 2048) begin : gen_2048x64 `TC_SRAM_IHP13_CUT(RM_IHPSG13_1P_2048x64_c2_bm_bist) end
  else if (Width == 48 && Words ==  256) begin : gen_256x48  `TC_SRAM_IHP13_CUT(RM_IHPSG13_1P_256x48_c2_bm_bist)  end
  else if (Width == 32 && Words ==  512) begin : gen_512x32  `TC_SRAM_IHP13_CUT(RM_IHPSG13_1P_512x32_c2_bm_bist)  end
  else begin : gen_invalid
    $error("tc_sram_ihp13_macro: no IHP macro with %0d words of %0d bits", Words, Width);
  end

endmodule

`undef TC_SRAM_IHP13_CUT

module tc_sram_ihp13_column #(
  parameter int unsigned Records   = 32'd256,
  parameter int unsigned Bits      = 32'd64,
  parameter int unsigned Pack      = 32'd1,
  // DEPENDENT PARAMETERS, DO NOT OVERWRITE!
  parameter int unsigned AddrWidth = $clog2(Records)
) (
  input  logic                 clk_i,
  input  logic                 rst_ni,
  input  logic                 dly_i,
  input  logic                 req_i,
  input  logic                 we_i,
  input  logic [AddrWidth-1:0] addr_i,
  input  logic [Bits-1:0]      wdata_i,
  input  logic [Bits-1:0]      bm_i,
  output logic [Bits-1:0]      rdata_o
);

  import tc_sram_ihp13_pkg::*;

  localparam int unsigned Width     = Bits * Pack;
  localparam int unsigned Words     = Records / Pack;
  localparam int unsigned NumTiles  = num_tiles(Width, Words);
  localparam int unsigned SlotWidth = (Pack > 1) ? $clog2(Pack) : 1;
  localparam int unsigned TileWidth = (NumTiles > 1) ? $clog2(NumTiles) : 1;

  logic [SlotWidth-1:0] slot, slot_q;
  logic [TileWidth-1:0] tile, tile_q;
  logic [NumTiles-1:0]  tile_hit;
  logic [AddrWidth-1:0] word;
  logic [Width-1:0]     macro_wdata, macro_bm;
  logic [Width-1:0]     macro_rdata [NumTiles];

  always_comb begin
    slot = '0;
    for (int unsigned s = 1; s < Pack; s++) begin
      if (addr_i >= s * Words) slot = SlotWidth'(s);
    end
  end

  always_comb begin
    tile = '0;
    for (int unsigned t = 1; t < NumTiles; t++) begin
      if (tile_hit[t]) tile = TileWidth'(t);
    end
  end

  assign tile_hit[0] = 1'b1;
  assign word        = addr_i - slot * Words;
  assign macro_wdata = {Pack{wdata_i}};
  assign macro_bm    = Width'(bm_i) << (Bits * slot);
  assign rdata_o     = macro_rdata[tile_q][Bits*slot_q +: Bits];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      slot_q <= '0;
      tile_q <= '0;
    end else if (req_i & ~we_i) begin
      slot_q <= slot;
      tile_q <= tile;
    end
  end

  for (genvar t = 0; t < NumTiles; t++) begin : gen_tiles
    localparam int unsigned TileBase  = tile_base(Width, Words, t);
    localparam int unsigned TileWords = macro_words(Width, Words - TileBase);

    if (t > 0) begin : gen_hit
      assign tile_hit[t] = word >= TileBase;
    end

    tc_sram_ihp13_macro #(
      .Width ( Width     ),
      .Words ( TileWords )
    ) i_macro (
      .clk_i,
      .dly_i,
      .req_i   ( req_i & (tile == t) & (~we_i | (|bm_i)) ),
      .we_i,
      .addr_i  ( word[$clog2(TileWords)-1:0]             ),
      .wdata_i ( macro_wdata                             ),
      .bm_i    ( macro_bm                                ),
      .rdata_o ( macro_rdata[t]                          )
    );
  end

endmodule

module tc_sram_ihp13_x80 #(
  parameter int unsigned Records   = 32'd256,
  // DEPENDENT PARAMETERS, DO NOT OVERWRITE!
  parameter int unsigned AddrWidth = $clog2(Records)
) (
  input  logic                 clk_i,
  input  logic                 rst_ni,
  input  logic                 dly_i,
  input  logic                 req_i,
  input  logic                 we_i,
  input  logic [AddrWidth-1:0] addr_i,
  input  logic [79:0]          wdata_i,
  input  logic [79:0]          bm_i,
  output logic [79:0]          rdata_o
);

  import tc_sram_ihp13_pkg::*;

  localparam int unsigned Layout = best_layout(Records);
  localparam int unsigned LoBits = LayoutLoBits[Layout];
  localparam int unsigned HiPack = LayoutHiPack[Layout];

  tc_sram_ihp13_column #(
    .Records ( Records ),
    .Bits    ( LoBits  ),
    .Pack    ( 1       )
  ) i_lo (
    .clk_i,
    .rst_ni,
    .dly_i,
    .req_i,
    .we_i,
    .addr_i,
    .wdata_i ( wdata_i[LoBits-1:0] ),
    .bm_i    ( bm_i[LoBits-1:0]    ),
    .rdata_o ( rdata_o[LoBits-1:0] )
  );

  tc_sram_ihp13_column #(
    .Records ( Records     ),
    .Bits    ( 80 - LoBits ),
    .Pack    ( HiPack      )
  ) i_hi (
    .clk_i,
    .rst_ni,
    .dly_i,
    .req_i,
    .we_i,
    .addr_i,
    .wdata_i ( wdata_i[79:LoBits] ),
    .bm_i    ( bm_i[79:LoBits]    ),
    .rdata_o ( rdata_o[79:LoBits] )
  );

endmodule

module tc_sram_impl #(
  parameter int unsigned NumWords     = 32'd1024,
  parameter int unsigned DataWidth    = 32'd128,
  parameter int unsigned ByteWidth    = 32'd8,
  parameter int unsigned NumPorts     = 32'd2,
  parameter int unsigned Latency      = 32'd1,
  parameter              SimInit      = "none",
  parameter bit          PrintSimCfg  = 1'b0,
  parameter              ImplKey      = "none",
  parameter type         impl_in_t    = logic,
  parameter type         impl_out_t   = logic,
  parameter impl_out_t   ImplOutSim   = '0,
  // DEPENDENT PARAMETERS, DO NOT OVERWRITE!
  parameter int unsigned AddrWidth = (NumWords > 32'd1) ? $clog2(NumWords) : 32'd1,
  parameter int unsigned BeWidth   = (DataWidth + ByteWidth - 32'd1) / ByteWidth,
  parameter type         addr_t    = logic [AddrWidth-1:0],
  parameter type         data_t    = logic [DataWidth-1:0],
  parameter type         be_t      = logic [BeWidth-1:0]
) (
  input  logic                 clk_i,
  input  logic                 rst_ni,

  input  impl_in_t             impl_i,
  output impl_out_t            impl_o,

  input  logic  [NumPorts-1:0] req_i,
  input  logic  [NumPorts-1:0] we_i,
  input  addr_t [NumPorts-1:0] addr_i,
  input  data_t [NumPorts-1:0] wdata_i,
  input  be_t   [NumPorts-1:0] be_i,

  output data_t [NumPorts-1:0] rdata_o
);

  localparam P1L1 = (NumPorts == 1 & Latency == 1);

  // Assemble bit mask
  data_t [NumPorts-1:0] bm;

  for (genvar p = 0; p < NumPorts; ++p) begin : gen_bm_ports
      for (genvar b = 0; b < DataWidth; ++b) begin : gen_bm_bits
        assign bm[p][b] = be_i[p][b/ByteWidth];
      end
  end

  // We drive a static value for `impl_o` in behavioral simulation.
  assign impl_o = ImplOutSim;

  // Generate desired cuts
  if (NumWords == 64 && DataWidth == 64 && P1L1) begin: gen_64x64xBx1
    logic [63:0] wdata64, rdata64, bm64;

    assign rdata_o = rdata64;
    assign wdata64 = wdata_i;
    assign bm64    = bm;


    RM_IHPSG13_1P_64x64_c2_bm_bist i_cut (
      .A_CLK   ( clk_i    ),
      .A_DLY   ( impl_i  ),
      .A_ADDR  ( addr_i [0][5:0] ),
      .A_BM    ( bm64     ),
      .A_MEN   ( req_i    ),
      .A_WEN   ( we_i     ),
      .A_REN   ( ~we_i    ),
      .A_DIN   ( wdata64  ),
      .A_DOUT       ( rdata64  ),
      .A_BIST_CLK   (  1'b0 ),
      .A_BIST_ADDR  (  6'd0 ),
      .A_BIST_DIN   ( 64'd0 ),
      .A_BIST_BM    ( 64'd0 ),
      .A_BIST_MEN   (  1'b0 ),
      .A_BIST_WEN   (  1'b0 ),
      .A_BIST_REN   (  1'b0 ),
      .A_BIST_EN    (  1'b0 )
    );

  end else if (NumWords == 256 & DataWidth == 64 & P1L1) begin : gen_256x64xBx1
    logic [63:0] wdata64, rdata64, bm64;

    assign rdata_o = rdata64;
    assign wdata64 = wdata_i;
    assign bm64    = bm;

    RM_IHPSG13_1P_256x64_c2_bm_bist i_cut (
      .A_CLK   ( clk_i    ),
      .A_DLY   ( impl_i  ),
      .A_ADDR  ( addr_i [0][7:0] ),
      .A_BM    ( bm64     ),
      .A_MEN   ( req_i    ),
      .A_WEN   ( we_i     ),
      .A_REN   ( ~we_i    ),
      .A_DIN        ( wdata64  ),
      .A_DOUT       ( rdata64  ),
      .A_BIST_CLK   (  1'b0 ),
      .A_BIST_ADDR  (  8'd0 ),
      .A_BIST_DIN   ( 64'd0 ),
      .A_BIST_BM    ( 64'd0 ),
      .A_BIST_MEN   (  1'b0 ),
      .A_BIST_WEN   (  1'b0 ),
      .A_BIST_REN   (  1'b0 ),
      .A_BIST_EN    (  1'b0 )
    );

  end else if (NumWords == 512 & DataWidth == 64 & P1L1) begin : gen_512x64xBx1
    logic [63:0] wdata64, rdata64, bm64;

    assign rdata_o = rdata64;
    assign wdata64 = wdata_i;
    assign bm64    = bm;

    RM_IHPSG13_1P_512x64_c2_bm_bist i_cut (
      .A_CLK   ( clk_i    ),
      .A_DLY   ( impl_i  ),
      .A_ADDR  ( addr_i [0][8:0] ),
      .A_BM    ( bm64     ),
      .A_MEN   ( req_i    ),
      .A_WEN   ( we_i     ),
      .A_REN   ( ~we_i    ),
      .A_DIN        ( wdata64  ),
      .A_DOUT       ( rdata64  ),
      .A_BIST_CLK   (  1'b0 ),
      .A_BIST_ADDR  (  9'd0 ),
      .A_BIST_DIN   ( 64'd0 ),
      .A_BIST_BM    ( 64'd0 ),
      .A_BIST_MEN   (  1'b0 ),
      .A_BIST_WEN   (  1'b0 ),
      .A_BIST_REN   (  1'b0 ),
      .A_BIST_EN    (  1'b0 )
    );

  end else if (NumWords == 1024 & DataWidth == 64 & P1L1) begin : gen_1024x64xBx1
    logic [63:0] wdata64, rdata64, bm64;

    assign rdata_o = rdata64;
    assign wdata64 = wdata_i;
    assign bm64    = bm;

    RM_IHPSG13_1P_1024x64_c2_bm_bist i_cut (
       .A_CLK   ( clk_i    ),
       .A_DLY   ( impl_i  ),
       .A_ADDR  ( addr_i [0][9:0] ),
       .A_BM    ( bm64     ),
       .A_MEN   ( req_i    ),
       .A_WEN   ( we_i     ),
       .A_REN   ( ~we_i    ),
       .A_DIN        ( wdata64  ),
       .A_DOUT       ( rdata64  ),
       .A_BIST_CLK   (  1'b0 ),
       .A_BIST_ADDR  ( 10'd0 ),
       .A_BIST_DIN   ( 64'd0 ),
       .A_BIST_BM    ( 64'd0 ),
       .A_BIST_MEN   (  1'b0 ),
       .A_BIST_WEN   (  1'b0 ),
       .A_BIST_REN   (  1'b0 ),
       .A_BIST_EN    (  1'b0 )
      );

  end else if (NumWords == 2048 & DataWidth == 64 & P1L1) begin : gen_2048x64xBx1
    logic [63:0] wdata64, rdata64, bm64;

    assign rdata_o = rdata64;
    assign wdata64 = wdata_i;
    assign bm64    = bm;

    RM_IHPSG13_1P_2048x64_c2_bm_bist i_cut (
       .A_CLK   ( clk_i    ),
       .A_DLY   ( impl_i   ),
       .A_ADDR  ( addr_i [0][10:0] ),
       .A_BM    ( bm64     ),
       .A_MEN   ( req_i    ),
       .A_WEN   ( we_i     ),
       .A_REN   ( ~we_i    ),
       .A_DIN        ( wdata64  ),
       .A_DOUT       ( rdata64  ),
       .A_BIST_CLK   (  1'b0 ),
       .A_BIST_ADDR  ( 11'd0 ),
       .A_BIST_DIN   ( 64'd0 ),
       .A_BIST_BM    ( 64'd0 ),
       .A_BIST_MEN   (  1'b0 ),
       .A_BIST_WEN   (  1'b0 ),
       .A_BIST_REN   (  1'b0 ),
       .A_BIST_EN    (  1'b0 )
      );
  end else if (NumWords == 512 && DataWidth == 32 && P1L1) begin: gen_512x32xBx1
    logic [31:0] wdata32, rdata32, bm32;

    assign rdata_o = rdata32;
    assign wdata32 = wdata_i;
    assign bm32    = bm;

    RM_IHPSG13_1P_512x32_c2_bm_bist i_cut (
     .A_CLK   ( clk_i   ),
     .A_DLY   ( impl_i  ),
     .A_ADDR  ( addr_i [0][8:0] ),
     .A_BM    ( bm32    ),
     .A_MEN   ( req_i   ),
     .A_WEN   ( we_i    ),
     .A_REN   ( ~we_i   ),
     .A_DIN        ( wdata32 ),
     .A_DOUT       ( rdata32 ),
     .A_BIST_CLK   (  1'b0 ),
     .A_BIST_ADDR  (  9'd0 ),
     .A_BIST_DIN   ( 32'd0 ),
     .A_BIST_BM    ( 32'd0 ),
     .A_BIST_MEN   (  1'b0 ),
     .A_BIST_WEN   (  1'b0 ),
     .A_BIST_REN   (  1'b0 ),
     .A_BIST_EN    (  1'b0 )
    );

  end else if (NumWords == 1024 && DataWidth == 32 && P1L1) begin: gen_1024x32xBx1
    logic [63:0] wdata64, rdata64, bm64;
    logic sel_d, sel_q;

    // muxing neighboring bits instead of upper/lower 32bit reduces routing
    always_comb begin : gen_bit_interleaving
      for (int i = 0; i < 32; i++) begin
          // duplicate each bit
          wdata64[2*i]   = wdata_i[0][i]; // even bits (active if addr LSB is 0)
          bm64[2*i]      = bm[0][i] & ~addr_i[0][0];
          wdata64[2*i+1] = wdata_i[0][i]; // odd bits  (active if addr LSB is 1)
          bm64[2*i+1]    = bm[0][i] & addr_i[0][0];

          if(~sel_q) begin
            rdata_o[0][i] = rdata64[2*i];   // even bits
          end else begin
            rdata_o[0][i] = rdata64[2*i+1]; // odd bits
          end
      end
    end

    // LSB needed for read in next cycle
    assign sel_d = addr_i[0][0];

    always_ff @(posedge clk_i or negedge rst_ni) begin : proc_mem_sel_q
      if(~rst_ni)             sel_q <= '0;
      else if (req_i & ~we_i) sel_q <= sel_d;
    end

    RM_IHPSG13_1P_512x64_c2_bm_bist i_cut (
     .A_CLK   ( clk_i   ),
     .A_DLY   ( impl_i  ),
     .A_ADDR  ( addr_i [0][9:1] ),
     .A_BM    ( bm64    ),
     .A_MEN   ( req_i   ),
     .A_WEN   ( we_i    ),
     .A_REN   ( ~we_i   ),
     .A_DIN        ( wdata64 ),
     .A_DOUT       ( rdata64 ),
     .A_BIST_CLK   (  1'b0 ),
     .A_BIST_ADDR  (  9'd0 ),
     .A_BIST_DIN   ( 64'd0 ),
     .A_BIST_BM    ( 64'd0 ),
     .A_BIST_MEN   (  1'b0 ),
     .A_BIST_WEN   (  1'b0 ),
     .A_BIST_REN   (  1'b0 ),
     .A_BIST_EN    (  1'b0 )
    );
  end else if (NumWords == 2048 && DataWidth == 32 && P1L1) begin: gen_2048x32xBx1
    logic [63:0] wdata64, rdata64, bm64;
    logic sel_d, sel_q;

    // muxing neighboring bits instead of upper/lower 32bit reduces routing
    always_comb begin : gen_bit_interleaving
      for (int i = 0; i < 32; i++) begin
          // duplicate each bit
          wdata64[2*i]   = wdata_i[0][i]; // even bits (active if addr LSB is 0)
          bm64[2*i]      = bm[0][i] & ~addr_i[0][0];
          wdata64[2*i+1] = wdata_i[0][i]; // odd bits  (active if addr LSB is 1)
          bm64[2*i+1]    = bm[0][i] & addr_i[0][0];

          if(~sel_q) begin
            rdata_o[0][i] = rdata64[2*i];   // even bits
          end else begin
            rdata_o[0][i] = rdata64[2*i+1]; // odd bits
          end
      end
    end

    // LSB needed for read in next cycle
    assign sel_d = addr_i[0][0];

    always_ff @(posedge clk_i or negedge rst_ni) begin : proc_mem_sel_q
      if(~rst_ni)             sel_q <= '0;
      else if (req_i & ~we_i) sel_q <= sel_d;
    end

    RM_IHPSG13_1P_1024x64_c2_bm_bist i_cut (
     .A_CLK   ( clk_i   ),
     .A_DLY   ( impl_i  ),
     .A_ADDR  ( addr_i [0][10:1] ),
     .A_BM    ( bm64    ),
     .A_MEN   ( req_i   ),
     .A_WEN   ( we_i    ),
     .A_REN   ( ~we_i   ),
     .A_DIN        ( wdata64 ),
     .A_DOUT       ( rdata64 ),
     .A_BIST_CLK   (  1'b0 ),
     .A_BIST_ADDR  ( 10'd0 ),
     .A_BIST_DIN   ( 64'd0 ),
     .A_BIST_BM    ( 64'd0 ),
     .A_BIST_MEN   (  1'b0 ),
     .A_BIST_WEN   (  1'b0 ),
     .A_BIST_REN   (  1'b0 ),
     .A_BIST_EN    (  1'b0 )
    );

  end else if (NumWords == 2048 & DataWidth == 64 & P1L1) begin : gen_2048x64xBx1
    logic [63:0] wdata64, rdata64, bm64;

    assign rdata_o = rdata64;
    assign wdata64 = wdata_i;
    assign bm64    = bm;

    RM_IHPSG13_1P_2048x64_c2_bm_bist i_cut (
       .A_CLK   ( clk_i    ),
       .A_DLY   ( impl_i   ),
       .A_ADDR  ( addr_i [0][10:0] ),
       .A_BM    ( bm64     ),
       .A_MEN   ( req_i    ),
       .A_WEN   ( we_i     ),
       .A_REN   ( ~we_i    ),
       .A_DIN        ( wdata64  ),
       .A_DOUT       ( rdata64  ),
       .A_BIST_CLK   (  1'b0 ),
       .A_BIST_ADDR  ( 11'd0 ),
       .A_BIST_DIN   ( 64'd0 ),
       .A_BIST_BM    ( 64'd0 ),
       .A_BIST_MEN   (  1'b0 ),
       .A_BIST_WEN   (  1'b0 ),
       .A_BIST_REN   (  1'b0 ),
       .A_BIST_EN    (  1'b0 )
      );

  end else if (NumWords == 16384 && DataWidth == 32 && P1L1) begin : gen_16384x32xBx1

      logic [1:0]  macro_sel;
      logic        word_upper;
      logic [10:0] macro_addr;
      logic [63:0] rdata64 [0:3];
      logic [31:0] rdata32; 
      logic [63:0] wdata64;
      logic [63:0] bm64;

      logic upper_d, upper_q;
      logic rdata_ready_d, rdata_ready_q;
      logic [1:0] macro_d, macro_q;

      logic [31:0] bm32;

      assign macro_sel  = addr_i[0][13:12];
      assign macro_addr = addr_i[0][11:1];
      assign word_upper = addr_i[0][0];
      assign bm32 = {{8{be_i[0][3]}},{8{be_i[0][2]}},{8{be_i[0][1]}},{8{be_i[0][0]}}};

      assign rdata_o[0] = rdata32;

      always_comb begin
          upper_d = upper_q;
          rdata_ready_d = 1'b0;
          macro_d = macro_q;
          wdata64 = 64'b0;
          bm64    = 64'b0;

          if (req_i) begin
            if (we_i) begin //write
              if (word_upper) begin
                wdata64 = {wdata_i[0], 32'b0};
                bm64    = {bm32, 32'b0};
              end
              else begin
                wdata64= {32'b0, wdata_i[0]};
                bm64    = {32'b0, bm32};
              end
            end 
            else begin //read
              rdata_ready_d = 1'b1;
              upper_d = word_upper;
              macro_d = macro_sel;
            end
          end 
        end

        always_comb begin
          rdata32 = 32'b0;
          if (rdata_ready_q) begin
            if (upper_q) begin
              rdata32 = rdata64[macro_q][63:32];
            end
            else begin
              rdata32 = rdata64[macro_q][31:0];
            end 
          end
        end


        always_ff @(posedge clk_i or negedge rst_ni) begin
          if (!rst_ni) begin
            upper_q <= 0;
            rdata_ready_q <= 0;
            macro_q <= 0;
          end
          else begin
            upper_q <= upper_d;
            rdata_ready_q <= rdata_ready_d;
            macro_q <= macro_d;
          end
        end

   
      for (genvar i = 0; i < 4; i++) begin
        
        // read data avail 1 cycle after macro was activated
        RM_IHPSG13_1P_2048x64_c2_bm_bist i_cut (
        .A_CLK   ( clk_i    ),
        .A_DLY   ( impl_i   ),
        .A_ADDR  ( macro_addr ),
        .A_BM    ( bm64     ),
        .A_MEN   ( req_i && (macro_sel == i)   ), //activate macro
        .A_WEN   ( we_i     ),
        .A_REN   ( ~we_i    ),
        .A_DIN        ( wdata64  ),
        .A_DOUT       ( rdata64[i]  ),
        .A_BIST_CLK   (  1'b0 ),
        .A_BIST_ADDR  ( 11'd0 ),
        .A_BIST_DIN   ( 64'd0 ),
        .A_BIST_BM    ( 64'd0 ),
        .A_BIST_MEN   (  1'b0 ),
        .A_BIST_WEN   (  1'b0 ),
        .A_BIST_REN   (  1'b0 ),
        .A_BIST_EN    (  1'b0 )
        );

      end



  end else if (DataWidth == 80 && NumWords % tc_sram_ihp13_pkg::SegmentUnit == 0 &&
               NumWords <= tc_sram_ihp13_pkg::SegmentUnit * tc_sram_ihp13_pkg::MaxUnits && P1L1)
      begin : gen_Nx80xBx1
    localparam tc_sram_ihp13_pkg::segment_plan_t Plan = tc_sram_ihp13_pkg::segment_plan(NumWords);
    localparam int unsigned NumSegments  = tc_sram_ihp13_pkg::num_segments(Plan);
    localparam int unsigned SegmentWidth = (NumSegments > 1) ? $clog2(NumSegments) : 1;

    logic [SegmentWidth-1:0] segment, segment_q;
    logic [NumSegments-1:0]  segment_hit;
    logic [79:0]             segment_rdata [NumSegments];

    always_comb begin
      segment = '0;
      for (int unsigned s = 1; s < NumSegments; s++) begin
        if (segment_hit[s]) segment = SegmentWidth'(s);
      end
    end

    assign segment_hit[0] = 1'b1;
    assign rdata_o[0]     = segment_rdata[segment_q];

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni)                  segment_q <= '0;
      else if (req_i[0] & ~we_i[0]) segment_q <= segment;
    end

    for (genvar s = 0; s < NumSegments; s++) begin : gen_segments
      localparam int unsigned Base     = tc_sram_ihp13_pkg::segment_base(Plan, s);
      localparam int unsigned Records  = Plan[s] * tc_sram_ihp13_pkg::SegmentUnit;
      localparam int unsigned RecAddrW = $clog2(Records);

      if (s > 0) begin : gen_hit
        assign segment_hit[s] = addr_i[0] >= Base;
      end

      tc_sram_ihp13_x80 #(
        .Records ( Records )
      ) i_segment (
        .clk_i,
        .rst_ni,
        .dly_i   ( impl_i                        ),
        .req_i   ( req_i[0] & (segment == s)     ),
        .we_i    ( we_i[0]                       ),
        .addr_i  ( RecAddrW'(addr_i[0] - Base)   ),
        .wdata_i ( wdata_i[0]                    ),
        .bm_i    ( bm[0]                         ),
        .rdata_o ( segment_rdata[s]              )
      );
    end

  end else begin : gen_blackbox

  `ifndef SYNTHESIS
    initial $fatal("No tc_sram for %m: NumWords %0d, DataWidth %0d NumPorts %0d, Latency %0d",
        NumWords, DataWidth, NumPorts);
  `endif

  // Instantiate a non-linkable blackbox with parameters for debugging
  `ifdef SYNTHESIS
    (* dont_touch = "true" *)
    tc_sram_blackbox #(
      .NumWords     ( NumWords    ),
      .DataWidth    ( DataWidth   ),
      .ByteWidth    ( ByteWidth   ),
      .NumPorts     ( NumPorts    ),
      .Latency      ( Latency     ),
      .SimInit      ( SimInit     ),
      .PrintSimCfg  ( PrintSimCfg ),
      .ImplKey      ( ImplKey     )
    ) i_sram_blackbox ();
  `endif

end

endmodule
