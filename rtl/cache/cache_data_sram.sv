

module cache_data_sram #(
    parameter int unsigned NumWords = 512,

    localparam int unsigned DataWidth = 80,
    localparam int unsigned AddrWidth = (NumWords > 1) ? $clog2(NumWords) : 1
) (
    input  logic                 clk_i,
    input  logic                 rst_ni,

    input  logic                 req_i,
    input  logic                 we_i,
    input  logic [AddrWidth-1:0] addr_i,
    input  logic [DataWidth-1:0] wdata_i,

    output logic [DataWidth-1:0] rdata_o
);
    logic [63:0] part_rdata [2];
    logic [1:0] read_slot_q;

    assign rdata_o[63:0] = part_rdata[0];
    assign rdata_o[79:64] = part_rdata[1][16 * read_slot_q +: 16];

    for (genvar part = 0; part < 2; part++) begin : gen_parts

        logic                     part_req;
        logic [AddrWidth-1:0]      part_addr;
        logic [63:0]              part_wdata;
        logic [7:0]               part_be;

        assign part_req = req_i && (addr_i < NumWords);
        assign part_addr = (part == 0) ? addr_i : (addr_i >> 2);
        assign part_wdata = (part == 0) ? wdata_i[63:0]: {4{wdata_i[79:64]}};
        assign part_be = (part == 0) ? 8'hFF: (8'b00000011 << (2 * addr_i[1:0]));
        localparam int unsigned PartWords = (part == 0) ? NumWords : NumWords / 4;

        localparam int unsigned Count2048 =  PartWords         / 2048;
        localparam int unsigned Count1024 = (PartWords % 2048) / 1024;
        localparam int unsigned Count512  = (PartWords % 1024) / 512;
        localparam int unsigned Count256  = (PartWords % 512)  / 256;
        localparam int unsigned Count64   = (PartWords % 256)  / 64;

        localparam int unsigned NumMacros = Count2048 + Count1024 + Count512 + Count256 + Count64;

        logic [63:0] bank_rdata [NumMacros];

        logic [NumMacros-1:0] bank_req_vec;
        logic [NumMacros-1:0] read_sel_q;
        logic [63:0] selected_rdata;

        assign part_rdata[part] = selected_rdata;

        always_comb begin
            selected_rdata = '0;

            for (int i = 0; i < NumMacros; i++) begin
                if (read_sel_q[i]) begin
                    selected_rdata = bank_rdata[i];
                end
            end
        end

        always_ff @(posedge clk_i or negedge rst_ni) begin
            if (!rst_ni) begin
                read_sel_q <= '0;
            end else if (part_req && !we_i) begin
                read_sel_q <= bank_req_vec;
            end
        end

        for (genvar bank = 0; bank < Count2048; bank++) begin : gen_2048

            localparam int unsigned BaseAddr = bank * 2048;
            logic bank_req;
            
            assign bank_req = part_req && (part_addr >= BaseAddr) && (part_addr < BaseAddr + 2048);
            assign bank_req_vec[bank] = bank_req;

            tc_sram_impl #(
                .NumWords  (2048),
                .DataWidth (64),
                .ByteWidth (8),
                .NumPorts  (1),
                .Latency   (1)
            ) i_sram (
                .clk_i,
                .rst_ni,
                .impl_i  ('0),
                .impl_o  (),
                .req_i   (bank_req),
                .we_i    (we_i),
                .addr_i  (part_addr[10:0]),
                .wdata_i (part_wdata),
                .be_i    (part_be),
                .rdata_o (bank_rdata[bank])
            );
        end

        for (genvar bank = 0; bank < Count1024; bank++) begin : gen_1024

            localparam int unsigned BaseAddr = Count2048 * 2048 + bank * 1024;
            localparam int unsigned MacroIndex = Count2048 + bank;

            logic bank_req;

            assign bank_req = part_req && (part_addr >= BaseAddr) && (part_addr < BaseAddr + 1024);
            assign bank_req_vec[MacroIndex] = bank_req;

            tc_sram_impl #(
                .NumWords  (1024),
                .DataWidth (64),
                .ByteWidth (8),
                .NumPorts  (1),
                .Latency   (1)
            ) i_sram (
                .clk_i,
                .rst_ni,
                .impl_i  ('0),
                .impl_o  (),
                .req_i   (bank_req),
                .we_i    (we_i),
                .addr_i  (part_addr[9:0]),
                .wdata_i (part_wdata),
                .be_i    (part_be),
                .rdata_o (bank_rdata[MacroIndex])
            );
        end

        for (genvar bank = 0; bank < Count512; bank++) begin : gen_512

            localparam int unsigned BaseAddr = Count2048 * 2048 + Count1024 * 1024 + bank * 512;
            localparam int unsigned MacroIndex = Count2048 + Count1024 + bank;

            logic bank_req;

            assign bank_req = part_req && (part_addr >= BaseAddr) && (part_addr < BaseAddr + 512);
            assign bank_req_vec[MacroIndex] = bank_req;

            tc_sram_impl #(
                .NumWords  (512),
                .DataWidth (64),
                .ByteWidth (8),
                .NumPorts  (1),
                .Latency   (1)
            ) i_sram (
                .clk_i,
                .rst_ni,
                .impl_i  ('0),
                .impl_o  (),
                .req_i   (bank_req),
                .we_i    (we_i),
                .addr_i  (part_addr[8:0]),
                .wdata_i (part_wdata),
                .be_i    (part_be),
                .rdata_o (bank_rdata[MacroIndex])
            );
        end


        for (genvar bank = 0; bank < Count256; bank++) begin : gen_256

            localparam int unsigned BaseAddr = Count2048 * 2048 + Count1024 * 1024 + Count512 * 512 + bank * 256;
            localparam int unsigned MacroIndex = Count2048 + Count1024 + Count512 + bank;
            
            logic bank_req;

            assign bank_req = part_req && (part_addr >= BaseAddr) && (part_addr < BaseAddr + 256);
            assign bank_req_vec[MacroIndex] = bank_req;

            tc_sram_impl #(
                .NumWords  (256),
                .DataWidth (64),
                .ByteWidth (8),
                .NumPorts  (1),
                .Latency   (1)
            ) i_sram (
                .clk_i,
                .rst_ni,
                .impl_i  ('0),
                .impl_o  (),
                .req_i   (bank_req),
                .we_i    (we_i),
                .addr_i  (part_addr[7:0]),
                .wdata_i (part_wdata),
                .be_i    (part_be),
                .rdata_o (bank_rdata[MacroIndex])
            );
        end


        for (genvar bank = 0; bank < Count64; bank++) begin : gen_64

            localparam int unsigned BaseAddr = Count2048 * 2048 + Count1024 * 1024 + Count512 * 512 + Count256 * 256 + bank * 64;
            localparam int unsigned MacroIndex = Count2048 + Count1024 + Count512 + Count256 + bank;

            logic bank_req;

            assign bank_req = part_req && (part_addr >= BaseAddr) && (part_addr < BaseAddr + 64);
            assign bank_req_vec[MacroIndex] = bank_req;

            tc_sram_impl #(
                .NumWords  (64),
                .DataWidth (64),
                .ByteWidth (8),
                .NumPorts  (1),
                .Latency   (1)
            ) i_sram (
                .clk_i,
                .rst_ni,
                .impl_i  ('0),
                .impl_o  (),
                .req_i   (bank_req),
                .we_i    (we_i),
                .addr_i  (part_addr[5:0]),
                .wdata_i (part_wdata),
                .be_i    (part_be),
                .rdata_o (bank_rdata[MacroIndex])
            );
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            read_slot_q <= '0;
        end 
        else if (req_i && !we_i && (addr_i < NumWords)) begin
            read_slot_q <= addr_i[1:0];
        end
    end


endmodule