module burst_contention_check (
  input logic clk_i,
  input logic rst_ni,
  input logic cpu_req_i,   
  input logic cpu_grant,  
  input logic rd_grant,    
  input logic wr_grant    
);

  longint cpu_req_cyc;     
  longint stall_total;     
  longint stall_by_dma;    
  int     cur_run;        
  int     max_run;         

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cpu_req_cyc  <= '0;
      stall_total  <= '0;
      stall_by_dma <= '0;
      cur_run      <= 0;
      max_run      <= 0;
    end else begin
      if (cpu_req_i)               cpu_req_cyc <= cpu_req_cyc + 1;
      if (cpu_req_i && !cpu_grant) stall_total <= stall_total + 1;

      if (cpu_req_i && !cpu_grant && (rd_grant || wr_grant)) begin
        stall_by_dma <= stall_by_dma + 1;
        cur_run      <= cur_run + 1;
        if (cur_run + 1 > max_run) max_run <= cur_run + 1;
      end else begin
        cur_run <= 0;
      end
    end
  end

  final begin
    $display("contention: cpu_req=%0d cyc, stalled=%0d cyc, stalled-by-DMA=%0d cyc (longest run=%0d)",
             cpu_req_cyc, stall_total, stall_by_dma, max_run);
    if (stall_by_dma == 0)
      $display("cpu was never blocked bei dma)");
    else
      $display("cpu held off for %0d cycles",
               stall_by_dma);
  end

endmodule

bind burst_endpoint_rw burst_contention_check i_contention_check (
  .clk_i     (clk_i),
  .rst_ni    (rst_ni),
  .cpu_req_i (cpu_req_i),
  .cpu_grant (cpu_grant),
  .rd_grant  (rd_grant),
  .wr_grant  (wr_grant)
);
