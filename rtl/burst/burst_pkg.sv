package burst_pkg;

localparam unsigned AddrWidth = 32;
localparam unsigned DataWidth = 32;
localparam unsigned BurstLenWidth = 8; 

typedef struct packed {
  logic [AddrWidth-1:0]     start_addr;
  logic [BurstLenWidth-1:0] blen;   
  logic                     we;     
} burst_hdr_t;


typedef struct packed {
  burst_hdr_t           hdr;
  logic                 hdr_valid;  
  logic [DataWidth-1:0] wdata;
  logic                 wvalid;    
  logic                 rready;     
} burst_req_t;


typedef struct packed {
  logic                 hdr_gnt;    
  logic                 wready;     
  logic [DataWidth-1:0] rdata;
  logic                 rvalid;    
} burst_rsp_t;


endpackage
