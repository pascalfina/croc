source scripts/startup.tcl
load_checkpoint 01_croc.floorplan
set block [ord::get_db_block]
source src/instances.tcl


proc fence {block sram_inst ep_pat name side} {
  set bb [[$block findInst $sram_inst] getBBox]
  set strip [expr {int(150*[$block getDbUnitsPerMicron])}]
  if {$side eq "above"} { set ylo [$bb yMax]; set yhi [expr {[$bb yMax]+$strip}] } \
  else { set yhi [$bb yMin]; set ylo [expr {[$bb yMin]-$strip}] }
  set r [odb::dbRegion_create $block $name]
  odb::dbBox_create $r [$bb xMin] $ylo [$bb xMax] $yhi
  set g [odb::dbGroup_create $block ${name}_g]
  $r addGroup $g
  set n 0
  foreach i [$block getInsts] {
    if {[string match $ep_pat [$i getName]]} { $g addInst $i; incr n }
  }
  puts "  $name: $n insts"
}

fence $block $bank1_sram0 "*endpoint_sram_bank_1*" ep1_reg above
fence $block $bank0_sram0 "*endpoint_sram_bank_0*" ep0_reg below

global_placement -density 0.60

set u [$block getDbUnitsPerMicron]
proc c {block u pat} {
  set xs 0; set ys 0; set n 0
  foreach i [$block getInsts] { if {[string match $pat [$i getName]]} {
    set b [$i getBBox]; set xs [expr {$xs+([$b xMin]+[$b xMax])/2.0}]
    set ys [expr {$ys+([$b yMin]+[$b yMax])/2.0}]; incr n } }
  if {$n} { puts [format "  %-26s (%.1f, %.1f) um" $pat [expr {$xs/$n/$u}] [expr {$ys/$n/$u}]] }
}
puts "=== nach global_placement ==="
c $block $u "*endpoint_sram_bank_1*"
c $block $u "*i_sram1*"
exit
