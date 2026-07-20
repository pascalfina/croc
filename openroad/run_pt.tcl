#==============================================================================
# run_pt.tcl  --  PrimeTime PX (PrimePower) average power analysis for croc_chip
#
#   Reconstructed by Claude from the actual design files on tardis
#   (openroad/out/croc.{v,sdc,spef}, power/croc.saif). If you have your own
#   version, diff against it before trusting this one.
#
# INVOCATION (once pt_shell is reachable), run from the REPO ROOT:
#   cd <repo> && <synopsys-wrapper> pt_shell -f openroad/run_pt.tcl
#   e.g.  ...  synopsys-2022.12 pt_shell -f openroad/run_pt.tcl     (needs PT in pkg)
#         ...  primetime-2023.06 pt_shell -f openroad/run_pt.tcl    (on a PT host)
#
# RELOCATING (if /scratch is NOT shared and you copied the files to ~/pt_run):
#   set the 6 file variables below to the copied paths, or export them, e.g.
#   export PT_NETLIST=$HOME/pt_run/croc.v ; ... ; pt_shell -f run_pt.tcl
#==============================================================================

#--- inputs (defaults = repo layout; env-overridable for the copy case) -------
proc _d {var def} { expr {[info exists ::env($var)] ? $::env($var) : $def} }
set REPO       [pwd]
set NETLIST    [_d PT_NETLIST  $REPO/openroad/out/croc.v]
set SDC        [_d PT_SDC      $REPO/openroad/out/croc.sdc]
set SPEF       [_d PT_SPEF     $REPO/openroad/out/croc.spef]
set SAIF       [_d PT_SAIF     $REPO/power/croc.saif]
set LIB_STD    [_d PT_LIB_STD  $REPO/ihp13/pdk/ihp-sg13g2/libs.ref/sg13g2_stdcell/lib/sg13g2_stdcell_typ_1p20V_25C.lib]
set LIB_SRAM   [_d PT_LIB_SRAM $REPO/ihp13/pdk/ihp-sg13g2/libs.ref/sg13g2_sram/lib/RM_IHPSG13_1P_256x64_c2_bm_bist_typ_1p20V_25C.lib]
set TOP        croc_chip
# SAIF divider prefix down to the design top (tb -> DUT). Netlist is flat with
# '/'-joined cell names starting at i_croc_soc, so strip only the testbench:
set STRIP_PATH [_d PT_STRIP    tb_croc_soc]
set RPT        [_d PT_RPT      $REPO/power/reports]
file mkdir $RPT

#--- libraries (typ corner, 1.20 V, 25 C) -------------------------------------
set_app_var search_path  [concat . [file dirname $LIB_STD] [file dirname $LIB_SRAM]]
set_app_var link_library [list * $LIB_STD $LIB_SRAM]

#--- read + link design -------------------------------------------------------
read_verilog $NETLIST
current_design $TOP
link_design $TOP

#--- timing constraints + parasitics ------------------------------------------
read_sdc $SDC
read_parasitics $SPEF

#--- power engine -------------------------------------------------------------
set_app_var power_enable_analysis true
set_app_var power_analysis_mode   averaged   ;# SAIF toggle-rate based average

#--- switching activity from gate-level SAIF ----------------------------------
read_saif $SAIF -strip_path $STRIP_PATH

#--- analyse ------------------------------------------------------------------
update_power

#--- reports ------------------------------------------------------------------
report_power                       > $RPT/power.summary.rpt
catch { report_power -hierarchy    > $RPT/power.hier.rpt }
catch { report_power -groups {clock_network register combinational sequential memory io_pad} \
                                   > $RPT/power.groups.rpt }
# annotation coverage sanity-check (want a high % annotated from the SAIF):
catch { report_switching_activity  > $RPT/switching_activity.rpt }

puts ""
puts "==================================================================="
puts " PrimeTime PX power analysis complete."
puts "   top          : $TOP"
puts "   saif         : $SAIF  (strip_path: $STRIP_PATH)"
puts "   reports      : $RPT/"
puts " If annotation coverage is low, adjust STRIP_PATH (e.g. tb_croc_soc/i_croc_soc)."
puts "==================================================================="
report_power
exit
