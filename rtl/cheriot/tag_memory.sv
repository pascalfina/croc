
//  sram goes from 
//  Bank 0: 0x1000_0000 bis 0x1000_07ff
//  Bank 1: 0x1000_0800 bis 0x1000_0fff
//  currently tag bit per 32 bit word 
//  since each bank 512 for both banks 

module tag_memory #(
    parameter logic [31:0] SRAM_OFFSET = 32'h1000_0000
) (
    input logic clk_i,
    input logic rst_ni,
    input logic data_req_i,
    input logic [31:0] data_addr_i,
    input logic data_tag_i,
    input logic data_we_i,
    output logic data_tag_o
);

 localparam int unsigned TAG_WIDTH = 512;

  logic [TAG_WIDTH-1:0] tag_mem_q, tag_mem_d;
  logic [8:0] idx;
  logic tag_read_d, tag_read_q;


  assign data_tag_o = tag_read_q;

  always_comb begin
    tag_mem_d = tag_mem_q;
    idx = (data_addr_i - SRAM_OFFSET) >> 2;
    tag_read_d = tag_read_q;

    if (data_req_i) begin
      if (data_we_i) begin  //write
        tag_mem_d[idx] = data_tag_i;
      end else begin  //read 
        tag_read_d = tag_mem_q[idx];
      end
    end
  end


  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      tag_mem_q  <= 0;
      tag_read_q <= 0;
    end else begin
      tag_mem_q  <= tag_mem_d;
      tag_read_q <= tag_read_d;
    end
  end

endmodule




