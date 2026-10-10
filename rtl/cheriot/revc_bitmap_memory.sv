module revc_bitmap_memory #(
    parameter logic [31:0] BitmapBase = 32'h1000_1000,
    parameter int BitmapNumb = 1'd1
) (
    input logic clk_i,
    input logic rst_ni,
    input logic data_req_i,
    input logic data_we_i,
    input logic [31:0] data_addr_i,
    input logic [31:0] data_wdata_i,
    input logic [3:0] data_be_i,
    output logic data_rvalid_o,
    output logic [31:0] data_rdata_o,
    output logic data_gnt_o,

    input logic trvk_revbm_req_i,
    input logic [31:0] trvk_revbm_addr_i,

    output logic trvk_revbm_gnt_o,
    output logic trvk_revbm_rvalid_o,
    output logic [31:0] trvk_revbm_rdata_o,
    output logic trvk_revbm_err_o

);

  localparam logic [31:0] BitmapEnd = BitmapBase + BitmapNumb * 8;

  typedef enum logic [1:0] {
    IDLE,
    TRVK_READ,
    READ,
    WRITE
  } mode_t;

  mode_t mode;


  logic [31:0] trvk_rdata_d, trvk_rdata_q;
  logic trvk_rvalid_d, trvk_rvalid_q;

  logic [31:0] rdata_d, rdata_q;
  logic rvalid_d, rvalid_q;


  logic [31:0] rev_bitmap_d[0:BitmapNumb];
  logic [31:0] rev_bitmap_q[0:BitmapNumb];

  assign trvk_revbm_rdata_o = trvk_rdata_q;
  assign trvk_revbm_rvalid_o = trvk_rvalid_q;
  assign trvk_revbm_gnt_o = 1'b1;
  assign trvk_revbm_err_o = 1'b0;

  assign data_rdata_o = rdata_q;
  assign data_rvalid_o = rvalid_q;

  assign data_gnt_o = 1'b1;

  always_comb begin
    rev_bitmap_d = rev_bitmap_q;
    trvk_rdata_d = trvk_rdata_q;
    trvk_rvalid_d = 0;
    rdata_d = rdata_q;
    rvalid_d = 0;


    if (mode == WRITE) begin
      int word_index;
      word_index = (data_addr_i - BitmapBase) >> 2;
      for (int b = 0; b < 4; b++) begin
        if (data_be_i[b]) begin
          rev_bitmap_d[word_index][8*b+:8] = data_wdata_i[8*b+:8];
        end
      end
    end else if (mode == TRVK_READ) begin
      int word_index;
      word_index = (trvk_revbm_addr_i - BitmapBase) >> 2;
      trvk_rdata_d = rev_bitmap_q[word_index];
      trvk_rvalid_d = 1;
    end else if (mode == READ) begin
      int word_index;
      word_index = (data_addr_i - BitmapBase) >> 2;
      rdata_d = rev_bitmap_q[word_index];
      rvalid_d = 1;
    end else begin
      rev_bitmap_d = rev_bitmap_q;
    end

  end


  always_comb begin
    mode = IDLE;
    if (data_addr_i >= BitmapBase && data_addr_i < BitmapEnd && data_req_i) begin
      if (data_we_i) begin
        mode = WRITE;
      end else begin
        mode = READ;
      end
    end 

    else if (trvk_revbm_addr_i >= BitmapBase && trvk_revbm_addr_i < BitmapEnd && trvk_revbm_req_i) begin
      mode = TRVK_READ;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int i = 0; i < BitmapNumb + 1; ++i) begin
        rev_bitmap_q[i] <= 0;
      end
      trvk_rdata_q <= 0;
      trvk_rvalid_q <= 0;
      rdata_q <= 0;
      rvalid_q <= 0;
    end else begin
      rev_bitmap_q <= rev_bitmap_d;
      trvk_rdata_q <= trvk_rdata_d;
      trvk_rvalid_q <= trvk_rvalid_d;
      rdata_q <= rdata_d;
      rvalid_q <= rvalid_d;
    end
  end



endmodule
