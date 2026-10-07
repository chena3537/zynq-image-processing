# =============================================================================
# run_sim.tcl
#
# Runs the UVM behavioural simulation of build/vivado/image_pipeline.xpr in
# batch mode. tb/input.bmp is copied into the xsim working directory and the
# resulting output.bmp is copied to build/sim/.
#
# Usage (from the repo root):
#   vivado -mode batch -source scripts/sim/run_sim.tcl
#   vivado -mode batch -source scripts/sim/run_sim.tcl -tclargs +UVM_TESTNAME=tb_test
#
# Any -tclargs are passed to xsim as plusargs.
# =============================================================================

set REPO_ROOT [file normalize [file join [file dirname [info script]] .. ..]]
set PROJ_FILE [file join $REPO_ROOT build vivado image_pipeline.xpr]
set OUT_DIR   [file join $REPO_ROOT build sim]

open_project $PROJ_FILE

set sim_dir [file join [get_property DIRECTORY [current_project]] \
                 image_pipeline.sim sim_1 behav xsim]
file mkdir $sim_dir
file copy -force [file join $REPO_ROOT tb input.bmp] $sim_dir

set plusargs [join [lmap a $argv {format "-testplusarg %s" [string trimleft $a +]}] " "]
set_property -name xsim.simulate.xsim.more_options -value $plusargs -objects [get_filesets sim_1]

launch_simulation -simset sim_1 -mode behavioral
close_sim

file mkdir $OUT_DIR
set log [file join $sim_dir simulate.log]
if {[file exists [file join $sim_dir output.bmp]]} {
    file copy -force [file join $sim_dir output.bmp] $OUT_DIR
}
file copy -force $log $OUT_DIR

# Fail the batch run on any UVM error/fatal
set fh [open $log r]
set text [read $fh]
close $fh
if {![regexp {UVM_ERROR\s*:\s*(\d+)} $text -> n_err] || ![regexp {UVM_FATAL\s*:\s*(\d+)} $text -> n_fatal]} {
    puts "ERROR: UVM report summary not found in $log"
    exit 1
}
puts "SIM RESULT: UVM_ERROR=$n_err UVM_FATAL=$n_fatal"
if {$n_err > 0 || $n_fatal > 0} {
    exit 1
}
