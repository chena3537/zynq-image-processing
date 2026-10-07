# =============================================================================
# program.tcl
#
# Programs the Arty Z7-20 over JTAG: loads the bitstream, initialises the PS,
# downloads the firmware ELF and starts it. Firmware output appears on the
# board's USB-UART.
#
# Usage (from the repo root, board connected over USB):
#   xsdb scripts/hw/program.tcl
#
# Inputs (produced by scripts/vivado/build.tcl and scripts/vitis/build_app.py):
#   build/vitis/plat/export/plat/hw/sdt/{image_pipeline.bit,ps7_init.tcl}   (or under $ZYNQ_VITIS_WS)
#   build/vitis/image_processing_app/build/image_processing_app.elf
# =============================================================================

set REPO_ROOT [file normalize [file join [file dirname [info script]] .. ..]]
if {[info exists ::env(ZYNQ_VITIS_WS)]} {
    set WS [file normalize $::env(ZYNQ_VITIS_WS)]
} else {
    set WS [file join $REPO_ROOT build vitis]
}
set ELF       [file join $WS image_processing_app build image_processing_app.elf]

set HW_DIR   [file join $WS plat export plat hw sdt]
set BIT      [file join $HW_DIR image_pipeline.bit]
set PS7_INIT [file join $HW_DIR ps7_init.tcl]
foreach f [list $BIT $PS7_INIT $ELF] {
    if {![file exists $f]} { error "Not found: $f" }
}

puts "Bitstream: $BIT"
puts "PS7 init:  $PS7_INIT"
puts "ELF:       $ELF"

connect
targets -set -nocase -filter {name =~ "APU*"}
rst -system
after 1000

targets -set -nocase -filter {name =~ "xc7z020*"}
fpga -file $BIT

targets -set -nocase -filter {name =~ "APU*"}
source $PS7_INIT
ps7_init
ps7_post_config

targets -set -nocase -filter {name =~ "*A9*#0"}
dow $ELF
con
puts "Firmware running."
disconnect
