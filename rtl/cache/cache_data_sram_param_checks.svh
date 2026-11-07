// SPDX-License-Identifier: SHL-0.51
// Included in cache_data_sram's parameter scope for elaboration checks.

    if (NumWords == 0 || NumWords % 256 != 0) begin : gen_invalid_depth
        $error("cache_data_sram: NumWords must be a positive multiple of 256 records.");
    end

    if (DataWidth != 80) begin : gen_invalid_data_width
        $error("cache_data_sram: only 80-bit records are supported.");
    end

    if (AddrWidth != ((NumWords > 1) ? $clog2(NumWords) : 1)) begin : gen_invalid_addr_width
        $error("cache_data_sram: AddrWidth must match the configured NumWords.");
    end
