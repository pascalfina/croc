
#
# Run once per VCD, changing VCD and TAG below.
###############################################################################

set REPO    /scratch/sem26f37/croc_burst2
set NETLIST $REPO/openroad/out/croc.v
set SPEF    $REPO/openroad/out/croc.spef

# --- change per run ----------------------------------------------------------
set VCD     $REPO/vsim/croc.vcd
set TAG     burst
# -----------------------------------------------------------------------------

set TOP        croc_chip
set STRIP_PATH tb_croc_soc/i_croc_soc
set CLK_PORT   clk_i
set CLK_PERIOD 50
set BYTES      13060

set PDK_DIR $REPO/ihp13/pdk/ihp-sg13g2/libs.ref
set RPT     reports/power
file mkdir $RPT

# cell-name prefixes of the three blocks (hierarchy survives in the flat names)
set PFX_IDMA  "i_croc_soc/i_croc/gen_dma.i_croc_idma/"
set PFX_XBAR  "i_croc_soc/i_croc/i_main_xbar."
set PFX_BDMA  "i_croc_soc/i_croc/i_burst_dma."

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

#--- which attribute carries net switching power? -----------------------------
set ATTR ""
foreach a {net_switching_power switching_power} {
    set probe [index_collection [get_nets -quiet *] 0]
    if {![catch { set v [get_attribute -quiet $probe $a] }] && $v ne ""} { set ATTR $a; break }
}
puts "\n\[info\] net power attribute: [expr {$ATTR eq "" ? "none" : $ATTR}]"

#--- classify every net by which blocks it touches ----------------------------
# A net crossing iDMA -> crossbar carries the compressed address channel.
proc block_of {name} {
    global PFX_IDMA PFX_XBAR PFX_BDMA
    if {[string first $PFX_IDMA $name] == 0} { return idma }
    if {[string first $PFX_XBAR $name] == 0} { return xbar }
    if {[string first $PFX_BDMA $name] == 0} { return bdma }
    return other
}

foreach k {idma_xbar xbar_bdma idma_internal xbar_internal} {
    set cnt($k) 0 ; set pwr($k) 0.0 ; set togg($k) 0.0
}

set n_scanned 0
foreach_in_collection net [get_nets -quiet *] {
    incr n_scanned

    # which blocks do the connected cells belong to?
    set seen_idma 0 ; set seen_xbar 0 ; set seen_bdma 0
    if {[catch { set pins [get_pins -quiet -of_objects $net] }]} { continue }
    foreach_in_collection p $pins {
        set pn [get_attribute -quiet $p full_name]
        if {$pn eq ""} { continue }
        switch [block_of $pn] {
            idma { set seen_idma 1 }
            xbar { set seen_xbar 1 }
            bdma { set seen_bdma 1 }
        }
    }

    set k ""
    if {$seen_idma && $seen_xbar} {
        set k idma_xbar
    } elseif {$seen_xbar && $seen_bdma} {
        set k xbar_bdma
    } elseif {$seen_idma} {
        set k idma_internal
    } elseif {$seen_xbar} {
        set k xbar_internal
    }
    if {$k eq ""} { continue }

    incr cnt($k)
    set t [get_attribute -quiet $net toggle_rate]
    if {$t ne "" && [string is double -strict $t]} { set togg($k) [expr {$togg($k) + $t}] }
    if {$ATTR ne ""} {
        set p [get_attribute -quiet $net $ATTR]
        if {$p ne "" && [string is double -strict $p]} { set pwr($k) [expr {$pwr($k) + $p}] }
    }
}

#--- emit ---------------------------------------------------------------------
set out $RPT/xbar_addr_${TAG}.rpt
set fh [open $out w]
puts $fh "Interconnect switching power by block boundary - $TAG"
puts $fh "VCD   : $VCD"
puts $fh "Bytes : $BYTES"
puts $fh "Nets scanned: $n_scanned\n"
puts $fh [format "%-16s %8s %18s %18s" "boundary" "nets" "toggle_rate" "power \[W\]"]
puts $fh [string repeat - 64]
foreach k {idma_xbar xbar_bdma idma_internal xbar_internal} {
    puts $fh [format "%-16s %8d %18.6e %18.6e" $k $cnt($k) $togg($k) $pwr($k)]
}
puts $fh [string repeat - 64]
puts $fh ""
puts $fh "Per byte moved:"
foreach k {idma_xbar xbar_bdma} {
    puts $fh [format "  %-16s power/byte = %.6e   toggle_rate/byte = %.6e" \
                  $k [expr {$pwr($k)/$BYTES}] [expr {$togg($k)/$BYTES}]]
}
puts $fh ""
puts $fh "idma_xbar is the boundary the compression acts on: with it the address"
puts $fh "field is a constant and only a_optional.start_addr moves, once per"
puts $fh "burst. A CPU access drives a fresh address over the crossbar per word."
close $fh

puts "\n=============================================================="
puts " written: $out"
puts "=============================================================="
sh cat $out

exit
