## Project-specific constraints for zynq-image-processing
## Target board: Digilent Arty Z7-20 Rev.B
## Source reference: Arty-Z7-20-Master.xdc (Digilent master template)
##
## Active controls used by this design:
## - sw[1:0] selects convolution kernel mode

## Switches
set_property -dict { PACKAGE_PIN M20 IOSTANDARD LVCMOS33 } [get_ports { sw[0] }]; # SW0
set_property -dict { PACKAGE_PIN M19 IOSTANDARD LVCMOS33 } [get_ports { sw[1] }]; # SW1
 