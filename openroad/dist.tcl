read_db out/croc.odb
set block [ord::get_db_block]
set u [$block getDbUnitsPerMicron]

proc cloud {block u pat} {
  set xmin 1e18; set ymin 1e18; set xmax -1e18; set ymax -1e18; set n 0
  foreach i [$block getInsts] {
    if {[string match $pat [$i getName]]} {
      set b [$i getBBox]; incr n
      set xmin [expr min($xmin,[$b xMin])]; set xmax [expr max($xmax,[$b xMax])]
      set ymin [expr min($ymin,[$b yMin])]; set ymax [expr max($ymax,[$b yMax])]
    }
  }
  if {$n==0} { puts [format "  %-16s : 0 Zellen (Muster pruefen)" $pat]; return }
  puts [format "  %-16s : %5d Zellen   center (%7.1f, %7.1f) um   span %.0f x %.0f um" \
        $pat $n [expr ($xmin+$xmax)/2.0/$u] [expr ($ymin+$ymax)/2.0/$u] \
        [expr ($xmax-$xmin)/$u] [expr ($ymax-$ymin)/$u]]
}

puts "=== Platzierungs-Zentren (um) ==="
cloud $block $u "*i_sram0*"
cloud $block $u "*i_sram1*"
cloud $block $u "*i_burst_dma*"
cloud $block $u "*idma*"
cloud $block $u "*read_burst*"
cloud $block $u "*endpoint*"




set block [ord::get_db_block]
set u [$block getDbUnitsPerMicron]

proc center {block u pat} {
  set xmin 1e18; set ymin 1e18; set xmax -1e18; set ymax -1e18; set n 0
  foreach i [$block getInsts] {
    if {[string match $pat [$i getName]]} {
      set b [$i getBBox]; incr n
      set xmin [expr min($xmin,[$b xMin])]; set xmax [expr max($xmax,[$b xMax])]
      set ymin [expr min($ymin,[$b yMin])]; set ymax [expr max($ymax,[$b yMax])]
    }
  }
  if {$n==0} { return {} }
  return [list [expr ($xmin+$xmax)/2.0/$u] [expr ($ymin+$ymax)/2.0/$u]]
}

array set C {}
foreach {name pat} {
  sram0 *i_sram0* sram1 *i_sram1* idma *idma*
  rd_comp *read_burst* wr_comp *write_burst*
  ep0 *endpoint_sram_bank_0* ep1 *endpoint_sram_bank_1*
} {
  set c [center $block $u $pat]
  if {$c ne {}} { set C($name) $c }
}

proc d {arr a b} {
  upvar 1 $arr A
  set ax [lindex $A($a) 0]; set ay [lindex $A($a) 1]
  set bx [lindex $A($b) 0]; set by [lindex $A($b) 1]
  return [expr sqrt(($ax-$bx)**2 + ($ay-$by)**2)]
}

puts "\n=== Estimated Dist. (um) ==="
foreach {a b label} {
  rd_comp ep0  "Read-Comp -> Bank0-Endpoint  (konst. Adr-Netz)"
  ep0     sram0 "Bank0-Endpoint -> Bank0-SRAM (togg. Adr-Netz)"
  wr_comp ep1  "Write-Comp -> Bank1-Endpoint (konst. Adr-Netz)"
  ep1     sram1 "Bank1-Endpoint -> Bank1-SRAM (togg. Adr-Netz)"
} { puts [format "  %-46s %7.1f" $label [d C $a $b]] }
exit
