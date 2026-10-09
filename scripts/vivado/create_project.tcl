# =============================================================================
# create_project.tcl
#
# Recreates the Vivado project from repo sources into build/vivado/.
# The repo is the source of truth: RTL and constraints are added
# by reference (edits in Vivado land in the repo), and the block design is
# rebuilt from bd/image_pipeline.tcl. Everything under build/ is disposable.
#
# Usage (from the repo root):
#   vivado -mode batch -source scripts/vivado/create_project.tcl
#
# Then open build/vivado/image_pipeline.xpr in the GUI if desired.
# Block design edits made in the GUI must be exported back with:
#   write_bd_tcl -force <repo>/bd/image_pipeline.tcl
#
# Simulation does not use this project; see scripts/sim/run_sim.py.
# =============================================================================

set REPO_ROOT [file normalize [file join [file dirname [info script]] .. ..]]
set PROJ_NAME image_pipeline
set PROJ_DIR  [file join $REPO_ROOT build vivado]
set PART      xc7z020clg400-1
set BD_NAME   image_pipeline

# Start clean: create_project -force keeps old block design files, which the
# BD script refuses to overwrite.
file delete -force $PROJ_DIR
create_project $PROJ_NAME $PROJ_DIR -part $PART
set_property target_language Verilog [current_project]

# Board files are optional: the PS7 configuration is embedded in the BD Tcl.
set board [lindex [get_board_parts -quiet -latest_file_version digilentinc.com:arty-z7-20:*] 0]
if {$board ne ""} {
    set_property board_part $board [current_project]
} else {
    puts "INFO: Arty Z7-20 board files not installed; using part $PART only."
}

# -----------------------------------------------------------------------------
# Design sources (referenced in place, not copied)
# -----------------------------------------------------------------------------
set rtl_files [glob -directory [file join $REPO_ROOT rtl] -types f *.v]
foreach sub [glob -nocomplain -directory [file join $REPO_ROOT rtl] -types d *] {
    lappend rtl_files {*}[glob -nocomplain -directory $sub -types f *.v]
}
add_files -norecurse -fileset sources_1 $rtl_files

# Xilinx IP: imported (copied) so generated output products stay in build/
foreach xci [glob -nocomplain -directory [file join $REPO_ROOT ip] *.xci] {
    import_ip $xci
}

# Digilent IP (dvi2rgb, rgb2dvi) from the ip/digilent submodule
set DIGILENT_IP [file join $REPO_ROOT ip digilent]
if {![file exists [file join $DIGILENT_IP ip dvi2rgb component.xml]]} {
    error "Digilent IP not found in $DIGILENT_IP; run: git submodule update --init"
}
set_property ip_repo_paths [list $DIGILENT_IP] [current_project]
update_ip_catalog

add_files -norecurse -fileset constrs_1 \
    [file join $REPO_ROOT constraints imageproc_active_io.xdc]
# Refers to clocks created by IP constraints, so implementation only
set timing_xdc [file join $REPO_ROOT constraints imageproc_timing.xdc]
add_files -norecurse -fileset constrs_1 $timing_xdc
set_property used_in_synthesis false [get_files $timing_xdc]

update_compile_order -fileset sources_1

# -----------------------------------------------------------------------------
# Block design
# -----------------------------------------------------------------------------
set ::origin_dir_loc [file join $PROJ_DIR bd]
source [file join $REPO_ROOT bd $BD_NAME.tcl]
if {[get_bd_designs -quiet $BD_NAME] eq ""} {
    error "Block design $BD_NAME was not created; see messages above."
}
validate_bd_design
save_bd_design

set bd_file [get_files $BD_NAME.bd]
set wrapper [make_wrapper -files $bd_file -top]
add_files -norecurse -fileset sources_1 $wrapper
set_property top ${BD_NAME}_wrapper [get_filesets sources_1]
update_compile_order -fileset sources_1

puts "Project created: [file join $PROJ_DIR $PROJ_NAME.xpr]"
