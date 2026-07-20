read_db out/croc.odb
define_process_corner -ext_model_index 0 X
extract_parasitics -ext_model_file ../ihp13/pdk/ihp-sg13g2/libs.tech/librelane/IHP_rcx_patterns.rules
write_spef out/croc.spef
exit
