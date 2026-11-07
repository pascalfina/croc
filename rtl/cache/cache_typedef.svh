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

`endif
