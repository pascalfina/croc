read_db out/croc.odb
set block [ord::get_db_block]
puts "=== Regionen in out/croc.odb ==="
foreach r [$block getRegions] {
  puts "  [$r getName] : [llength [$r getRegionInsts]] insts, [llength [$r getBoundaries]] boxes"
}
exit
