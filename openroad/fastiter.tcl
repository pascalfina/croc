source scripts/startup.tcl
load_checkpoint 01_croc.floorplan
set block [ord::get_db_block]

proc fence_box2 {block pats name xlo ylo xhi yhi} {
  set u [$block getDbUnitsPerMicron]
  set r [odb::dbRegion_create $block $name]
  odb::dbBox_create $r [expr {int($xlo*$u)}] [expr {int($ylo*$u)}] [expr {int($xhi*$u)}] [expr {int($yhi*$u)}]
  set g [odb::dbGroup_create $block ${name}_g]
  $r addGroup $g
  set n 0
  foreach i [$block getInsts] {
    foreach p $pats { if {[string match $p [$i getName]]} { $g addInst $i; incr n; break } }
  }
  puts "  $name: $n insts"
}
# beide Compressoren in EINE Region, ganz rechts (weit weg von den linken SRAMs)
fence_box2 $block {*read_burst* *write_burst*} comp 1450 700 1580 1300

global_placement -density 0.60 -init_density_penalty 0.0001 -max_phi_coef 1.02

set u [$block getDbUnitsPerMicron]
proc c {block u pat} {
  set xs 0; set ys 0; set n 0
  foreach i [$block getInsts] { if {[string match $pat [$i getName]]} {
    set b [$i getBBox]; set xs [expr {$xs+([$b xMin]+[$b xMax])/2.0}]
    set ys [expr {$ys+([$b yMin]+[$b yMax])/2.0}]; incr n } }
  if {$n} { puts [format "  %-26s (%.1f, %.1f) um" $pat [expr {$xs/$n/$u}] [expr {$ys/$n/$u}]] }
}
puts "=== nach global_placement ==="
c $block $u "*read_burst*"
c $block $u "*write_burst*"
c $block $u "*endpoint_sram_bank_0*"
c $block $u "*endpoint_sram_bank_1*"
c $block $u "*i_sram0*"
c $block $u "*i_sram1*"
exit
