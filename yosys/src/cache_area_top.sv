`include "cache_typedef.svh"

package cache_area_pkg;
  `CACHE_TYPEDEF_MEM_ALL(
    mem,
    croc_pkg::SbrObiCfg.AddrWidth,
    $clog2(1024 / cache_pkg::CacheRecordDataBytes + 1)
  )
endpackage

module cache_area_top
  import croc_pkg::*;
  import cache_area_pkg::*;
(
  input  logic         clk_i,
  input  logic         rst_ni,
  input  sbr_obi_req_t obi_req_i,
  output sbr_obi_rsp_t obi_rsp_o,
  output mem_req_t     mem_req_o,
  input  mem_rsp_t     mem_rsp_i
);

  localparam int unsigned NumWays        = `CACHE_AREA_WAYS;
  localparam int unsigned NumSets        = `CACHE_AREA_SETS;
  localparam int unsigned LineDataBytes  = `CACHE_AREA_LINE_BYTES;
  localparam int unsigned CacheDataBytes = NumWays * NumSets * LineDataBytes;

  if (`CACHE_AREA_INSTRUCTION) begin : gen_instruction_cache
    instruction_cache #(
      .AddrWidth      ( 32             ),
      .CpuDataWidth   ( 32             ),
      .CacheDataBytes ( CacheDataBytes ),
      .LineDataBytes  ( LineDataBytes  ),
      .NumWays        ( NumWays        ),
      .obi_req_t      ( sbr_obi_req_t  ),
      .obi_rsp_t      ( sbr_obi_rsp_t  ),
      .mem_req_t      ( mem_req_t      ),
      .mem_rsp_t      ( mem_rsp_t      )
    ) i_cache (
      .clk_i,
      .rst_ni,
      .obi_req_i,
      .obi_rsp_o,
      .mem_req_o,
      .mem_rsp_i
    );
  end else begin : gen_data_cache
    data_cache #(
      .AddrWidth          ( 32             ),
      .CpuDataWidth       ( 32             ),
      .CacheDataBytes     ( CacheDataBytes ),
      .LineDataBytes      ( LineDataBytes  ),
      .NumWays            ( NumWays        ),
      .WritebackFifoDepth ( 2              ),
      .obi_req_t          ( sbr_obi_req_t  ),
      .obi_rsp_t          ( sbr_obi_rsp_t  ),
      .mem_req_t          ( mem_req_t      ),
      .mem_rsp_t          ( mem_rsp_t      )
    ) i_cache (
      .clk_i,
      .rst_ni,
      .obi_req_i,
      .obi_rsp_o,
      .mem_req_o,
      .mem_rsp_i
    );
  end

endmodule
