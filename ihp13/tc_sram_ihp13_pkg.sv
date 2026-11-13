package tc_sram_ihp13_pkg;

  localparam int unsigned RecordBits  = 80;
  localparam int unsigned SegmentUnit = 256;
  localparam int unsigned MaxUnits    = 64;
  localparam int unsigned NumLayouts  = 4;
  localparam int unsigned LayoutLoBits [NumLayouts] = '{64, 64, 64, 48};
  localparam int unsigned LayoutHiPack [NumLayouts] = '{ 4,  2,  3,  1};

  localparam int unsigned Area64x64   = 50489;
  localparam int unsigned Area256x64  = 93181;
  localparam int unsigned Area512x64  = 150102;
  localparam int unsigned Area1024x64 = 263946;
  localparam int unsigned Area2048x64 = 491634;
  localparam int unsigned Area256x48  = 70850;
  localparam int unsigned Area512x32  = 79720;
  localparam int unsigned NoFit       = 32'h7fff_ffff;

  typedef logic [MaxUnits-1:0][$clog2(MaxUnits+1)-1:0] segment_plan_t;

  function automatic int unsigned macro_words(int unsigned width, int unsigned words);
    if (width == 48)    return 256;
    if (width == 32)    return 512;
    if (words >= 2048)  return 2048;
    if (words >= 1024)  return 1024;
    if (words >=  512)  return 512;
    if (words >=  256)  return 256;
    return 64;
  endfunction

  function automatic int unsigned tile_base(int unsigned width, int unsigned words, int unsigned tile);
    tile_base = 0;
    for (int unsigned t = 0; t < tile; t++) begin
      tile_base += macro_words(width, words - tile_base);
    end
  endfunction

  function automatic int unsigned num_tiles(int unsigned width, int unsigned words);
    num_tiles = 0;
    for (int unsigned base = 0; base < words; base += macro_words(width, words - base)) begin
      num_tiles++;
    end
  endfunction

  function automatic int unsigned column_area(int unsigned records, int unsigned bits,
                                              int unsigned pack);
    int unsigned words = records / pack;
    if (records % pack != 0) return NoFit;
    case (bits * pack)
      48:      return (words % 256 != 0) ? NoFit : words / 256 * Area256x48;
      32:      return (words % 512 != 0) ? NoFit : words / 512 * Area512x32;
      default: return (words %  64 != 0) ? NoFit :
                      words / 2048 * Area2048x64 + words % 2048 / 1024 * Area1024x64 +
                      words % 1024 / 512 * Area512x64 + words % 512 / 256 * Area256x64 +
                      words % 256 / 64 * Area64x64;
    endcase
  endfunction

  function automatic int unsigned layout_area(int unsigned records, int unsigned layout);
    return column_area(records, LayoutLoBits[layout], 1)
         + column_area(records, RecordBits - LayoutLoBits[layout], LayoutHiPack[layout]);
  endfunction

  function automatic int unsigned best_layout(int unsigned records);
    int unsigned best_area = '1;
    best_layout = 0;
    for (int unsigned l = 0; l < NumLayouts; l++) begin
      int unsigned area = layout_area(records, l);
      if (area < best_area) begin
        best_area   = area;
        best_layout = l;
      end
    end
  endfunction

  function automatic segment_plan_t segment_plan(int unsigned records);
    int unsigned units = records / SegmentUnit;
    int unsigned area  [MaxUnits+1];
    int unsigned cost  [MaxUnits+1];
    int unsigned first [MaxUnits+1];
    for (int unsigned u = 1; u <= units; u++) begin
      area[u] = layout_area(u * SegmentUnit, best_layout(u * SegmentUnit));
    end
    cost[0] = 0;
    for (int unsigned u = 1; u <= units; u++) begin
      cost[u] = '1;
      for (int unsigned k = u; k >= 1; k--) begin
        if (area[k] + cost[u - k] < cost[u]) begin
          cost[u]  = area[k] + cost[u - k];
          first[u] = k;
        end
      end
    end
    segment_plan = '0;
    for (int unsigned s = 0; units > 0; s++) begin
      segment_plan[s] = first[units];
      units          -= first[units];
    end
  endfunction

  function automatic int unsigned num_segments(segment_plan_t plan);
    num_segments = 0;
    while (num_segments < MaxUnits && plan[num_segments] != 0) num_segments++;
  endfunction

  function automatic int unsigned segment_base(segment_plan_t plan, int unsigned segment);
    segment_base = 0;
    for (int unsigned s = 0; s < segment; s++) begin
      segment_base += plan[s] * SegmentUnit;
    end
  endfunction

endpackage
