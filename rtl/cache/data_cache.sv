`include "cache_typedef.svh"

module data_cache #(
    parameter int unsigned AddrWidth      = 32,
    parameter int unsigned CpuDataWidth   = 32,
    parameter int unsigned CacheDataBytes = 8 * 1024,
    parameter int unsigned LineDataBytes  = 16,
    parameter int unsigned NumWays        = 2,
    parameter type         obi_req_t      = logic,
    parameter type         obi_rsp_t      = logic
) (
    input  logic     clk_i,
    input  logic     rst_ni,

    // obi signals <-> crossbar <-> ibex
    input  obi_req_t obi_req_i,
    output obi_rsp_t obi_rsp_o,




);

    import cache_pkg::*;

    typedef enum logic [2:0]
    {  
        IDLE,
        CACHE_LOOKUP,
        ACCESS_SRAM,
        WAIT_FOR_SECOND_WORD,



    } state_t;

    state_t state_q, state_d;

    localparam int unsigned EccBits = CacheEccBits;

    localparam int unsigned NumSets = CacheDataBytes / (LineDataBytes * NumWays);
    localparam int unsigned OffsetBits = $clog2(LineDataBytes);
    localparam int unsigned SetBits    = $clog2(NumSets);
    localparam int unsigned TagBits    = AddrWidth - OffsetBits - SetBits;

    localparam int unsigned RecordDataBytes = CacheRecordDataBytes;
    localparam int unsigned SramWordsPerWay = CacheDataBytes / (NumWays * RecordDataBytes);
    localparam int unsigned SramAddrWidth = (SramWordsPerWay > 1) ? $clog2(SramWordsPerWay) : 1;

    localparam int unsigned RecordsPerLine = LineDataBytes / RecordDataBytes;
    localparam int unsigned RecordBits = CacheRecordBits;

    // sram signals 

    logic [NumWays-1:0] sram_req;
    logic               sram_we;
    logic [RecordBits-1:0] sram_wdata;
    logic [RecordBits-1:0] sram_rdata [NumWays];

    logic [SramAddrWidth-1:0] sram_word_addr;
    logic [RecordBits/8-1:0] sram_mask;

    // cache signals/memory
    `CACHE_TYPEDEF_META_T(cache_meta_t, TagBits)

    cache_meta_t cache_meta_q [NumSets][NumWays];
    cache_meta_t cache_meta_d [NumSets][NumWays];

    logic [TagBits-1:0] addr_tag;
    logic [SetBits-1:0] set_index;

    logic [$clog2(NumWays)-1:0] selected_way_q, selected_way_d;

    logic [RecordBits-1:0] rdata_cache_q,rdata_cache_d;
    logic [OffsetBits-1:0] block_offset;

    // obi singals 
    logic [CpuDataWidth/8-1:0]  obi_req_be_q, obi_req_be_d;
    logic [AddrWidth-1:0]       obi_req_addr_q, obi_req_addr_d;
    logic                       obi_req_write_q, obi_req_write_d;
    logic                       obi_req_wtag_q, obi_req_wtag_d;
    logic                       obi_is_cap_store_q, obi_is_cap_store_d;

    cap_store_t cap_store_q, cap_store_d;             

    assign set_index = obi_req_addr_q[OffsetBits +: SetBits];
    assign addr_tag = obi_req_addr_q[AddrWidth-1 : OffsetBits+SetBits];
    assign block_offset = obi_req_addr_q[OffsetBits-1 : 0];
    assign sram_word_addr = set_index * RecordsPerLine + (block_offset / RecordDataBytes);


    always_comb begin

        state_d = state_q;

        obi_req_be_d = obi_req_be_q;
        obi_req_addr_d = obi_req_addr_q;
        obi_req_write_d = obi_req_write_q;
        obi_req_wtag_d = obi_req_wtag_q;
        obi_is_cap_store_d = obi_is_cap_store_q;
        cap_store_d = cap_store_q;

        obi_rsp_o = '0;

        cache_meta_d = cache_meta_q;
        selected_way_d = selected_way_q;
        rdata_cache_d = rdata_cache_q;

        sram_req[0] = 0;
        sram_req[1] = 0;
        sram_we     = 0;
        sram_wdata  = '0;
        sram_mask   = '0;
        
        case (state_q)

            IDLE: begin
                obi_rsp_o.gnt = 1'b1; //cache ready to receive requests

                if (obi_req_i.req && obi_rsp_o.gnt) begin

                    obi_req_be_d = obi_req_i.a.be;
                    obi_req_addr_d = obi_req_i.a.addr;
                    obi_req_write_d = obi_req_i.a.we;
                    obi_is_cap_store_d = obi_req_i.a.a_optional.is_cap_store;

                    // only used for write
                    if (obi_req_i.a.we) begin
                        cap_store_d.lower.data    = obi_req_i.a.wdata;
                        cap_store_d.lower.ecc     = obi_req_i.a.a_optional.ecc;
                        cap_store_d.lower.cap_tag = obi_req_i.a.a_optional.cap_tag;
                    end
    
                    state_d = CACHE_LOOKUP;
                end
            end

            CACHE_LOOKUP: begin

                for (int way=0; way<NumWays; ++way) begin
                    if (cache_meta_q[set_index][way].addr_tag == addr_tag 
                        && cache_meta_q[set_index][way].valid) begin  // cache hit

                        selected_way_d = way;
                        //sram_req[way] = 1;

                        if (obi_is_cap_store_q && obi_req_write_q) begin //cap write
                            obi_rsp_o.gnt = 1'b1;
                            if (obi_req_i.req && obi_rsp_o.gnt) begin //second word already here we can already write to sram
                                sram_req[way] = 1; 
                                cap_store_d.upper.data    = obi_req_i.a.wdata;
                                cap_store_d.upper.ecc     = obi_req_i.a.a_optional.ecc;
                                cap_store_d.upper.cap_tag = obi_req_i.a.a_optional.cap_tag;

                                sram_wdata    = cap_store_d;
                                sram_mask     = '1;
                                sram_req[way] = 1'b1;
                                sram_we       = 1'b1;
                                cache_meta_d[set_index][way].dirty = 1;
                                state_d = /*todo*/
                            end
                            else begin //second word not here we need to wait for it
                                state_d = WAIT_FOR_SECOND_WORD;
                            end
                        end

                        else if (!obi_is_cap_store_q && obi_req_write_q) begin //normal store
                            sram_wdata    = cap_store_d;
                            sram_mask = 10'h01F; //set lower five bits
                            if (obi_req_addr_q[2] = 1) begin //set upper bits
                                sram_mask = 10'h3E0; //upper 5 bits
                            end
                            else begin
                                sram_mask = 10'h01F; //lower 5 bits
                            end
                            sram_req[way] = 1'b1;
                            sram_we       = 1'b1;
                            cache_meta_d[set_index][way].dirty = 1;

                            state_d = /*todo*/

                            
                        end
                        

                        
                        
                        //state_d = ACCESS_SRAM;
                    end
                    else begin // cache miss
                        //todo
                    end
                    
                end  
            end

            WAIT_FOR_SECOND_WORD: begin //cap address should be 
                obi_rsp_o.gnt = 1'b1;
                if (obi_req_i.req && obi_rsp_o.gnt) begin //second word already here we can already write to sram
                    cap_store_d.upper.data    = obi_req_i.a.wdata;
                    cap_store_d.upper.ecc     = obi_req_i.a.a_optional.ecc;
                    cap_store_d.upper.cap_tag = obi_req_i.a.a_optional.cap_tag;

                    sram_wdata    = cap_store_d;
                    sram_mask     = '1;
                    sram_req[selected_way_q] = 1'b1;
                    sram_we       = 1'b1;
                    sram_req[selected_way_q] = 1; 
                    cache_meta_d[set_index][selected_way_q].dirty = 1;
                    state_d = /*Todo*/
                end
                
            end

            ACCESS_SRAM: begin
                // if (!obi_req_write_q) begin
                //     rdata_cache_d = sram_rdata[selected_way_q]; //rdata from sram should be there 1 cycle delay
                // end
            end
            
            default: begin
                state_d = IDLE;
            end
        endcase
    end


    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <= IDLE;
        end
        else begin
            state_q <= state_d;
        end
        
    end


    // obi request flip flops
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            obi_req_be_q <= 0;
            obi_req_addr_q <= 0;
            obi_req_write_q <= 0;
            obi_is_cap_store_q <= 0;
            cap_store_q <= '0; 
        end
        else begin
            obi_req_be_q <= obi_req_be_d;
            obi_req_addr_q <= obi_req_addr_d;
            obi_req_write_q <= obi_req_write_d;
            obi_is_cap_store_q <= obi_is_cap_store_d;
            cap_store_q <= cap_store_d;
        end
        
    end

    // cache meta-data
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            for (int unsigned s = 0; s < NumSets; s++) begin
                for (int unsigned w = 0; w < NumWays; w++) begin
                    cache_meta_q[s][w] <= '0;
                end
            end
            selected_way_q <= 0;
            rdata_cache_q <= 0;
        end else begin
            cache_meta_q <= cache_meta_d;
            selected_way_q <= selected_way_d;
            rdata_cache_q <= rdata_cache_d;
        end
    end

    localparam unsigned int NumWords = 512;
    localparam unsigned int AddrWidthSram = (NumWords > 1) ? $clog2(NumWords) : 1;

    cache_data_sram #(
        .NumWords(NumWords),
        .DataWidth(80),
        .AddrWidth(AddrWidthSram)
    ) i_cache_data_sram_way_0 (

        .clk_i(clk_i),
        .rst_ni(rst_ni),

        .req_i(sram_req[0]),
        .we_i(sram_we),
        .addr_i(sram_word_addr),
        .wdata_i(sram_wdata),
        .be_i(sram_mask),

        .rdata_o(sram_rdata[0])
    );

    cache_data_sram #(
        .NumWords(NumWords),
        .DataWidth(80),
        .AddrWidth(AddrWidthSram)
    ) i_cache_data_sram_way_1 (

        .clk_i(clk_i),
        .rst_ni(rst_ni),

        .req_i(sram_req[1]),
        .we_i(sram_we),
        .addr_i(sram_word_addr),
        .wdata_i(sram_wdata),
        .be_i(sram_mask),

        .rdata_o(sram_rdata[1])
    );
    // synthesis translate_off
    assert_cap_store_second_addr: assert property (
        @(posedge clk_i) disable iff (!rst_ni)
        (
            (state_q == CHACHE_LOOKUP ||
            state_q == WAIT_FOR_SECOND_WORD) &&
            obi_is_cap_store_q &&
            obi_req_write_q &&
            obi_req_i.req &&
            obi_rsp_o.gnt
        )
        |-> (obi_req_i.a.addr == obi_req_addr_q + AddrWidth'(4))
    ) else $fatal(
        1,
        "Capability store: expected second address 0x%0h, got 0x%0h",
        obi_req_addr_q + AddrWidth'(4),
        obi_req_i.a.addr
    );
// synthesis translate_on


endmodule
