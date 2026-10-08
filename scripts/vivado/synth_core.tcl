# =============================================================================
# synth_core.tcl
#
# Out-of-context implementation of ImageProcessTop alone (no block design),
# to check the core's timing and resource use in a given configuration.
# Synthesises, places and routes, writes reports to build/reports/ and exits
# with code 1 if setup or hold timing is not met.
#
# Usage (from the repo root):
#   vivado -mode batch -source scripts/vivado/synth_core.tcl
#   vivado -mode batch -source scripts/vivado/synth_core.tcl -tclargs 512 512 1 10.0
#
# Arguments: WIDTH HEIGHT CHANNELS CLOCK_PERIOD_NS
# Default: 1280 720 3 6.667 (720p RGB at 150 MHz, 2x the 74.25 MHz pixel clock)
# =============================================================================

set REPO_ROOT  [file normalize [file join [file dirname [info script]] .. ..]]
set REPORT_DIR [file join $REPO_ROOT build reports]
set PART       xc7z020clg400-1

lassign {1280 720 3 6.667} WIDTH HEIGHT CHANNELS PERIOD
if {[llength $argv] == 4} {
    lassign $argv WIDTH HEIGHT CHANNELS PERIOD
} elseif {[llength $argv] != 0} {
    error "usage: -tclargs WIDTH HEIGHT CHANNELS CLOCK_PERIOD_NS"
}
set tag "core_${WIDTH}x${HEIGHT}x${CHANNELS}"

read_verilog [glob [file join $REPO_ROOT rtl *.v]]
synth_design -top ImageProcessTop -part $PART -mode out_of_context \
    -generic WIDTH=$WIDTH -generic HEIGHT=$HEIGHT -generic CHANNELS=$CHANNELS

# Internal register-to-register timing only; the switch inputs are
# asynchronous and pass through a synchroniser.
create_clock -name aclk -period $PERIOD [get_ports aclk]
set_false_path -from [get_ports {sw[*]}]

opt_design
place_design
route_design

file mkdir $REPORT_DIR
report_timing_summary -max_paths 10 -file [file join $REPORT_DIR ${tag}_timing.rpt]
report_utilization -file [file join $REPORT_DIR ${tag}_utilization.rpt]

set wns [get_property SLACK [get_timing_paths -setup -max_paths 1 -nworst 1]]
set whs [get_property SLACK [get_timing_paths -hold  -max_paths 1 -nworst 1]]
set fmax [format %.1f [expr {1000.0 / ($PERIOD - $wns)}]]
puts "CORE TIMING ($tag @ $PERIOD ns): WNS = $wns ns, WHS = $whs ns, est. Fmax = $fmax MHz"

if {$wns < 0 || $whs < 0} {
    puts "ERROR: timing not met; see [file join $REPORT_DIR ${tag}_timing.rpt]"
    exit 1
}
