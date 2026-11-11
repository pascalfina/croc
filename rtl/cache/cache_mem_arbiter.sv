`include "cache_typedef.svh"

module cache_mem_arbiter #(
    parameter int unsigned NumPorts      = 2,
    parameter int unsigned AddrWidth     = 32,
    parameter int unsigned HostDataWidth = 32,
    parameter int unsigned WriteBufferBits = 96,

    parameter logic [AddrWidth-1:0] LogicalBaseAddr  = 32'h8000_0000,
    parameter logic [AddrWidth-1:0] PhysicalBaseAddr = 32'h8000_0000,

    parameter type mem_req_t  = logic,
    parameter type mem_rsp_t  = logic,
    parameter type host_req_t = logic,
    parameter type host_rsp_t = logic
) (
    input logic clk_i,
    input logic rst_ni,

    // Connections to the caches
    input  mem_req_t [NumPorts-1:0] cache_req_i,
    output mem_rsp_t [NumPorts-1:0] cache_rsp_o,

    // Connection to the HyperBus midend
    output host_req_t host_req_o,
    input  host_rsp_t host_rsp_i,

    // Connection to the HyperBus configuration frontend
    input  logic drain_i,
    output logic idle_o
);
    localparam int unsigned PortIndexWidth = (NumPorts > 1) ? $clog2(NumPorts) : 1;

    localparam int unsigned RecordCountWidth = $bits(cache_data_q.records);
    localparam longint unsigned MaxRecords = (64'd1 << RecordCountWidth) - 1;
    localparam longint unsigned MaxHostBeats = (MaxRecords * cache_pkg::CacheRecordBits) / HostDataWidth;
    localparam int unsigned HostBeatCountWidth = (MaxHostBeats > 0) ? $clog2(MaxHostBeats + 1) : 1;
    localparam int unsigned HostBeatBytes = HostDataWidth / 8;

    localparam int unsigned HostSize = $clog2(HostBeatBytes); 
    localparam int unsigned WriteBufferCountWidth = $clog2(WriteBufferBits + 1);
    localparam int unsigned WriteBufferIndexWidth = (WriteBufferBits > 1) ? $clog2(WriteBufferBits) : 1;

    if (WriteBufferBits < 96) begin : gen_invalid_write_buffer_bits
        $error("cache_mem_arbiter: WriteBufferBits must be at least 96 for 80-bit records and a 32-bit host.");
    end

    // fsm states signals
    typedef enum logic [3:0]
    {  
        IDLE,
        ISSUE_COMMAND,
        SEND_WRITE,
        RECEIVE_READ,
        WAIT_WRITE_RESPONSE, 
        COMPLETE_READ

    } state_t;

    state_t state_q, state_d;

    logic[PortIndexWidth-1:0] rr_start_port_q, rr_start_port_d;
    logic[PortIndexWidth-1:0] selected_port_q, selected_port_d;

    // 4-state on purpose: a 2-state int gets an implicit init value that
    // conflicts with its constant upper bits in Yosys opt_merge.
    logic [31:0] port;
    logic found_port;

    typedef type(cache_req_i[0].cmd) cache_cmd_t;
    cache_cmd_t cache_data_q, cache_data_d;

    logic [31:0] numb_burst_beats;
    logic [HostBeatCountWidth-1:0] total_host_beats;
    logic [HostBeatCountWidth-1:0] count_beat_d, count_beat_q;

    logic err_r_q, err_r_d;

    logic [AddrWidth-1:0] current_addr;

    `CACHE_TYPEDEF_WRITE_BUFFER_T(write_buffer_t, WriteBufferBits)
    write_buffer_t write_buffer_q, write_buffer_d;



    assign total_host_beats = (cache_data_q.records * cache_pkg::CacheRecordBits) / HostDataWidth;
    
    function automatic logic [AddrWidth-1:0] map_cache_addr_to_hyperram_addr
    (
        input logic [AddrWidth-1:0] cache_line_addr,
        input logic [HostBeatCountWidth-1:0] count_beat
    );

        logic [AddrWidth-1:0] logical_byte_offset;
        logic [AddrWidth-1:0] record_index;
        logic [AddrWidth-1:0] physical_byte_offset;
        logic [AddrWidth-1:0] physical_line_addr;
        logic [AddrWidth-1:0] beat_byte_offset;

        logical_byte_offset = cache_line_addr - LogicalBaseAddr;                //adress offset
        record_index = logical_byte_offset / cache_pkg::CacheRecordDataBytes;   // how many actual records
        physical_byte_offset = record_index * (cache_pkg::CacheRecordBits / 8); // mutl with size of one record 10 bytes in our case
        physical_line_addr = PhysicalBaseAddr + physical_byte_offset;           //physical base address
        beat_byte_offset = AddrWidth'(count_beat) * HostBeatBytes;              //add beat offset 

        return physical_line_addr + beat_byte_offset;
    endfunction


    always_comb begin

        state_d = state_q;

        rr_start_port_d = rr_start_port_q;
        selected_port_d = selected_port_q;

        cache_data_d = cache_data_q;

        count_beat_d = count_beat_q;

        err_r_d = err_r_q;

        found_port = 0;
        port = 0;

        idle_o = 0;

        cache_rsp_o = '0;
        host_req_o = '0;
        current_addr = '0;

        write_buffer_d = write_buffer_q;



        case (state_q)

            IDLE: begin //todo possible optimization drain not over getting first cache entry but annoying to do 
                
                idle_o = 1; // tell hyperbus config that its the right time to update its configuration registers

                if (!drain_i) begin //dont ake new 

                    found_port = 0;

                    for (int offset=0; offset<NumPorts; ++offset) begin

                        port = int'(rr_start_port_q) + offset;

                        if (port >= NumPorts) begin
                            port = port - NumPorts;
                        end

                        if (cache_req_i[port].cmd_valid && !found_port) begin
                            count_beat_d = '0;
                            found_port = 1;
                            selected_port_d = port;
                            cache_rsp_o[port].cmd_ready = 1; // ready receive data from cache
                            cache_data_d = cache_req_i[port].cmd; // save data
                            
                            state_d = ISSUE_COMMAND;
                        end    
                    end   
                end   
            end

            ISSUE_COMMAND: begin

                current_addr = map_cache_addr_to_hyperram_addr(cache_data_q.line_addr, count_beat_q);
                host_req_o.cmd.write = cache_data_q.write;
                host_req_o.cmd.addr = current_addr;
                host_req_o.cmd.beats = total_host_beats;
                host_req_o.cmd_valid = 1;
                host_req_o.cmd.burst = hyperbus_pkg::HyperBurstIncr;
                host_req_o.cmd.atomic_op = hyperbus_pkg::HyperAtomicNone;
                host_req_o.cmd.size = HostSize;

                if (host_req_o.cmd_valid && host_rsp_i.cmd_ready) begin //command received
                    if (cache_data_q.write) begin //write
                        state_d = SEND_WRITE;  
                    end
                    else begin
                        state_d = RECEIVE_READ;
                        err_r_d = 1'b0;
                    end     
                end  
            end

            SEND_WRITE: begin
                if (count_beat_q == total_host_beats) begin
                    state_d = WAIT_WRITE_RESPONSE;
                end
            end

            WAIT_WRITE_RESPONSE: begin
                host_req_o.wrsp_ready = cache_req_i[selected_port_q].done_ready;
                cache_rsp_o[selected_port_q].done_valid = host_rsp_i.wrsp_valid;
                cache_rsp_o[selected_port_q].done.error = (host_rsp_i.wrsp.resp != hyperbus_pkg::HyperRespOkay);
                
               
                if (cache_rsp_o[selected_port_q].done_valid && cache_req_i[selected_port_q].done_ready) begin
                    rr_start_port_d = selected_port_q + 1;
                    state_d = IDLE;
                end
            end

            RECEIVE_READ: begin
           
                if (write_buffer_q.valid_bits <= WriteBufferCountWidth'(WriteBufferBits - HostDataWidth)) begin //buffer still has space

                    host_req_o.r_ready = 1'b1;

                    if (host_rsp_i.r_valid && host_req_o.r_ready) begin // cache has data for us

                        count_beat_d = count_beat_q + 1'b1;
                        write_buffer_d.data[WriteBufferIndexWidth'(write_buffer_q.valid_bits) +: HostDataWidth] = host_rsp_i.r.data;
                        write_buffer_d.valid_bits = write_buffer_q.valid_bits + WriteBufferCountWidth'(HostDataWidth); // update valid bits
                        err_r_d = err_r_q | (host_rsp_i.r.resp != hyperbus_pkg::HyperRespOkay);
                    end  
                end

                if (write_buffer_d.valid_bits >= cache_pkg::CacheRecordBits) begin //we have bits to send to cache

                    cache_rsp_o[selected_port_q].r.record = write_buffer_d.data[cache_pkg::CacheRecordBits-1:0];
                    cache_rsp_o[selected_port_q].r_valid = 1;
                    cache_rsp_o[selected_port_q].r.last = (count_beat_d == total_host_beats) && (write_buffer_d.valid_bits == WriteBufferCountWidth'(cache_pkg::CacheRecordBits)); //check if its last 80 bit message
                    
                    if (cache_rsp_o[selected_port_q].r_valid && cache_req_i[selected_port_q].r_ready) begin
                        write_buffer_d.data = write_buffer_d.data >> cache_pkg::CacheRecordBits;
                        write_buffer_d.valid_bits = write_buffer_d.valid_bits - WriteBufferCountWidth'(cache_pkg::CacheRecordBits);

                        if (cache_rsp_o[selected_port_q].r.last) begin
                            state_d = COMPLETE_READ;
                        end
                    end
                    
                end
            end

            COMPLETE_READ: begin
                cache_rsp_o[selected_port_q].done_valid = 1;
                cache_rsp_o[selected_port_q].done.error = err_r_q;

                if (cache_rsp_o[selected_port_q].done_valid && cache_req_i[selected_port_q].done_ready) begin
                    rr_start_port_d = selected_port_q + 1;
                    state_d = IDLE;
                end
            end

            default: begin
                state_d = IDLE;
            end
        endcase

        if (cache_data_q.write && ((state_q == SEND_WRITE) || (state_q == ISSUE_COMMAND && host_req_o.cmd_valid && host_rsp_i.cmd_ready))) begin

            if (write_buffer_q.valid_bits <= WriteBufferCountWidth'(WriteBufferBits - cache_pkg::CacheRecordBits)) begin

                cache_rsp_o[selected_port_q].w_ready = 1; // ready to recieve new data from cache
                
                if (cache_req_i[selected_port_q].w_valid) begin // cache has data for us
                    write_buffer_d.data[WriteBufferIndexWidth'(write_buffer_q.valid_bits) +: cache_pkg::CacheRecordBits] = cache_req_i[selected_port_q].w.record;
                    write_buffer_d.strb[WriteBufferIndexWidth'(write_buffer_q.valid_bits / 8) +: cache_pkg::CacheRecordBits/8] = cache_req_i[selected_port_q].w_strb;
                    write_buffer_d.valid_bits = write_buffer_q.valid_bits + WriteBufferCountWidth'(cache_pkg::CacheRecordBits); // update valid bits
                end  
            end

            if (write_buffer_d.valid_bits >= WriteBufferCountWidth'(HostDataWidth)) begin

                host_req_o.w_valid = 1'b1;
                host_req_o.w.data = write_buffer_d.data[HostDataWidth-1:0];
                host_req_o.w.strb = write_buffer_d.strb[HostBeatBytes-1:0];
                host_req_o.w.last = (count_beat_q == total_host_beats - 1'b1);

                if (host_rsp_i.w_ready) begin
                    write_buffer_d.data = write_buffer_d.data >> HostDataWidth;
                    write_buffer_d.strb = write_buffer_d.strb >> HostBeatBytes;
                    write_buffer_d.valid_bits = write_buffer_d.valid_bits - WriteBufferCountWidth'(HostDataWidth);
                    count_beat_d = count_beat_q + 1'b1;
                end  
            end
        end
        
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <= IDLE;
            rr_start_port_q <= 0;
            selected_port_q <= 0;
            cache_data_q <= '0;
            count_beat_q <= 0;
            err_r_q <= 0;
        end
        else begin
            state_q <= state_d;
            rr_start_port_q <= rr_start_port_d;
            selected_port_q <= selected_port_d;
            cache_data_q <= cache_data_d;
            count_beat_q <= count_beat_d;
            err_r_q <= err_r_d;
        end
        
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            write_buffer_q <= '0; 
        end
        else begin
            write_buffer_q <= write_buffer_d;
        end

    end

`ifndef SYNTHESIS
    // synthesis translate_off
    // Coverage counters, reported at the end of simulation: operations per
    // port, operations accepted while another port was also requesting, cycles
    // a port's command waited, and consecutive operations of different ports.
    int unsigned cov_ops [NumPorts];
    int unsigned cov_ops_contended [NumPorts];
    int unsigned cov_wait_cycles [NumPorts];
    int unsigned cov_handovers;
    logic [PortIndexWidth-1:0] cov_last_port_q;
    logic                      cov_seen_op_q;

    always @(posedge clk_i) begin
        if (rst_ni) begin
            for (int p = 0; p < NumPorts; p++) begin
                if (cache_req_i[p].cmd_valid && !cache_rsp_o[p].cmd_ready) cov_wait_cycles[p]++;
            end

            if (state_q == IDLE && found_port) begin
                cov_ops[selected_port_d]++;
                for (int p = 0; p < NumPorts; p++) begin
                    if (p != int'(selected_port_d) && cache_req_i[p].cmd_valid) begin
                        cov_ops_contended[selected_port_d]++;
                        break;
                    end
                end
                if (cov_seen_op_q && cov_last_port_q != selected_port_d) cov_handovers++;
                cov_last_port_q <= selected_port_d;
                cov_seen_op_q   <= 1'b1;
            end
        end else begin
            cov_seen_op_q <= 1'b0;
        end
    end

    final begin
        for (int p = 0; p < NumPorts; p++) begin
            $display("[CACHE-COV] %m: port %0d: %0d operations, %0d accepted while another port requested, %0d wait cycles",
                     p, cov_ops[p], cov_ops_contended[p], cov_wait_cycles[p]);
        end
        $display("[CACHE-COV] %m: %0d handovers between different ports", cov_handovers);
    end
    // synthesis translate_on
`endif

endmodule
