source scripts/init_tech.tcl
#set extRules ../technology/rcx/IHP_rcx_patterns.rules
set extRules ../ihp13/pdk/ihp-sg13g2/libs.tech/librelane/IHP_rcx_patterns.rules
read_def ./out/croc.def
define_process_corner -ext_model_index 0 tt
extract_parasitics -ext_model_file $extRules
write_spef ./out/croc.spef
write_sdf ./out/croc.sdf -corner tt -include_typ
