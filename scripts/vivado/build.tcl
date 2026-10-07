# =============================================================================
# build.tcl
#
# Synthesises and implements build/vivado/image_pipeline.xpr, writes timing
# and utilisation reports to build/reports/, and exports the hardware
# platform (bitstream included) to build/image_pipeline.xsa for Vitis.
#
# The build fails (exit 1) and no XSA is exported if setup or hold timing
# is not met, so a bitstream that cannot run at speed never reaches Vitis.
#
# Usage (from the repo root):
#   vivado -mode batch -source scripts/vivado/build.tcl
#   vivado -mode batch -source scripts/vivado/build.tcl -tclargs -allow-timing-fail
# =============================================================================

set REPO_ROOT   [file normalize [file join [file dirname [info script]] .. ..]]
set PROJ_FILE   [file join $REPO_ROOT build vivado image_pipeline.xpr]
set REPORT_DIR  [file join $REPO_ROOT build reports]
set XSA_FILE    [file join $REPO_ROOT build image_pipeline.xsa]
set ALLOW_TIMING_FAIL [expr {[lsearch -exact $argv -allow-timing-fail] >= 0}]

if {[info exists ::env(NUMBER_OF_PROCESSORS)]} {
    set JOBS $::env(NUMBER_OF_PROCESSORS)
} else {
    set JOBS 4
}

if {![file exists $PROJ_FILE]} {
    error "Project not found: $PROJ_FILE (run scripts/vivado/create_project.tcl first)"
}
open_project $PROJ_FILE

# The RTL (ImageProcessTop and below) enters the block design as a module
# reference with its own out-of-context synthesis run. Vivado does not mark
# that run stale when the RTL changes, so refresh the reference on every
# build. The refresh deletes the run; regenerate the BD and recreate it.
set bd_file [get_files image_pipeline.bd]
set modrefs [get_ips -quiet -filter {IPDEF =~ "*:module_ref:*"}]
if {[llength $modrefs]} {
    update_module_reference $modrefs
}
generate_target all $bd_file
create_ip_run $bd_file

reset_run synth_1
launch_runs synth_1 -jobs $JOBS
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    error "Synthesis failed"
}

launch_runs impl_1 -to_step write_bitstream -jobs $JOBS
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "Implementation failed"
}

open_run impl_1
file mkdir $REPORT_DIR
report_timing_summary -max_paths 10 -file [file join $REPORT_DIR timing_summary.rpt]
report_utilization -file [file join $REPORT_DIR utilization.rpt]

set wns [get_property SLACK [get_timing_paths -setup -max_paths 1 -nworst 1]]
set whs [get_property SLACK [get_timing_paths -hold  -max_paths 1 -nworst 1]]
puts "TIMING: WNS = $wns ns, WHS = $whs ns"

if {$wns < 0 || $whs < 0} {
    if {$ALLOW_TIMING_FAIL} {
        puts "WARNING: timing not met; exporting anyway (-allow-timing-fail)."
    } else {
        puts "ERROR: timing not met (see [file join $REPORT_DIR timing_summary.rpt]); XSA not exported."
        exit 1
    }
}

write_hw_platform -fixed -include_bit -force $XSA_FILE
puts "Exported: $XSA_FILE"
