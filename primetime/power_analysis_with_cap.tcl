###############################################################################
# PrimeTime PX - power analysis for the croc SoC
###############################################################################

# post-synth
#set NETLIST ../yosys/out/netlist_debug.v 
#set TOP        {croc_soc$croc_chip.i_croc_soc}
#set REPORT  post_synth_power.rpt

# post-layout
# set NETLIST [expr {[info exists env(NETLIST)] ? $env(NETLIST) : "../openroad/out/croc.v"}]

set NETLIST /scratch/sem26f37/croc_burst2/tmp_sim_data_croc/pt_package_20260720/baseline/croc_baseline.v

set TOP        croc_chip
set REPORT  [expr {[info exists env(REPORT_NAME)] ? $env(REPORT_NAME) : "baseline.rpt"}]

#set VCD     [expr {[info exists env(VCD_FILE)] ? $env(VCD_FILE) : "../vsim/croc.vcd"}]

set VCD /scratch/sem26f37/croc_burst2/tmp_sim_data_croc/pt_package_20260720/baseline/croc_baseline.vcd

#set SPEF    [expr {[info exists env(SPEF)] ? $env(SPEF) : "../openroad/out/croc.spef"}]

set SPEF /scratch/sem26f37/croc_burst2/tmp_sim_data_croc/pt_package_20260720/baseline/croc_baseline.spef

set STRIP_PATH tb_croc_soc/i_croc_soc
set CLK_PORT   clk_i
set CLK_PERIOD 50

# change path
set PDK_DIR ../ihp13/pdk/ihp-sg13g2/libs.ref

# start link_library with "*" so the design itself is searched too
set link_library "*"

# standard cells
set STDCELL_DIR ${PDK_DIR}/sg13g2_stdcell/lib
set STDCELL_LIB sg13g2_stdcell_typ_1p20V_25C.lib
lappend search_path     $STDCELL_DIR
lappend link_library    $STDCELL_LIB
lappend target_library  $STDCELL_LIB

# sram macros - one .lib file per macro used in croc (see ihp13/tc_sram_impl.sv)
set SRAM_DIR  ${PDK_DIR}/sg13g2_sram/lib
set SRAM_LIB_64x64   RM_IHPSG13_1P_64x64_c2_bm_bist_typ_1p20V_25C.lib
set SRAM_LIB_256x64  RM_IHPSG13_1P_256x64_c2_bm_bist_typ_1p20V_25C.lib
set SRAM_LIB_512x64  RM_IHPSG13_1P_512x64_c2_bm_bist_typ_1p20V_25C.lib
set SRAM_LIB_1024x64 RM_IHPSG13_1P_1024x64_c2_bm_bist_typ_1p20V_25C.lib
set SRAM_LIB_2048x64 RM_IHPSG13_1P_2048x64_c2_bm_bist_typ_1p20V_25C.lib

lappend search_path $SRAM_DIR

lappend link_library $SRAM_LIB_64x64
lappend link_library $SRAM_LIB_256x64
lappend link_library $SRAM_LIB_512x64
lappend link_library $SRAM_LIB_1024x64
lappend link_library $SRAM_LIB_2048x64

lappend target_library $SRAM_LIB_64x64
lappend target_library $SRAM_LIB_256x64
lappend target_library $SRAM_LIB_512x64
lappend target_library $SRAM_LIB_1024x64
lappend target_library $SRAM_LIB_2048x64

# io cells
set IO_DIR /scratch/sem26f37/croc_burst2/primetime
set IO_LIB sg13g2_io_noanalog.lib
#sg13g2_io_typ_1p2V_3p3V_25C.lib
lappend search_path     $IO_DIR
lappend link_library    $IO_LIB
lappend target_library  $IO_LIB

set disable_multicore_resource_checks true
set_host_options -max_cores 8

set power_enable_analysis true
set power_analysis_mode   time_based

read_verilog $NETLIST
link_design $TOP


read_parasitics -format SPEF $SPEF

create_clock $CLK_PORT -period $CLK_PERIOD
update_timing

read_vcd -strip_path $STRIP_PATH $VCD
update_power

file mkdir reports/power
report_power -nosplit -sort_by total_power -hierarchy -significant_digits 6 > reports/power/$REPORT

##############################
exit