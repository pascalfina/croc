`include "cache_typedef.svh"

module instruction_cache #(
    parameter int unsigned AddrWidth            = 32,
    parameter int unsigned CpuDataWidth         = 32,
    parameter int unsigned CacheDataBytes       = 8 * 1024,
    parameter int unsigned LineDataBytes        = 16,
    parameter int unsigned NumWays              = 2,
    parameter type         obi_req_t      = logic,
    parameter type         obi_rsp_t      = logic,
    parameter type         mem_req_t      = logic,
    parameter type         mem_rsp_t      = logic
) (
    input  logic     clk_i,
    input  logic     rst_ni,

    // obi signals data cache <-> crossbar <-> ibex
    input  obi_req_t obi_req_i,
    output obi_rsp_t obi_rsp_o,

    // Complete-line transfers to the shared memory arbiter.
    output mem_req_t mem_req_o,
    input  mem_rsp_t mem_rsp_i
);
    import cache_pkg::*;

    localparam int unsigned EccBits = CacheEccBits;

    localparam int unsigned NumSets = (LineDataBytes > 0 && NumWays > 0)
        ? CacheDataBytes / NumWays / LineDataBytes : 0;
    localparam int unsigned OffsetBits = $clog2(LineDataBytes);
    localparam int unsigned SetBits    = $clog2(NumSets);
    localparam int unsigned SetIndexWidth = (NumSets > 1) ? SetBits : 1;
    localparam int unsigned WayIndexWidth = (NumWays > 1) ? $clog2(NumWays) : 1;
    localparam int unsigned TagBits = (AddrWidth > OffsetBits + SetBits)
        ? AddrWidth - OffsetBits - SetBits : 1;

    localparam int unsigned RecordDataBytes = CacheRecordDataBytes;
    localparam int unsigned SramWordsPerWay = (NumWays > 0)
        ? CacheDataBytes / NumWays / RecordDataBytes : 0;
    localparam int unsigned SramAddrWidth = (SramWordsPerWay > 1) ? $clog2(SramWordsPerWay) : 1;

    localparam int unsigned RecordsPerLine = LineDataBytes / RecordDataBytes;
    localparam int unsigned RecordBits = CacheRecordBits;

    localparam int unsigned ObiIdWidth = $bits(obi_req_i.a.aid);

    typedef enum logic [3:0]
    {  
        IDLE,
        CACHE_LOOKUP,
        ACCESS_SRAM,
        SEND_REFILL_CMD, 
        WAIT_REFILL_DATA, 
        WAIT_REFILL_DONE

    } state_t;

    state_t state_q, state_d;

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
     
    logic [WayIndexWidth-1:0] selected_way_q, selected_way_d;
    logic [WayIndexWidth-1:0] replace_way_q [NumSets];
    logic [WayIndexWidth-1:0] replace_way_d [NumSets];

    logic [TagBits-1:0] addr_tag;
    logic [SetIndexWidth-1:0] set_index;
    logic [OffsetBits-1:0] block_offset;

    logic hit_found;
    logic all_valid;


    // obi signals 
    logic [AddrWidth-1:0]       obi_req_addr_q, obi_req_addr_d;
    logic [ObiIdWidth-1:0]      obi_aid_q, obi_aid_d;
    logic [$clog2(RecordsPerLine)-1:0] line_record_index_q, line_record_index_d;

    // extra 

    cap_word_t read_word;


    if (NumSets > 1) begin : gen_set_index
        assign set_index = obi_req_addr_q[OffsetBits +: SetBits];
    end else begin : gen_single_set
        assign set_index = '0;
    end

    assign addr_tag = obi_req_addr_q[AddrWidth-1 : OffsetBits+SetBits];
    assign block_offset = obi_req_addr_q[OffsetBits-1 : 0];
    //assign sram_word_addr = set_index * RecordsPerLine + (block_offset / RecordDataBytes);


    assign read_word = obi_req_addr_q[2] ? sram_rdata[selected_way_q][RecordBits-1 : RecordBits/2] 
        : sram_rdata[selected_way_q][RecordBits/2-1 : 0];



    always_comb begin

        state_d = state_q;

        // obi signals
        obi_req_addr_d      = obi_req_addr_q;
        obi_aid_d           = obi_aid_q;

        // module output
        obi_rsp_o           = '0;
        mem_req_o           = '0;

        // cache logic signals
        cache_meta_d        = cache_meta_q;
        selected_way_d      = selected_way_q;
        replace_way_d       = replace_way_q;
        line_record_index_d = line_record_index_q;

        hit_found           = 0;
        all_valid           = 0;

        // sram signals
        sram_req            = '0;
        sram_we             =  0;
        sram_wdata          = '0;
        sram_mask           = '0;
        sram_word_addr      = set_index * RecordsPerLine + (block_offset / RecordDataBytes);
        
        case (state_q)

            IDLE: begin
                obi_rsp_o.gnt = 1'b1; //cache ready to receive requests

                if (obi_req_i.req && obi_rsp_o.gnt) begin // get new request
                    obi_req_addr_d = obi_req_i.a.addr;
                    obi_aid_d = obi_req_i.a.aid;
                    state_d = CACHE_LOOKUP;
                end
            end

            CACHE_LOOKUP: begin
                hit_found = 0;
                for (int way=0; way<NumWays; ++way) begin
                    if (cache_meta_q[set_index][way].addr_tag == addr_tag 
                        && cache_meta_q[set_index][way].valid) begin  // cache hit

                        hit_found = 1;
                        selected_way_d = WayIndexWidth'(way);

                        sram_req[way] = 1'b1;
                        sram_we       = 1'b0;
                        state_d       = ACCESS_SRAM; 
                    end
                end
                if(!hit_found) begin // cache miss
                    all_valid = 1;
                    selected_way_d = replace_way_q[set_index];
                    for (int way=0; way<NumWays; ++way) begin
                        if (all_valid && !cache_meta_q[set_index][way].valid) begin //choose this cacheline
                            all_valid = 0;
                            selected_way_d = WayIndexWidth'(way);
                        end
                    end
                    state_d = SEND_REFILL_CMD; // immidately fetch new cachelin
                end
            end

            SEND_REFILL_CMD: begin
                mem_req_o.cmd.write = 0; // we want to read from hypperam

                // use adress received from obi bus
                mem_req_o.cmd.line_addr = {obi_req_addr_q[AddrWidth-1:OffsetBits],{OffsetBits{1'b0}}};
                mem_req_o.cmd.records = RecordsPerLine; //fetch one cacheline
                mem_req_o.cmd_valid = 1'b1;

                if (mem_req_o.cmd_valid && mem_rsp_i.cmd_ready) begin
                    state_d = WAIT_REFILL_DATA;
                    line_record_index_d = 0;
                end  
            end

            WAIT_REFILL_DATA: begin
                mem_req_o.r_ready = 1;
                if (mem_rsp_i.r_valid && mem_req_o.r_ready) begin //write data to sram
                    sram_req[selected_way_q] = 1;
                    sram_we = 1;
                    sram_word_addr = set_index * RecordsPerLine + line_record_index_q;
                    sram_wdata = mem_rsp_i.r.record;
                    sram_mask     = '1;
                    
                    if (line_record_index_q == RecordsPerLine - 1) begin
                        state_d = WAIT_REFILL_DONE;
                    end
                    else begin
                        line_record_index_d  = line_record_index_q + 1;
                    end
                end
            end

            WAIT_REFILL_DONE: begin
                mem_req_o.done_ready = 1;
                if (mem_rsp_i.done_valid && mem_req_o.done_ready) begin
                    
                    if (mem_rsp_i.done.error) begin //todo: erro handling do smth
                        // todo later somewhen maybe never
                    end
                    else begin //no error world is fine
                        cache_meta_d[set_index][selected_way_q].valid = 1; //data also valid
                        cache_meta_d[set_index][selected_way_q].addr_tag = addr_tag;

                        if (selected_way_q != NumWays-1) begin //round robin way selection within a set
                            replace_way_d[set_index] = selected_way_q + 1;
                        end
                        else begin
                            replace_way_d[set_index] = '0;
                        end
                        
                        state_d = CACHE_LOOKUP;
                    end
                end  
            end

            ACCESS_SRAM: begin
                obi_rsp_o.r.rdata = read_word.data;
                obi_rsp_o.r.rid = obi_aid_q;
                obi_rsp_o.r.r_optional.ecc = read_word.ecc;
                obi_rsp_o.r.r_optional.cap_tag = read_word.cap_tag;
                obi_rsp_o.rvalid = 1;
                state_d = IDLE;
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

    // obi flp flops
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            obi_req_addr_q <= 0;
            obi_aid_q <= 0;
        end
        else begin
            obi_req_addr_q <= obi_req_addr_d;
            obi_aid_q <= obi_aid_d;
        end
        
    end

    // cache meta data flip flops
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            for (int unsigned s = 0; s < NumSets; s++) begin
                for (int unsigned w = 0; w < NumWays; w++) begin
                    cache_meta_q[s][w] <= '0;
                    replace_way_q[s] <= '0;
                end
            end
            selected_way_q <= 0;
            line_record_index_q <= 0;
        end else begin
            cache_meta_q <= cache_meta_d;
            selected_way_q <= selected_way_d;
            replace_way_q <= replace_way_d;
            line_record_index_q <= line_record_index_d;
        end
    end



    for (genvar way = 0; way < NumWays; ++way) begin : gen_sram_ways
        cache_data_sram #(
            .NumWords(SramWordsPerWay),
            .DataWidth(RecordBits),
            .AddrWidth(SramAddrWidth)
        ) i_cache_data_sram (
            .clk_i(clk_i),
            .rst_ni(rst_ni),
            .req_i(sram_req[way]),
            .we_i(sram_we),
            .addr_i(sram_word_addr),
            .wdata_i(sram_wdata),
            .be_i(sram_mask),
            .rdata_o(sram_rdata[way])
        );
    end

    `include "instruction_cache_param_checks.svh"


endmodule
