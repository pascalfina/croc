
module jtag_hyperram_adapter #(
    parameter int unsigned AddrWidth      = 32,
    parameter int unsigned ObiDataWidth   = 32,
    parameter int unsigned BlockDataBytes = 16,

    parameter type obi_req_t = logic,
    parameter type obi_rsp_t = logic,
    parameter type mem_req_t = logic,
    parameter type mem_rsp_t = logic
) (
    input  logic clk_i,
    input  logic rst_ni,

    // OBI connection to the crossbar.
    input  obi_req_t obi_req_i,
    output obi_rsp_t obi_rsp_o,

    // Record transfers to the HyperRAM arbiter.
    output mem_req_t mem_req_o,
    input  mem_rsp_t mem_rsp_i
);

    localparam int unsigned WordsPerBlock = BlockDataBytes / (ObiDataWidth / 8);
    localparam int unsigned BlockOffsetBits = $clog2(BlockDataBytes);
    localparam int unsigned WordOffsetBits  = $clog2(ObiDataWidth / 8);
    localparam int unsigned WordIndexWidth  = (WordsPerBlock > 1) ? $clog2(WordsPerBlock) : 1;

    localparam int unsigned RecordsPerBlock = BlockDataBytes / cache_pkg::CacheRecordDataBytes;
    localparam int unsigned RecordIndexWidth = (RecordsPerBlock > 1) ? $clog2(RecordsPerBlock) : 1;
    localparam int unsigned RecordCountWidth = $bits(mem_req_o.cmd.records);

    localparam int unsigned StoredWordBytes = $bits(cache_pkg::cap_word_t) / 8;
    

    typedef struct packed {
        logic [AddrWidth-1:0]                      base_addr;
        logic [WordsPerBlock-1:0]                  word_valid;
        cache_pkg::cap_word_t [WordsPerBlock-1:0]   words;
    } jtag_write_buffer_t;

    jtag_write_buffer_t write_buffer_q, write_buffer_d;

    

    typedef enum logic [3:0]
    {  
        IDLE,
        BUFFER_WRITE,
        RESPOND,
        SEND_WRITE_CMD,
        SEND_WRITE_DATA,
        WAIT_WRITE_DONE,
        SEND_READ_CMD,
        WAIT_READ_DATA,
        WAIT_READ_DONE

    } state_t;

    state_t state_q, state_d;

    // obi signals
    typedef type(obi_req_i.a) obi_a_t;
    obi_a_t obi_a_q, obi_a_d;

    logic [AddrWidth-1:0]      block_addr;
    logic [WordIndexWidth-1:0] word_index;

    logic [39:0] encoded_word;
    logic [ObiDataWidth-1:0] merged_data;
    logic error_q, error_d;

    logic [RecordIndexWidth-1:0] write_record_index_q, write_record_index_d;


    assign block_addr = {obi_a_q.addr[AddrWidth-1:BlockOffsetBits],{BlockOffsetBits{1'b0}}};
    assign word_index = WordIndexWidth'(obi_a_q.addr[BlockOffsetBits-1:0] >> WordOffsetBits);

    always_comb begin
        merged_data = write_buffer_q.words[word_index].data;
        for (int byte_idx = 0; byte_idx < ObiDataWidth / 8; byte_idx++) begin
            if (obi_a_q.be[byte_idx]) begin
                merged_data[byte_idx*8 +: 8] = obi_a_q.wdata[byte_idx*8 +: 8];
            end
        end
    end

    assign encoded_word = ibex_mem_ecc_pkg::mem_ecc_encode(merged_data, 1'b0);


    always_comb begin

        state_d = state_q;

        obi_a_d   = obi_a_q;
        write_buffer_d = write_buffer_q;
        obi_rsp_o = '0;
        mem_req_o = '0;

        write_record_index_d = write_record_index_q;
        error_d = error_q;

        case (state_q)

            IDLE: begin
                obi_rsp_o.gnt = 1'b1;

                if (obi_req_i.req && obi_rsp_o.gnt) begin
                    obi_a_d = obi_req_i.a;
                    error_d = 1'b0;
                    state_d = BUFFER_WRITE; 
                end
            end


            BUFFER_WRITE: begin
                if (!obi_a_q.we) begin
                    // reads drain posted writes before accessing backing memory.
                    state_d = (write_buffer_q.word_valid != '0) ? SEND_WRITE_CMD : SEND_READ_CMD;
                end
                else if (obi_a_q.be == '0 ||
                         (obi_a_q.be == '1 && obi_a_q.addr[WordOffsetBits-1:0] != '0)) begin
                    error_d = 1'b1;
                    state_d = RESPOND;
                end
                else if ((write_buffer_q.word_valid != '0) &&
                    (write_buffer_q.base_addr != block_addr)) begin

                    state_d = SEND_WRITE_CMD; // got address that is not part of the block 

                end 
                else begin
                    write_buffer_d.base_addr = block_addr;

                    if (obi_a_q.be != '1 && !write_buffer_q.word_valid[word_index]) begin
                        state_d = SEND_READ_CMD;
                    end else begin
                        write_buffer_d.words[word_index].data    = merged_data;
                        write_buffer_d.words[word_index].cap_tag = 1'b0;
                        write_buffer_d.words[word_index].ecc     = encoded_word[39:33];

                        write_buffer_d.word_valid[word_index] = 1'b1;

                        if (write_buffer_d.word_valid == '1) begin
                            state_d = SEND_WRITE_CMD; //received the whole buffer
                        end else begin
                            state_d = RESPOND; //tell jtag we are ready for the next data
                        end
                    end
                end
            end

            RESPOND: begin
                obi_rsp_o.rvalid = 1'b1;
                obi_rsp_o.r.rid = obi_a_q.aid;
                obi_rsp_o.r.rdata = '0;
                obi_rsp_o.r.err = error_q;
                obi_rsp_o.r.r_optional.ecc = ibex_mem_ecc_pkg::MemEccZeroEcc;

                if (!obi_a_q.we && !error_q) begin
                    obi_rsp_o.r.rdata = write_buffer_q.words[word_index].data;
                    obi_rsp_o.r.r_optional.ecc = write_buffer_q.words[word_index].ecc;
                    obi_rsp_o.r.r_optional.cap_tag = write_buffer_q.words[word_index].cap_tag;
                end

                state_d = IDLE;
            end

            SEND_WRITE_CMD: begin
                mem_req_o.cmd.write = 1;
                mem_req_o.cmd.line_addr = write_buffer_q.base_addr;
                mem_req_o.cmd.records = RecordCountWidth'(RecordsPerBlock);
                mem_req_o.cmd_valid = 1;

                if (mem_rsp_i.cmd_ready && mem_req_o.cmd_valid) begin
                    write_record_index_d = 0;
                    state_d = SEND_WRITE_DATA;
                end  
            end

            SEND_WRITE_DATA: begin

                mem_req_o.w.record = {
                    write_buffer_q.words[2 * write_record_index_q + 1],
                    write_buffer_q.words[2 * write_record_index_q]
                };
                mem_req_o.w_strb = {
                    {StoredWordBytes{write_buffer_q.word_valid[2 * write_record_index_q + 1]}},
                    {StoredWordBytes{write_buffer_q.word_valid[2 * write_record_index_q]}}
                    }; // retharded but at least compatible

                if (write_record_index_q == RecordIndexWidth'(RecordsPerBlock - 1)) begin
                    mem_req_o.w.last = 1;
                end

                mem_req_o.w_valid = 1;

                if (mem_rsp_i.w_ready && mem_req_o.w_valid) begin
                    if (write_record_index_q != RecordIndexWidth'(RecordsPerBlock - 1)) begin
                        write_record_index_d = write_record_index_q + 1'b1;
                    end
                    else begin
                        state_d = WAIT_WRITE_DONE;
                    end
                end
            end

            WAIT_WRITE_DONE: begin
                mem_req_o.done_ready = 1;

                if (mem_rsp_i.done_valid && mem_req_o.done_ready) begin
                    error_d = mem_rsp_i.done.error;
                    if (mem_rsp_i.done.error) begin
                        state_d = RESPOND;
                    end else begin
                        write_buffer_d.word_valid = '0;
                        if (!obi_a_q.we) begin
                            state_d = SEND_READ_CMD;
                        end 
                        else if (block_addr == write_buffer_q.base_addr) begin
                            // case 1 the buffer was filled and we still need to repsond to jtag for
                            // the last word we received

                            state_d = RESPOND;
                        end 
                        else begin
                            /* case 2 the buffer was not full but the last address from jtag was
                             not part of the current block so we neede to stop filling the buffer
                             and write the current buffer to the hyperram so we can use the buffer for
                             the next block so we go to buffer write
                             */
                            state_d = BUFFER_WRITE;
                        end
                    end
                    
                end
            end

            SEND_READ_CMD: begin
                mem_req_o.cmd.write = 1'b0;
                mem_req_o.cmd.line_addr = block_addr;
                mem_req_o.cmd.records = RecordCountWidth'(RecordsPerBlock);
                mem_req_o.cmd_valid = 1'b1;

                if (mem_req_o.cmd_valid && mem_rsp_i.cmd_ready) begin
                    write_buffer_d.base_addr = block_addr;
                    write_record_index_d = '0;
                    state_d = WAIT_READ_DATA;
                end
            end

            WAIT_READ_DATA: begin
                mem_req_o.r_ready = 1'b1;
                if (mem_rsp_i.r_valid && mem_req_o.r_ready) begin
                    if (int'(write_record_index_q) == int'(word_index) / 2) begin
                        write_buffer_d.words[word_index] = word_index[0]
                            ? mem_rsp_i.r.record.upper : mem_rsp_i.r.record.lower;
                    end
                    if (write_record_index_q == RecordIndexWidth'(RecordsPerBlock - 1)) begin
                        state_d = WAIT_READ_DONE;
                    end else begin
                        write_record_index_d = write_record_index_q + 1'b1;
                    end
                end
            end

            WAIT_READ_DONE: begin
                mem_req_o.done_ready = 1'b1;
                if (mem_rsp_i.done_valid && mem_req_o.done_ready) begin
                    error_d = mem_rsp_i.done.error;
                    if (mem_rsp_i.done.error || !obi_a_q.we) begin
                        state_d = RESPOND;
                    end else begin
                        // The old word is available for the pending partial write.
                        write_buffer_d.word_valid[word_index] = 1'b1;
                        state_d = BUFFER_WRITE;
                    end
                end
            end
                        
            default: begin
                state_d = IDLE;
            end
        endcase
    end


    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <= IDLE;
            write_buffer_q <= '0;
            write_record_index_q <= 0;
            error_q <= 1'b0;
        end else begin
            state_q <= state_d;
            write_buffer_q <= write_buffer_d;
            write_record_index_q <= write_record_index_d;
            error_q <= error_d;
        end  
    end

     always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            obi_a_q <= '0;
        end else begin
            obi_a_q <= obi_a_d;
        end  
    end

    `include "jtag_hyperram_adapter_param_checks.svh"

endmodule
