# =============================================================================
# create_project.tcl
#
# Recreates the Vivado project from repo sources into build/vivado/.
# The repo is the source of truth: RTL, testbench and constraints are added
# by reference (edits in Vivado land in the repo), and the block design is
# rebuilt from bd/image_pipeline.tcl. Everything under build/ is disposable.
#
# Usage (from the repo root):
#   vivado -mode batch -source scripts/vivado/create_project.tcl
#
# Then open build/vivado/image_pipeline.xpr in the GUI if desired.
# Block design edits made in the GUI must be exported back with:
#   write_bd_tcl -force <repo>/bd/image_pipeline.tcl
# =============================================================================

set REPO_ROOT [file normalize [file join [file dirname [info script]] .. ..]]
set PROJ_NAME image_pipeline
set PROJ_DIR  [file join $REPO_ROOT build vivado]
set PART      xc7z020clg400-1
set BD_NAME   image_pipeline

create_project -force $PROJ_NAME $PROJ_DIR -part $PART
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

add_files -norecurse -fileset constrs_1 \
    [file join $REPO_ROOT constraints imageproc_active_io.xdc]

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

# -----------------------------------------------------------------------------
# Simulation (UVM)
# Component files are `included by tb_pkg.sv, so only the interface, package
# and top are compiled directly.
# -----------------------------------------------------------------------------
set TB_DIR [file join $REPO_ROOT tb]
set tb_files [glob -directory $TB_DIR -types f *.sv]
add_files -norecurse -fileset sim_1 $tb_files
foreach f $tb_files {
    set_property used_in_simulation false [get_files $f]
}
foreach name {tb_stream_if.sv tb_pkg.sv tb_top.sv} {
    set f [file join $TB_DIR $name]
    if {[file exists $f]} {
        set_property used_in_simulation true [get_files $f]
    }
}
set_property include_dirs [list $TB_DIR] [get_filesets sim_1]
set_property top tb_top [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
set_property -name xsim.compile.xvlog.more_options -value {-L uvm} -objects [get_filesets sim_1]
set_property -name xsim.elaborate.xelab.more_options -value {-L uvm} -objects [get_filesets sim_1]
set_property -name xsim.simulate.runtime -value {all} -objects [get_filesets sim_1]

puts "Project created: [file join $PROJ_DIR $PROJ_NAME.xpr]"
