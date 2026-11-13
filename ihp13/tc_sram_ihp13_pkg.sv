package tc_sram_ihp13_pkg;

  localparam int unsigned RecordBits  = 80;
  localparam int unsigned SegmentUnit = 256;
  localparam int unsigned MaxUnits    = 64;
  localparam int unsigned NumLayouts  = 4;
  localparam int unsigned LayoutLoBits [NumLayouts] = '{64, 64, 64, 48};
  localparam int unsigned LayoutHiPack [NumLayouts] = '{ 4,  2,  3,  1};

  function automatic int unsigned macro_words(int unsigned width, int unsigned words);
    if (width == 48)    return 256;
    if (width == 32)    return 512;
    if (words >= 2048)  return 2048;
    if (words >= 1024)  return 1024;
    if (words >=  512)  return 512;
    if (words >=  256)  return 256;
    return 64;
  endfunction

  function automatic int unsigned macro_area(int unsigned width, int unsigned words);
    if (width == 48)    return 70850;
    if (width == 32)    return 79720;
    if (words == 2048)  return 491634;
    if (words == 1024)  return 263946;
    if (words ==  512)  return 150102;
    if (words ==  256)  return 93181;
    return 50489;
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
    int unsigned width = bits * pack;
    int unsigned words = records / pack;
    if (records % pack != 0 || words % macro_words(width, 0) != 0) return 32'h7fff_ffff;
    column_area = 0;
    for (int unsigned base = 0; base < words; base += macro_words(width, words - base)) begin
      column_area += macro_area(width, macro_words(width, words - base));
    end
  endfunction

  function automatic int unsigned layout_area(int unsigned records, int unsigned layout);
    return column_area(records, LayoutLoBits[layout], 1)
         + column_area(records, RecordBits - LayoutLoBits[layout], LayoutHiPack[layout]);
  endfunction

  function automatic int unsigned best_layout(int unsigned records);
    best_layout = 0;
    for (int unsigned l = 1; l < NumLayouts; l++) begin
      if (layout_area(records, l) < layout_area(records, best_layout)) best_layout = l;
    end
  endfunction

  function automatic int unsigned segment_records(int unsigned records, int unsigned segment);
    int unsigned cost  [MaxUnits+1];
    int unsigned first [MaxUnits+1];
    int unsigned units = records / SegmentUnit;
    cost[0]  = 0;
    first[0] = 0;
    for (int unsigned u = 1; u <= units; u++) begin
      cost[u] = '1;
      for (int unsigned k = u; k >= 1; k--) begin
        int unsigned area = layout_area(k * SegmentUnit, best_layout(k * SegmentUnit)) + cost[u - k];
        if (area < cost[u]) begin
          cost[u]  = area;
          first[u] = k;
        end
      end
    end
    for (int unsigned s = 0; s < segment; s++) begin
      units -= first[units];
    end
    return first[units] * SegmentUnit;
  endfunction

  function automatic int unsigned num_segments(int unsigned records);
    num_segments = 0;
    while (segment_records(records, num_segments) != 0) num_segments++;
  endfunction

  function automatic int unsigned segment_base(int unsigned records, int unsigned segment);
    segment_base = 0;
    for (int unsigned s = 0; s < segment; s++) begin
      segment_base += segment_records(records, s);
    end
  endfunction

endpackage
