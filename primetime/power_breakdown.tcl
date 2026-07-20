###############################################################################
# PrimeTime PX - post-layout power analysis WITH per-block breakdown
#
# The post-layout netlist (croc_chip) is flat: every cell is a top-level
# instance whose escaped name still carries the old hierarchy path, e.g.
#
#     i_croc_soc/i_croc/gen_dma.i_croc_idma/_01234_
#
# "report_power -hierarchy" therefore reports a single line. This script
# recovers the breakdown by matching cell names against glob patterns and
# summing the per-cell power attributes.
#
# Run from the directory holding this file:
#   primetime-2026.03 pt_shell -f power_breakdown.tcl |& tee pt_breakdown.log
###############################################################################

set REPO    /scratch/sem26f37/croc_burst2
set NETLIST $REPO/openroad/out/croc.v
set SPEF    $REPO/openroad/out/croc.spef
set VCD     $REPO/vsim/croc.vcd

set TOP        croc_chip
set STRIP_PATH tb_croc_soc/i_croc_soc
set CLK_PORT   clk_i
set CLK_PERIOD 50

set PDK_DIR $REPO/ihp13/pdk/ihp-sg13g2/libs.ref
set RPT     reports/power
file mkdir $RPT

#--- libraries ----------------------------------------------------------------
set link_library "*"

set STDCELL_DIR ${PDK_DIR}/sg13g2_stdcell/lib
set STDCELL_LIB sg13g2_stdcell_typ_1p20V_25C.lib
lappend search_path    $STDCELL_DIR
lappend link_library   $STDCELL_LIB
lappend target_library $STDCELL_LIB

set SRAM_DIR ${PDK_DIR}/sg13g2_sram/lib
lappend search_path $SRAM_DIR
foreach s {64 256 512 1024 2048} {
    set l RM_IHPSG13_1P_${s}x64_c2_bm_bist_typ_1p20V_25C.lib
    lappend link_library   $l
    lappend target_library $l
}

# patched IO liberty: the stock file's sg13g2_IOPadAnalog cell is malformed and
# makes PrimeTime reject the whole library, so that (unused) cell was stripped.
set IO_DIR $REPO/primetime
set IO_LIB sg13g2_io_noanalog.lib
lappend search_path    $IO_DIR
lappend link_library   $IO_LIB
lappend target_library $IO_LIB

set disable_multicore_resource_checks true
set_host_options -max_cores 8

set power_enable_analysis true
set power_analysis_mode   time_based

#--- analysis -----------------------------------------------------------------
read_verilog $NETLIST
link_design $TOP
read_parasitics -format SPEF $SPEF

create_clock $CLK_PORT -period $CLK_PERIOD
update_timing

read_vcd -strip_path $STRIP_PATH $VCD
update_power

#--- standard reports ---------------------------------------------------------
report_power -nosplit -significant_digits 6 > $RPT/post_layout_total.rpt

# by cell type - works on a flat netlist, unlike -hierarchy
catch {
    report_power -nosplit -significant_digits 6 \
        -groups {clock_network register combinational sequential memory io_pad} \
        > $RPT/post_layout_groups.rpt
}

#--- per-block breakdown ------------------------------------------------------
# {label pattern} - first match wins, so order from specific to general.
set GROUPS {
    {core         i_croc_soc/i_croc/i_core_wrap/*}
    {dma_idma     i_croc_soc/i_croc/gen_dma.i_croc_idma/*}
    {dma_burst    i_croc_soc/i_croc/i_burst_dma*}
    {sram0        i_croc_soc/i_croc/i_sram0/*}
    {sram1        i_croc_soc/i_croc/i_sram1/*}
    {xbar         i_croc_soc/i_croc/i_xbar*}
    {uart         i_croc_soc/i_croc/i_uart/*}
    {gpio         i_croc_soc/i_croc/i_gpio/*}
    {jtag_dm      i_croc_soc/i_croc/i_dm*}
    {clint        i_croc_soc/i_croc/i_clint/*}
    {timer        i_croc_soc/i_croc/i_obi_timer/*}
    {soc_ctrl     i_croc_soc/i_croc/i_soc_ctrl/*}
    {bootrom      i_croc_soc/i_croc/i_bootrom/*}
    {rstgen       i_croc_soc/i_rstgen*}
    {user_domain  i_croc_soc/i_user*}
    {croc_other   i_croc_soc/i_croc/*}
    {soc_other    i_croc_soc/*}
    {io_pads      pad_*}
    {io_bondpad   IO_BOND_*}
    {io_filler    IO_FILL_*}
    {io_corner    IO_CORNER_*}
}

foreach g $GROUPS {
    set tot([lindex $g 0]) 0.0
    set cnt([lindex $g 0]) 0
}
set tot(unmatched) 0.0
set cnt(unmatched) 0
set grand 0.0
set missing 0

foreach_in_collection c [get_cells -quiet *] {
    set nm [get_attribute -quiet $c full_name]
    set p  [get_attribute -quiet $c total_power]
    if {$p eq "" || ![string is double -strict $p]} { incr missing; continue }
    set grand [expr {$grand + $p}]

    set hit unmatched
    foreach g $GROUPS {
        if {[string match [lindex $g 1] $nm]} { set hit [lindex $g 0]; break }
    }
    set tot($hit) [expr {$tot($hit) + $p}]
    incr cnt($hit)
}

#--- emit ---------------------------------------------------------------------
set fh [open $RPT/post_layout_breakdown.rpt w]
puts $fh "Post-layout power breakdown by block (croc_chip, flat netlist)"
puts $fh "Reconstructed from escaped cell names; total_power per cell, summed."
puts $fh "VCD: $VCD"
puts $fh "Clock: $CLK_PERIOD ns\n"
puts $fh [format "%-14s %10s  %14s  %7s" "Block" "Cells" "Power [W]" "%"]
puts $fh [string repeat - 50]

foreach g $GROUPS {
    set k [lindex $g 0]
    if {$cnt($k) == 0} { continue }
    set pct [expr {$grand > 0 ? 100.0 * $tot($k) / $grand : 0.0}]
    puts $fh [format "%-14s %10d  %14.6e  %7.2f" $k $cnt($k) $tot($k) $pct]
}
if {$cnt(unmatched) > 0} {
    set pct [expr {$grand > 0 ? 100.0 * $tot(unmatched) / $grand : 0.0}]
    puts $fh [format "%-14s %10d  %14.6e  %7.2f" "unmatched" $cnt(unmatched) $tot(unmatched) $pct]
}
puts $fh [string repeat - 50]
puts $fh [format "%-14s %10s  %14.6e  %7.2f" "TOTAL" "" $grand 100.0]
if {$missing > 0} {
    puts $fh "\nNote: $missing cells had no total_power attribute and were skipped."
}
close $fh

puts "\n=============================================================="
puts " reports written to $RPT/"
puts "   post_layout_total.rpt      overall power"
puts "   post_layout_groups.rpt     by cell type (clock/register/...)"
puts "   post_layout_breakdown.rpt  by block  <-- the interesting one"
puts "=============================================================="
sh cat $RPT/post_layout_breakdown.rpt

exit
