`timescale 1ns / 1ps
`include "uvm_macros.svh"
`include "tb_stream_if.sv"
`include "tb_pkg.sv"

import uvm_pkg::*;
import tb_pkg::*;

// DUT parameters can be overridden at elaboration, e.g.
//   xelab tb_top -generic_top WIDTH=16 -generic_top HEIGHT=8
module tb_top #(
    parameter WIDTH    = 512,
    parameter HEIGHT   = 512,
    parameter CHANNELS = 1
);

    logic clk;
    initial begin
        clk = 0;
        forever #5 clk = ~clk;      // 100 MHz
    end

    tb_stream_if pif (.clk(clk));

    wire [CHANNELS*8-1:0] m_tdata;
    assign pif.m_tdata = 24'(m_tdata);

    ImageProcessTop #(
        .WIDTH    (WIDTH),
        .HEIGHT   (HEIGHT),
        .CHANNELS (CHANNELS)
    ) dut (
        .aclk               (clk),
        .aresetn            (pif.aresetn),
        .s_axis_tdata       (pif.s_tdata[CHANNELS*8-1:0]),
        .s_axis_tvalid      (pif.s_tvalid),
        .s_axis_tready      (pif.s_tready),
        .s_axis_tuser       (pif.s_tuser),
        .s_axis_tlast       (pif.s_tlast),
        .m_axis_tdata       (m_tdata),
        .m_axis_tvalid      (pif.m_tvalid),
        .m_axis_tready      (pif.m_tready),
        .m_axis_tuser       (pif.m_tuser),
        .m_axis_tlast       (pif.m_tlast),
        .s_axi_ctrl_awaddr  (pif.awaddr),
        .s_axi_ctrl_awvalid (pif.awvalid),
        .s_axi_ctrl_awready (pif.awready),
        .s_axi_ctrl_wdata   (pif.wdata),
        .s_axi_ctrl_wstrb   (pif.wstrb),
        .s_axi_ctrl_wvalid  (pif.wvalid),
        .s_axi_ctrl_wready  (pif.wready),
        .s_axi_ctrl_bresp   (pif.bresp),
        .s_axi_ctrl_bvalid  (pif.bvalid),
        .s_axi_ctrl_bready  (pif.bready),
        .s_axi_ctrl_araddr  (pif.araddr),
        .s_axi_ctrl_arvalid (pif.arvalid),
        .s_axi_ctrl_arready (pif.arready),
        .s_axi_ctrl_rdata   (pif.rdata),
        .s_axi_ctrl_rresp   (pif.rresp),
        .s_axi_ctrl_rvalid  (pif.rvalid),
        .s_axi_ctrl_rready  (pif.rready),
        .sw                 (pif.sw),
        .out_intr           (pif.out_intr)
    );

    // Reset and idle values for everything the testbench drives
    initial begin
        pif.aresetn  = 1'b0;
        pif.sw       = 2'b00;
        pif.s_tvalid = 1'b0;
        pif.s_tdata  = '0;
        pif.s_tuser  = 1'b0;
        pif.s_tlast  = 1'b0;
        pif.m_tready = 1'b0;
        pif.awaddr   = '0;
        pif.awvalid  = 1'b0;
        pif.wdata    = '0;
        pif.wstrb    = '0;
        pif.wvalid   = 1'b0;
        pif.bready   = 1'b0;
        pif.araddr   = '0;
        pif.arvalid  = 1'b0;
        pif.rready   = 1'b0;
        repeat (10) @(posedge clk);
        pif.aresetn <= 1'b1;
    end

    initial begin
        uvm_config_db #(virtual tb_stream_if)::set(null, "uvm_test_top*", "vif", pif);
        uvm_config_db #(int)::set(null, "uvm_test_top", "width", WIDTH);
        uvm_config_db #(int)::set(null, "uvm_test_top", "height", HEIGHT);
        uvm_config_db #(int)::set(null, "uvm_test_top", "channels", CHANNELS);
        run_test("tb_test");
    end

endmodule
