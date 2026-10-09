## Project-specific constraints for zynq-image-processing
## Target board: Digilent Arty Z7-20 Rev.B
## Source reference: Arty-Z7-20-Master.xdc (Digilent master template).
## Port names follow the block design wrapper (image_pipeline_wrapper).
##
## Active I/O used by this design:
## - sw[1:0]   selects the convolution kernel (both cores, in switch mode)
## - HDMI RX   720p60 input (dvi2rgb, EDID emulated on DDC, HPD driven high)
## - HDMI TX   processed 720p60 output (rgb2dvi)
## - led[0]    HDMI input clock locked; led[1] HDMI output locked

## Switches
set_property -dict { PACKAGE_PIN M20 IOSTANDARD LVCMOS33 } [get_ports { sw[0] }]; # SW0
set_property -dict { PACKAGE_PIN M19 IOSTANDARD LVCMOS33 } [get_ports { sw[1] }]; # SW1

## LEDs
set_property -dict { PACKAGE_PIN R14 IOSTANDARD LVCMOS33 } [get_ports { led[0] }]; # LD0
set_property -dict { PACKAGE_PIN P14 IOSTANDARD LVCMOS33 } [get_ports { led[1] }]; # LD1

## HDMI RX
set_property -dict { PACKAGE_PIN P19 IOSTANDARD TMDS_33  } [get_ports { hdmi_rx_clk_n }];
set_property -dict { PACKAGE_PIN N18 IOSTANDARD TMDS_33  } [get_ports { hdmi_rx_clk_p }];
set_property -dict { PACKAGE_PIN W20 IOSTANDARD TMDS_33  } [get_ports { hdmi_rx_data_n[0] }];
set_property -dict { PACKAGE_PIN V20 IOSTANDARD TMDS_33  } [get_ports { hdmi_rx_data_p[0] }];
set_property -dict { PACKAGE_PIN U20 IOSTANDARD TMDS_33  } [get_ports { hdmi_rx_data_n[1] }];
set_property -dict { PACKAGE_PIN T20 IOSTANDARD TMDS_33  } [get_ports { hdmi_rx_data_p[1] }];
set_property -dict { PACKAGE_PIN P20 IOSTANDARD TMDS_33  } [get_ports { hdmi_rx_data_n[2] }];
set_property -dict { PACKAGE_PIN N20 IOSTANDARD TMDS_33  } [get_ports { hdmi_rx_data_p[2] }];
set_property -dict { PACKAGE_PIN T19 IOSTANDARD LVCMOS33 } [get_ports { hdmi_rx_hpd[0] }];
set_property -dict { PACKAGE_PIN U14 IOSTANDARD LVCMOS33 } [get_ports { hdmi_rx_ddc_scl_io }];
set_property -dict { PACKAGE_PIN U15 IOSTANDARD LVCMOS33 } [get_ports { hdmi_rx_ddc_sda_io }];

## HDMI TX
set_property -dict { PACKAGE_PIN L17 IOSTANDARD TMDS_33  } [get_ports { hdmi_tx_clk_n }];
set_property -dict { PACKAGE_PIN L16 IOSTANDARD TMDS_33  } [get_ports { hdmi_tx_clk_p }];
set_property -dict { PACKAGE_PIN K18 IOSTANDARD TMDS_33  } [get_ports { hdmi_tx_data_n[0] }];
set_property -dict { PACKAGE_PIN K17 IOSTANDARD TMDS_33  } [get_ports { hdmi_tx_data_p[0] }];
set_property -dict { PACKAGE_PIN J19 IOSTANDARD TMDS_33  } [get_ports { hdmi_tx_data_n[1] }];
set_property -dict { PACKAGE_PIN K19 IOSTANDARD TMDS_33  } [get_ports { hdmi_tx_data_p[1] }];
set_property -dict { PACKAGE_PIN H18 IOSTANDARD TMDS_33  } [get_ports { hdmi_tx_data_n[2] }];
set_property -dict { PACKAGE_PIN J18 IOSTANDARD TMDS_33  } [get_ports { hdmi_tx_data_p[2] }];

## Clocks
# HDMI input pixel clock: 720p60 = 74.25 MHz. dvi2rgb derives PixelClk from
# it; rgb2dvi derives the output serial clock from PixelClk.
create_clock -period 13.468 -name hdmi_rx_clk [get_ports hdmi_rx_clk_p]

# Clock-domain grouping is in imageproc_timing.xdc (implementation only).

# Static or slowly changing board I/O
set_false_path -to [get_ports { led[*] hdmi_rx_hpd[*] }]
