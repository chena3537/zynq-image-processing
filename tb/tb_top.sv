`timescale 1ns / 1ps
`include "uvm_macros.svh"
`include "tb_stream_if.sv"
`include "tb_pkg.sv"

import uvm_pkg::*;
import tb_pkg::*;

module tb_top;

    // Clock generation
    logic clk;
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // Interface instantiation
    tb_stream_if pif(.clk(clk));

    // DUT instantiation
    ImageProcessTop dut(
        .aclk        (clk),
        .aresetn    (pif.rst),
        .s_axis_tvalid  (pif.in_data_valid),
        .s_axis_tdata        (pif.in_data),
        .s_axis_tready (pif.out_data_ready),
        .m_axis_tvalid (pif.out_data_valid),
        .m_axis_tdata       (pif.out_data),
        .m_axis_tready  (pif.in_data_ready),
        .out_intr       (pif.out_intr)
    );

    // Reset generation
    initial begin
        pif.rst          <= 0;
        pif.in_data_valid <= 0;
        pif.in_data       <= 0;
        pif.in_data_ready <= 1;
        #100;
        pif.rst <= 1;
    end

    // Register interface in config db and start UVM
    initial begin
        uvm_config_db #(virtual tb_stream_if)::set(null, "uvm_test_top.*", "vif", pif);
        run_test("tb_test");
    end

endmodule
