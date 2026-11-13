# Copyright (c) 2022 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Authors:
# - Philippe Sauter <phsauter@iis.ee.ethz.ch>

# Preparation for the synthesis flow
# A common setup to provide some functionality and define variables

# global variables imported from environment variables (if set)
# define with scheme: <local-var> { <ENVVAR>  <fallback> }
set sv_flist   [expr {[info exists ::env(SV_FLIST)]   ? $::env(SV_FLIST)   : "src/croc.flist"}]
set out_dir    [expr {[info exists ::env(OUT_DIR)]    ? $::env(OUT_DIR)    : "out"}]
set tmp_dir    [expr {[info exists ::env(TMP_DIR)]    ? $::env(TMP_DIR)    : "tmp"}]
set rep_dir    [expr {[info exists ::env(REP_DIR)]    ? $::env(REP_DIR)    : "reports"}]
set proj_name  [expr {[info exists ::env(PROJ_NAME)]  ? $::env(PROJ_NAME)  : "croc"}]
set top_design [expr {[info exists ::env(TOP_DESIGN)] ? $::env(TOP_DESIGN) : "croc_chip"}]

file mkdir $out_dir
file mkdir $tmp_dir
file mkdir $rep_dir

puts "using: sv_flist   = '$sv_flist'"
puts "using: top_design = '$top_design'"
puts "using: proj_name  = '$proj_name'"
puts "using: out_dir    = '$out_dir'"
puts "using: tmp_dir    = '$tmp_dir'"
puts "using: rep_dir    = '$rep_dir'"

# process ABC script and write to temporary directory
proc processAbcScript {abc_script} {
    global tmp_dir
    set abc_out_path $tmp_dir/[file tail $abc_script]

    # substitute {STRING} placeholders with their value
    set raw [read -nonewline [open $abc_script r]]
    set abc_script_recaig [string map -nocase [list "{REC_AIG}" [subst "src/lazy_man_synth_library.aig"]] $raw]
    set abc_out [open $abc_out_path w]
    puts -nonewline $abc_out $abc_script_recaig

    flush $abc_out
    close $abc_out
    return $abc_out_path
}
