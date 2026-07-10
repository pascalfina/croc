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
# iDMA-Fence + Endpoint-Constraint sind jetzt in 01 gebacken (im Checkpoint).
# Hier NICHT nochmal anlegen -> sonst doppelte Region (GPL-0304). fastiter macht nur
# noch global_placement auf dem geladenen Checkpoint + misst die Distanzen.
#fence_box2 $block {*idma*} idma_fence 1220 345 1585 1585


global_placement -density 0.60 -init_density_penalty 0.0001 -max_phi_coef 1.01


set u [$block getDbUnitsPerMicron]
proc cc {block u pat} {
  set xs 0; set ys 0; set n 0
  foreach i [$block getInsts] { if {[string match $pat [$i getName]]} {
    set b [$i getBBox]; set xs [expr {$xs+([$b xMin]+[$b xMax])/2.0}]
    set ys [expr {$ys+([$b yMin]+[$b yMax])/2.0}]; incr n } }
  if {$n==0} { return {} }
  return [list [expr {$xs/$n/$u}] [expr {$ys/$n/$u}]]
}
proc dd {a b} { expr {sqrt(([lindex $a 0]-[lindex $b 0])**2 + ([lindex $a 1]-[lindex $b 1])**2)} }
set idma [cc $block $u "*idma*"]
set ep0  [cc $block $u "*endpoint_sram_bank_0*"]
set ep1  [cc $block $u "*endpoint_sram_bank_1*"]
set sr0  [cc $block $u "*i_sram0*"]
set sr1  [cc $block $u "*i_sram1*"]
puts "=== nach global_placement (um) ==="
puts [format "  iDMA  center (%.1f, %.1f)" [lindex $idma 0] [lindex $idma 1]]
puts [format "  ep0   (%.1f, %.1f)   sram0 (%.1f, %.1f)" [lindex $ep0 0] [lindex $ep0 1] [lindex $sr0 0] [lindex $sr0 1]]
puts [format "  ep1   (%.1f, %.1f)   sram1 (%.1f, %.1f)" [lindex $ep1 0] [lindex $ep1 1] [lindex $sr1 0] [lindex $sr1 1]]
puts "  --- konst. Span iDMA->Endpoint (soll GROSS werden) ---"
puts [format "    iDMA -> ep0 (Read)   %.1f" [dd $idma $ep0]]
puts [format "    iDMA -> ep1 (Write)  %.1f" [dd $idma $ep1]]
puts "  --- togg. Netz Endpoint->SRAM (soll KLEIN bleiben) ---"
puts [format "    ep0 -> sram0         %.1f" [dd $ep0 $sr0]]
puts [format "    ep1 -> sram1         %.1f" [dd $ep1 $sr1]]
exit
