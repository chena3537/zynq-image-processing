`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: imageProcessTop
//
// Description:
//   Top-level wrapper for the 512×512 grayscale image blur pipeline.
//
//   Data path:
//     AXI-stream slave input  →  imageControl (line buffer management)
//                             →  conv         (3×3 box-blur convolution)
//                             →  outputBuffer (AXI-stream FIFO, Xilinx IP)
//                             →  AXI-stream master output
//
//   Port naming follows the AXI4-Stream specification:
//     aclk / aresetn   - global clock and active-low reset
//     s_axis_t*        - slave  (input)  stream ports
//     m_axis_t*        - master (output) stream ports
//
//   AXI-stream handshake:
//     Input  side: s_axis_tvalid / s_axis_tready (flow-controlled via FIFO)
//     Output side: m_axis_tvalid / m_axis_tready
//
//   Image parameters (512 × 512 greyscale):
//     LINE_LEN = 512 pixels per row
//     NUM_ROWS = 512 rows per frame
//
//   Reset convention: aresetn is ACTIVE-LOW (standard AXI).
//                     Internal logic uses active-high rst = ~aresetn.
//
//   Note: tb_top.sv DUT instantiation must be updated to use these port names.
//////////////////////////////////////////////////////////////////////////////////

module imageProcessTop #(
    parameter LINE_LEN = 512,
    parameter NUM_ROWS = 512
)(
    // Global clock and active-low reset
    input  wire        aclk,
    input  wire        aresetn,

    // Slave AXI-stream input (one pixel byte per valid cycle)
    input  wire        s_axis_tvalid,   // upstream data valid
    input  wire [7:0]  s_axis_tdata,    // pixel byte
    output wire        s_axis_tready,   // asserted when output FIFO is not full

    // Master AXI-stream output (convolved pixel bytes)
    output wire        m_axis_tvalid,   // output data valid
    output wire [7:0]  m_axis_tdata,    // convolved pixel byte
    input  wire        m_axis_tready,   // downstream ready

    // Interrupt: pulses one cycle per completed 512-pixel read pass
    output wire        out_intr
);

    // =========================================================================
    // Internal active-high reset (invert AXI active-low)
    // =========================================================================
    wire rst = ~aresetn;

    // =========================================================================
    // Internal wires between pipeline stages
    // =========================================================================
    wire [71:0] pixel_window;       // 9-pixel neighbourhood from imageControl
    wire        pixel_window_valid; // qualifies pixel_window

    wire [7:0]  conv_data;          // averaged pixel from convolver
    wire        conv_data_valid;    // qualifies conv_data

    wire        fifo_prog_full;     // FIFO is almost full → back-pressure input

    // =========================================================================
    // Back-pressure: tell the source to pause when the output FIFO is nearly full
    // =========================================================================
    assign s_axis_tready = ~fifo_prog_full;

    // =========================================================================
    // Stage 1: imageControl
    //   - Routes incoming pixels into four circular line buffers.
    //   - Once three full rows are buffered, streams out 72-bit pixel windows.
    //   - Generates out_intr after each 512-pixel read pass.
    // =========================================================================
    imageControl #(
        .LINE_LEN  (LINE_LEN),
        .NUM_LINES (4)
    ) u_imageControl (
        .clk                  (aclk),
        .rst                  (rst),
        .in_pixel_data        (s_axis_tdata),
        .in_pixel_data_valid  (s_axis_tvalid),
        .out_pixel_data       (pixel_window),
        .out_pixel_data_valid (pixel_window_valid),
        .out_intr             (out_intr)
    );

    // =========================================================================
    // Stage 2: conv
    //   - 2-cycle latency 3×3 box-blur (all-ones kernel, divide by 9).
    // =========================================================================
    conv #(
        .NUM_TAPS (9)
    ) u_conv (
        .clk                 (aclk),
        .in_pixel_data       (pixel_window),
        .in_pixel_data_valid (pixel_window_valid),
        .out_conv_data       (conv_data),
        .out_conv_data_valid (conv_data_valid)
    );

    // =========================================================================
    // Stage 3: outputBuffer (Xilinx AXI-stream FIFO IP)
    //   - Absorbs bursts from the convolver and delivers them back-pressured
    //     to the downstream consumer.
    //   - axis_prog_full drives the input-side flow control signal.
    // =========================================================================
    outputBuffer u_outputBuffer (
        .wr_rst_busy   (),
        .rd_rst_busy   (),
        .s_aclk        (aclk),
        .s_aresetn     (aresetn),
        .s_axis_tvalid (conv_data_valid),
        .s_axis_tready (),
        .s_axis_tdata  (conv_data),
        .m_axis_tvalid (m_axis_tvalid),
        .m_axis_tready (m_axis_tready),
        .m_axis_tdata  (m_axis_tdata),
        .axis_prog_full(fifo_prog_full)
    );

endmodule
