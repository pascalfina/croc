# Copyright 2023 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Tobias Senti      <tsenti@ethz.ch>
# - Jannis Schönleber <janniss@iis.ee.ethz.ch>
# - Philippe Sauter   <phsauter@iis.ee.ethz.ch>

# Stage 02: Placement (Repair Netlist + Global Placement + Detailed Placement)
#
# This stage performs:
# - Initial repair of the netlist (tie cells, buffers)
# - Global placement (2-pass: rough + routability-driven)
# - Detailed placement (legalization)
#
# Required environment variables:
#   PROJ_NAME    - Project name (e.g., "croc")
#   TOP_DESIGN   - Top module name
#
# Input checkpoint: 01_${PROJ_NAME}.floorplan
# Output checkpoint: 02_${PROJ_NAME}.placed

###############################################################################
# Setup
###############################################################################
source scripts/startup.tcl

# Load checkpoint from previous stage
load_checkpoint 01_${proj_name}.floorplan

# Set layers used for estimate_parasitics
setDefaultParasitics
set_dont_use $dont_use_cells


utl::report "###############################################################################"
utl::report "# Stage 02: PLACEMENT"
utl::report "###############################################################################"

utl::report "###############################################################################"
utl::report "# 02-01: Initial Repair Netlist"
utl::report "###############################################################################"

# Don't touch clock-tree related nets as repair_timing can insert buffers
# which then prevents CTS from running
set clock_nets [get_nets -of_objects [get_pins -of_objects "*_reg" -filter "name == CLK"]]
set_dont_touch $clock_nets

# RSZ-2008-Workaround: im gespreizten Floorplan wird das Reset-Mux-Netz zu lang ->
# repair_timing crasht mit "wire step options empty" -> Stage 02 bricht ab, 02_croc.placed
# wird NICHT gespeichert -> 03-05 laufen auf altem Layout. Reset ist nicht timing-kritisch.
# Breites Muster (flachgeklopfter Name mit Punkten) + Zaehler zur Kontrolle.
set rstnets [get_nets "*i_rstgen*"]
puts "RSZ-2008 Workaround: [llength $rstnets] i_rstgen-Netze -> dont_touch"
if {[llength $rstnets]} { set_dont_touch $rstnets }

utl::report "Repair tie fanout"
repair_tie_fanout $tieHiPin 
repair_tie_fanout $tieLoPin 

utl::report "Remove buffers"
remove_buffers

utl::report "Repair design"
repair_design -verbose

save_checkpoint 02-01_${proj_name}.pre_place


utl::report "###############################################################################"
utl::report "# 02-02: Global Placement"
utl::report "###############################################################################"

set_thread_count 8

# global_placement parameters:
# density:            In every part of the chip, about N% of the area is occupied by standard cells
# routability_driven: Reduce density target when there are a lot of wires in an area
# check_overflow:     Higher means routability starts being considered earlier in placement
#                     too early -> very dense regions, too late -> little to no effect
# timing_driven:      Prioritize near-critical timing paths (reduce their length)

# Rough placement to get parasitics from steiner-tree estimate so we can run repair_timing
utl::report "Global Placement (1)"
global_placement -density 0.60 -init_density_penalty 0.0001 -max_phi_coef 1.01
report_metrics "02-02_${proj_name}.gpl1"
report_image "02-02_${proj_name}.gpl1" true true
save_checkpoint 02-02_${proj_name}.gpl1

utl::report "Estimate parasitics"
estimate_parasitics -placement
utl::report "Repair design"
repair_design -verbose
save_checkpoint 02-02_${proj_name}.gpl1_fix

utl::report "Repair setup"
repair_timing -setup -verbose
save_checkpoint 02-02_${proj_name}.gpl1_repaired

# Actual global placement with routability and timing driven
utl::report "Global Placement (2)"
global_placement -density 0.60 \
                 -init_density_penalty 0.0001 \
                 -max_phi_coef 1.01 \
                 -routability_driven \
                 -routability_check_overflow 0.30 \
                 -timing_driven
report_metrics "02-02_${proj_name}.gpl2"
report_image "02-02_${proj_name}.gpl2" true true
save_checkpoint 02-02_${proj_name}.gpl2


utl::report "###############################################################################"
utl::report "# 02-03: Detailed Placement"
utl::report "###############################################################################"

# Opendp segfaultet (Signal 11 in legalPt) bei der grossen idma_fence-dbGroup. Die Gruppen
# wurden nur fuer global_placement gebraucht - die Zellen sind jetzt platziert. Vor
# detailed_placement Gruppen UND Regionen ZERSTOEREN (blosses removeInst reichte nicht).
# iDMA bleibt rechts / Endpoints an SRAM (detailed_placement macht nur lokale Legalisierung).
set blk [ord::get_db_block]
foreach g [$blk getGroups] { foreach i [$g getInsts] { catch {$g removeInst $i} } }
foreach g [$blk getGroups] { catch {odb::dbGroup_destroy $g} }
foreach r [$blk getRegions] { catch {odb::dbRegion_destroy $r} }
puts "Opendp-Workaround: nach Cleanup [llength [$blk getGroups]] Gruppen / [llength [$blk getRegions]] Regionen uebrig (soll 0/0 sein)"

# Legalize overlapping cells
utl::report "Detailed placement"
detailed_placement

utl::report "Optimize mirroring"
optimize_mirroring

utl::report "Estimate parasitics"
estimate_parasitics -placement

report_metrics "02_${proj_name}.placed"
save_checkpoint 02_${proj_name}.placed
report_image "02_${proj_name}.placed" true true

utl::report "###############################################################################"
utl::report "# Stage 02 complete: Checkpoint saved to ${save_dir}/02_${proj_name}.placed.zip"
utl::report "###############################################################################"
