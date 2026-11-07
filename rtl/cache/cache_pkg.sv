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


  function automatic logic [6:0] ecc_merge_partial32(
    input cap_word_t old_word,
    input cap_word_t incoming_word,
    input logic [3:0] byte_enable
);
    logic [31:0] unused_data;
    logic [38:0] encoded_unused;

    for (int i = 0; i < 4; ++i) begin
        unused_data[i*8 +: 8] = byte_enable[i] ? old_word.data[i*8 +: 8] : incoming_word.data[i*8 +: 8];
    end

    encoded_unused = prim_secded_pkg::prim_secded_inv_39_32_enc(unused_data);

    return old_word.ecc ^ incoming_word.ecc ^ encoded_unused[38:32];
endfunction




endpackage
