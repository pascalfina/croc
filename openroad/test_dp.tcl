# Schnell-Test: laeuft detailed_placement durch, wenn wir die dbGroups vorher zerstoeren?
# Laedt den Checkpoint NACH global_placement (kein GP noetig -> schnell), Cleanup, Legalisierung.
source scripts/startup.tcl
load_checkpoint 02-02_croc.gpl2
setDefaultParasitics
set blk [ord::get_db_block]
puts "VOR Cleanup: [llength [$blk getGroups]] Gruppen / [llength [$blk getRegions]] Regionen"
foreach g [$blk getGroups] { foreach i [$g getInsts] { catch {$g removeInst $i} } }
foreach g [$blk getGroups] { catch {odb::dbGroup_destroy $g} }
foreach r [$blk getRegions] { catch {odb::dbRegion_destroy $r} }
puts "NACH Cleanup: [llength [$blk getGroups]] Gruppen / [llength [$blk getRegions]] Regionen (soll 0/0)"
detailed_placement
optimize_mirroring
puts "=== ERFOLG: detailed_placement durchgelaufen, KEIN Signal 11 ==="
exit
