## Timing constraints that reference clocks created by IP (the PS7's
## clk_fpga_0/1). Those clocks exist only once the IP constraints are
## loaded, so this file is used in implementation only
## (scripts/vivado/create_project.tcl sets used_in_synthesis false).

# The pixel-clock domain only talks to the PS clock domains through
# asynchronous paths: the AXI clock converter, reset synchronisers and the
# GPIO status bits.
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks hdmi_rx_clk] \
    -group [get_clocks -include_generated_clocks clk_fpga_0] \
    -group [get_clocks -include_generated_clocks clk_fpga_1]
