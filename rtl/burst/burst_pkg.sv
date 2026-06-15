package burst_pkg;

localparam unsigned AddrWidth = 32;
localparam unsigned DataWidth = 32;
localparam unsigned BurstLenWidth = 8; 

typedef struct packed {
  logic [AddrWidth-1:0]     start_addr;
  logic [BurstLenWidth-1:0] blen;   // Beats - 1
  logic                     we;     // 1=write, 0=read
} burst_hdr_t;

// Manager (iDMA) → Subordinate (Endpoint)
typedef struct packed {
  burst_hdr_t           hdr;
  logic                 hdr_valid;  
  logic [DataWidth-1:0] wdata;
  logic                 wvalid;     // Write-Datum gültig
  logic                 rready;     // bereit, Read-Datum abzunehmen
} burst_req_t;

// Subordinate (Endpoint) → Manager (iDMA)
typedef struct packed {
  logic                 hdr_gnt;    // Header akzeptiert (= Burst-Start + Lock)
  logic                 wready;     // Write-Datum akzeptiert (Backpressure)
  logic [DataWidth-1:0] rdata;
  logic                 rvalid;     // Read-Datum gültig
} burst_rsp_t;


endpackage
