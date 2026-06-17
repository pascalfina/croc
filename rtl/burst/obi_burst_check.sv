// Burst-Marker-Monitor fuer M1-Schicht 4.
// Prueft an einem iDMA-OBI-Manager-Port, dass bfirst/blast/blen/addr konsistent sind:
//   - bfirst nur beim ersten Beat eines Bursts (sonst Fehler)
//   - addr += 4 pro Beat
//   - blast genau beim Beat mit Index == blen
//   - single-beat (blast schon beim bfirst) => blen muss 0 sein
//
// Wird per `bind` an croc_domain gehaengt (kein RTL-Change) und laeuft in der
// vollen Croc-Sim (z.B. test_idma) mit. Siehe bind-Statements am Dateiende.

module obi_burst_check import croc_pkg::*; #(
  parameter string NAME = "?"
) (
  input logic         clk_i,
  input logic         rst_ni,
  input mgr_obi_req_t req_i,
  input mgr_obi_rsp_t rsp_i
);

  logic [31:0] start_a;     // Start-Adresse des laufenden Bursts
  logic [7:0]  exp_blen;    // beim bfirst gemeldetes blen
  int          cnt;         // Index des naechsten erwarteten Beats
  logic        active;      // Burst laeuft (zwischen bfirst und blast)

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      active <= 1'b0;
      cnt    <= 0;
    end else if (req_i.req && rsp_i.gnt) begin   // ein Beat akzeptiert
      if (req_i.a.a_optional.bfirst) begin
        // ── erster Beat ──
        start_a  <= req_i.a.addr;
        exp_blen <= req_i.a.a_optional.blen;
        cnt      <= 1;
        active   <= !req_i.a.a_optional.blast;    // single-beat? dann gleich fertig
        if (req_i.a.a_optional.blast && req_i.a.a_optional.blen != 0)
          $error("[%s] single-beat (blast@bfirst) aber blen=%0d (erwartet 0)",
                 NAME, req_i.a.a_optional.blen);
      end else if (active) begin
        // ── Folge-Beat ──
        if (req_i.a.addr !== start_a + (cnt << 2))
          $error("[%s] addr-increment falsch: %08x, erwartet %08x (beat %0d)",
                 NAME, req_i.a.addr, start_a + (cnt << 2), cnt);
        if (req_i.a.a_optional.blast) begin
          if (cnt != exp_blen)
            $error("[%s] blast bei beat-index %0d, aber blen war %0d",
                   NAME, cnt, exp_blen);
          else
            $display("[%s] burst OK: %0d beats ab %08x (blen=%0d)",
                     NAME, cnt + 1, start_a, exp_blen);
          active <= 1'b0;
        end
        cnt <= cnt + 1;
      end else begin
        // ── Beat ohne aktiven Burst und ohne bfirst => Marker fehlt ──
        $error("[%s] beat ohne bfirst und ohne laufenden Burst (addr %08x)",
               NAME, req_i.a.addr);
      end
    end
  end

endmodule

// ──────────────────────────────────────────────────────────────────────────
// An beide iDMA-Ports in croc_domain binden (kein Eingriff in croc_domain.sv).
// Greift auf die internen Signale idma_obi_read_req/_rsp + idma_obi_write_req/_rsp zu.
// ──────────────────────────────────────────────────────────────────────────
bind croc_domain obi_burst_check #(.NAME("iDMA-RD")) i_burst_check_rd (
  .clk_i  (clk_i),
  .rst_ni (rst_ni),
  .req_i  (idma_obi_read_req),
  .rsp_i  (idma_obi_read_rsp)
);

bind croc_domain obi_burst_check #(.NAME("iDMA-WR")) i_burst_check_wr (
  .clk_i  (clk_i),
  .rst_ni (rst_ni),
  .req_i  (idma_obi_write_req),
  .rsp_i  (idma_obi_write_rsp)
);
