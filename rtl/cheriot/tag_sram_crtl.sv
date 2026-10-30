

module tag_sram_crtl #(
    parameter logic [31:0] DataBaseAddr = 32'h8000_0000,
    parameter int unsigned DataSizeBytes = 2 * 1024 * 1024,
    parameter int unsigned DataAddrWidth = 32,
    parameter int unsigned DataWordWidth = 32,
    parameter int unsigned TagSramDataWidth = 32,
    parameter int unsigned TagSramNumWords = 32768,
    parameter int unsigned SramReadLatency = 1
) (
    input logic clk_i,
    input logic rst_ni,

    // signals from hyperbus frontend
    input logic access_i,
    input logic write_tag_i,
    input logic [31:0] addr_i,
    input logic we_i,
    input logic data_done_i,
    input logic data_error_i,
    //

    output logic ready_o,
    output logic read_tag_o,
    output logic read_tag_valid_o,
    output logic tag_error_o, 

    output logic tag_ready_o, //tell hyperbus we are ready

    output logic tag_sram_req_o,
    output logic tag_sram_we_o,
    output logic [31:0] tag_sram_addr_o,
    output logic [31:0] tag_sram_wdata_o,
    output logic [3:0] tag_sram_be_o,
    input logic [31:0] tag_sram_rdata_i
);


    typedef enum logic [2:0] {
        INIT,
        IDLE,
        READ_TAG, 
        WAIT_TAG, 
        WAIT_DATA,
        WRITE_TAG,
        DONE
    } state_t;

    state_t state_q, state_d;
    logic [31:0] init_addr_q, init_addr_d;

    logic [31:0] frontend_addr_q, frontend_addr_d;
    logic frontend_we_q, frontend_we_d;
    logic frontend_tag_q, frontend_tag_d;

    logic err_q, err_d;

    logic frontend_done_q, frontend_done_d;
    logic frontend_error_q, frontend_error_d;

    logic [31:0] sram_tag_word_q,sram_tag_word_d;


    logic [31:0] tag_word_index;
    logic [31:0] tag_bit_index;

    logic write_tag;
    logic [$clog2(TagSramNumWords)-1:0] sram_addr;
    logic [31:0] sram_wdata;



    assign tag_word_index = (frontend_addr_q - DataBaseAddr) >> 7;
    assign tag_bit_index = ((frontend_addr_q - DataBaseAddr) >> 2) & 31;

    //assign tag_sram_req_o = write_tag;


    assign tag_sram_addr_o = sram_addr;
    assign tag_sram_wdata_o = sram_wdata;

    always_comb begin
        state_d = state_q;
        init_addr_d = init_addr_q;

        ready_o = 0;
        read_tag_valid_o = 0;
        tag_sram_req_o = 0;
        tag_sram_we_o = 0;

        frontend_addr_d = frontend_addr_q;
        frontend_we_d = frontend_we_q;
        frontend_tag_d = frontend_tag_q;

        err_d = err_q;

        frontend_done_d = frontend_done_q;
        frontend_error_d =  frontend_error_q;

        sram_tag_word_d = sram_tag_word_q;
        tag_ready_o = 0;

        tag_sram_we_o = 0;

        sram_addr = tag_word_index;
        sram_wdata = sram_tag_word_q;

        read_tag_o = 0;
        tag_error_o = 0;
        tag_sram_be_o = 0;

        case (state_q)

            INIT: begin //set all tags to 0 in sram

                //write_tag = 0;
                tag_sram_req_o = 1;
                sram_addr = init_addr_q;
                sram_wdata = 32'b0;
                tag_sram_be_o = '1;
                tag_sram_we_o = 1;

                init_addr_d = init_addr_q + 1;

                if (init_addr_q == TagSramNumWords -1) begin
                    state_d = IDLE;
                end
            end

            IDLE: begin
                ready_o = 1;
                err_d = 0;
                tag_ready_o = 1;

                if (access_i) begin // frontend writing to hyperram
                    frontend_addr_d = addr_i;
                    frontend_we_d = we_i;
                    frontend_tag_d = write_tag_i;
                    state_d = READ_TAG;
                end
        
            end

            READ_TAG: begin
                tag_sram_req_o = 1;
                tag_sram_we_o = 0;
                //sram_addr = tag_word_index; 
                state_d = WAIT_TAG;  
            end

            WAIT_TAG: begin // read data valid because of sram latency of  cycle after request

                if (frontend_we_q) begin //frontend wants to write tag
                    sram_tag_word_d = tag_sram_rdata_i;
                    state_d = WAIT_DATA;
                end

                else begin // frontend wants to read tag from sram
                    read_tag_o = tag_sram_rdata_i[tag_bit_index];
                    read_tag_valid_o = 1;
                    state_d = DONE;
                end
            end

            WAIT_DATA: begin
                if (data_done_i) begin  // wait until hyperram transaction is finished 
                    if (data_error_i) begin // hyperram store did not succeed
                        err_d = 1;
                        state_d = DONE;
                    end
                    else begin //store successful
                        sram_tag_word_d[tag_bit_index] = frontend_tag_q; //write at correct position
                        state_d = WRITE_TAG;  
                    end
                end
            end

            WRITE_TAG: begin
                tag_sram_req_o = 1;
                tag_sram_we_o = 1; //write
                //sram_addr = tag_word_index;
                sram_wdata = sram_tag_word_q;
                tag_sram_be_o = 4'b1111;
                state_d = DONE; // sram store happens in the same cycle
            
            end

            DONE: begin
                tag_ready_o = 1; //tell hyperbus we stored the tag
                tag_error_o = err_q;
                state_d = IDLE;
            end

            default: begin
                state_d = IDLE;
            end
        endcase
        
    end


    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <= INIT;
            init_addr_q <= 0;
            frontend_addr_q <= 0;
            frontend_we_q <= 0;
            frontend_tag_q <= 0;
            sram_tag_word_q <= 0;
            err_q <= 0;
            frontend_done_q <= 0;
            frontend_error_q <= 0;
        end
        else begin
            state_q <= state_d;
            init_addr_q <= init_addr_d;
            frontend_addr_q <= frontend_addr_d;
            frontend_we_q <= frontend_we_d;
            frontend_tag_q <= frontend_tag_d;
            sram_tag_word_q <= sram_tag_word_d;
            err_q <= err_d;
            frontend_done_q <= frontend_done_d;
            frontend_error_q <=  frontend_error_d;
        end
    end
        
endmodule