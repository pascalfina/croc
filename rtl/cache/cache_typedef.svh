// SPDX-License-Identifier: SHL-0.51

`ifndef CROC_CACHE_TYPEDEF_SVH
`define CROC_CACHE_TYPEDEF_SVH

// The cache address-tag width depends on the cache instance's geometry.
`define CACHE_TYPEDEF_META_T(type_name, tag_width) \
  typedef struct packed {                        \
    logic [(tag_width)-1:0] addr_tag;             \
    logic                  valid;                \
    logic                  dirty;                \
  } type_name;

`define CACHE_TYPEDEF_WRITE_BUFFER_T(type_name, buffer_bits) \
  typedef struct packed {                                  \
    logic [(buffer_bits)-1:0] data;                        \
    logic [$clog2((buffer_bits)+1)-1:0] valid_bits;         \
  } type_name;

`define CACHE_TYPEDEF_MEM_CMD_T(type_name, addr_width, record_count_width) \
  typedef struct packed {                                               \
    logic                            write;                             \
    logic [(addr_width)-1:0]          line_addr;                         \
    logic [(record_count_width)-1:0] records;                           \
  } type_name;

// Cache outputs, including readiness for refill data and completion.
`define CACHE_TYPEDEF_MEM_REQ_T(type_name, cmd_type) \
  typedef struct packed {                          \
    cmd_type                     cmd;              \
    logic                        cmd_valid;        \
    cache_pkg::cache_mem_data_t   w;                \
    logic                        w_valid;          \
    logic                        r_ready;          \
    logic                        done_ready;       \
  } type_name;

// Arbiter outputs, including readiness for commands and write-back data.
`define CACHE_TYPEDEF_MEM_RSP_T(type_name)          \
  typedef struct packed {                         \
    logic                       cmd_ready;        \
    logic                       w_ready;          \
    cache_pkg::cache_mem_data_t  r;                \
    logic                       r_valid;          \
    cache_pkg::cache_mem_done_t  done;             \
    logic                       done_valid;       \
  } type_name;

`define CACHE_TYPEDEF_MEM_ALL(name, addr_width, record_count_width) \
  `CACHE_TYPEDEF_MEM_CMD_T(name``_cmd_t, addr_width, record_count_width) \
  `CACHE_TYPEDEF_MEM_REQ_T(name``_req_t, name``_cmd_t) \
  `CACHE_TYPEDEF_MEM_RSP_T(name``_rsp_t)

`endif
