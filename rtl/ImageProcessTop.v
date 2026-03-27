`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: ImageProcessTop
//
// Description:
// Top-level AXI4-Stream wrapper for the 3x3 image convolution pipeline.
//
// Connects three pipeline stages:
//   BufferCtrl  ->  Conv  ->  outputBuffer (Xilinx FIFO IP)
//
// Ports follow AXI4-Stream naming conventions (s_axis_t*, m_axis_t*).
// aresetn is active-low; internal logic uses active-high rst = ~aresetn.
// s_axis_tready is deasserted when the output FIFO asserts axis_prog_full.
//////////////////////////////////////////////////////////////////////////////////

module ImageProcessTop #(
    parameter LINE_LEN = 512,
    parameter NUM_ROWS = 512
)(
    input  wire        aclk,
    input  wire        aresetn,

    input  wire        s_axis_tvalid,
    input  wire [7:0]  s_axis_tdata,
    output wire        s_axis_tready,

    output wire        m_axis_tvalid,
    output wire [7:0]  m_axis_tdata,
    output wire        m_axis_tlast,
    input  wire        m_axis_tready,

    // Interrupt: pulses one cycle per completed 512-pixel read pass
    output wire        out_intr
);

    // Internal active-high reset (invert AXI active-low)
    wire rst = ~aresetn;

    wire [71:0] pixel_window;
    wire        pixel_window_valid;

    wire [7:0]  conv_data;
    wire        conv_data_valid;

    wire        fifo_prog_full;



    localparam FRAME_SIZE = LINE_LEN * NUM_ROWS;        
    localparam CNT_W      = $clog2(FRAME_SIZE);      
 
    reg [CNT_W-1:0] out_pixel_cnt;               
 
    always @(posedge aclk) begin                           
        if (~aresetn) begin                                  
            out_pixel_cnt <= {CNT_W{1'b0}};                     
        end else if (m_axis_tvalid && m_axis_tready) begin        
            // Advance only on completed transfers (both sides ready)
            if (out_pixel_cnt == FRAME_SIZE - 1)
                out_pixel_cnt <= {CNT_W{1'b0}};
            else
                out_pixel_cnt <= out_pixel_cnt + 1'b1;
        end                                                      
    end                                                            
 
    // Assert tlast only on the last pixel of the frame
    assign m_axis_tlast = m_axis_tvalid &&                         
                          (out_pixel_cnt == FRAME_SIZE - 1);


    // Back-pressure: tell the source to pause when the output FIFO is nearly full
    assign s_axis_tready = ~fifo_prog_full;

    BufferCtrl #(
        .LINE_LEN  (LINE_LEN),
        .NUM_LINES (4)
    ) u_BufferCtrl (
        .clk                  (aclk),
        .rst                  (rst),
        .in_pixel_data        (s_axis_tdata),
        .in_pixel_data_valid  (s_axis_tvalid),
        .out_pixel_data       (pixel_window),
        .out_pixel_data_valid (pixel_window_valid),
        .out_intr             (out_intr)
    );

    Conv #(
        .NUM_TAPS (9)
    ) u_Conv (
        .clk                 (aclk),
        .in_pixel_data       (pixel_window),
        .in_pixel_data_valid (pixel_window_valid),
        .out_conv_data       (conv_data),
        .out_conv_data_valid (conv_data_valid)
    );

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
