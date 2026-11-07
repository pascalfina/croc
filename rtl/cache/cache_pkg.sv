// SPDX-License-Identifier: SHL-0.51

package cache_pkg;
  localparam int unsigned CacheWordDataBits = 32;
  localparam int unsigned CacheEccBits = 7;

  typedef struct packed {
    logic [CacheEccBits-1:0]      ecc;
    logic                       cap_tag;
    logic [CacheWordDataBits-1:0] data;
  } cap_word_t;

  typedef struct packed {
    cap_word_t upper;
    cap_word_t lower;
  } cap_store_t;

  localparam int unsigned CacheRecordDataBytes = 2 * CacheWordDataBits / 8;
  localparam int unsigned CacheRecordBits = $bits(cap_store_t);
endpackage
