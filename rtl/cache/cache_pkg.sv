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

  typedef struct packed {
    cap_store_t record;
    logic       last; // Last record of the complete line, not of a host burst.
  } cache_mem_data_t;

  typedef struct packed {
    logic error;
  } cache_mem_done_t;


  function automatic logic [6:0] ecc_merge_partial32(input cap_word_t old_word,input cap_word_t incoming_word,input logic [3:0] byte_enable);
    logic [31:0] unused_data;
    logic [39:0] encoded_unused;

    for (int i = 0; i < 4; ++i) begin
        unused_data[i*8 +: 8] = byte_enable[i] ? old_word.data[i*8 +: 8] : incoming_word.data[i*8 +: 8];
    end

    // The result takes the incoming tag, so the unused term takes the old tag.
    encoded_unused = ibex_mem_ecc_pkg::mem_ecc_encode(unused_data, old_word.cap_tag);

    return old_word.ecc ^ incoming_word.ecc ^ encoded_unused[39:33];
endfunction




endpackage
