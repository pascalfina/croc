
module burst_addr_monitor #(
  parameter string        NAME = "?",
  parameter logic [31:0]  EXP  = '0   // erwartete konstante EP-Fenster-Adresse
) (
  input logic        clk_i,
  input logic        rst_ni,
  input logic        req_i,         // iDMA praesentiert eine Transaktion
  input logic [31:0] xbar_addr_i,   // Adresse auf dem langen Netz (nach Rewrite)
  input logic [31:0] real_addr_i    // echte iDMA-Adresse (vor Rewrite)
);

  logic [31:0] xbar_prev, real_prev;
  longint      xbar_toggles, real_toggles;
  longint      beats;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      xbar_prev    <= EXP;
      real_prev    <= '0;
      xbar_toggles <= '0;
      real_toggles <= '0;
      beats        <= '0;
    end else if (req_i) begin

      if (xbar_addr_i !== EXP)
        $error("[%s] a.addr not constant: %08x (expected %08x)",
               NAME, xbar_addr_i, EXP);

      xbar_toggles <= xbar_toggles + $countones(xbar_addr_i ^ xbar_prev);
      real_toggles <= real_toggles + $countones(real_addr_i ^ real_prev);
      xbar_prev    <= xbar_addr_i;
      real_prev    <= real_addr_i;
      beats        <= beats + 1;
    end
  end

  final begin
    $display("[%s] beats=%0d | addr-toggles =%0d  vs =%0d  -> saved=%0d",
             NAME, beats, xbar_toggles, real_toggles, real_toggles - xbar_toggles);
  end

endmodule


bind croc_domain burst_addr_monitor #(.NAME("ADDR-RD"), .EXP(32'h1100_0000)) i_addr_mon_rd (
  .clk_i       (clk_i),
  .rst_ni      (rst_ni),
  .req_i       (xbar_mgr_obi_req[5].req),
  .xbar_addr_i (xbar_mgr_obi_req[5].a.addr),
  .real_addr_i (idma_obi_read_req.a.addr)
);

bind croc_domain burst_addr_monitor #(.NAME("ADDR-WR"), .EXP(32'h1100_1000)) i_addr_mon_wr (
  .clk_i       (clk_i),
  .rst_ni      (rst_ni),
  .req_i       (xbar_mgr_obi_req[4].req),
  .xbar_addr_i (xbar_mgr_obi_req[4].a.addr),
  .real_addr_i (idma_obi_write_req.a.addr)
);
