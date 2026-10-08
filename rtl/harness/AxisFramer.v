`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: AxisFramer
//
// Description:
// Adapts an AXI DMA MM2S stream (one transfer = one frame, tlast on its last
// byte) to AXI4-Stream Video for ImageProcessTop: tuser on the first pixel
// of each frame and tlast on the last pixel of each line.
//
// Data and handshake pass straight through (no added latency). Counters
// restart after every beat that carries the DMA's tlast, so each DMA
// transfer starts a new frame even if a previous one had the wrong length.
//////////////////////////////////////////////////////////////////////////////////

module AxisFramer #(
    parameter WIDTH  = 512,     // pixels per line
    parameter DATA_W = 8
)(
    input  wire              aclk,
    input  wire              aresetn,

    // From AXI DMA MM2S
    input  wire [DATA_W-1:0] s_axis_tdata,
    input  wire              s_axis_tvalid,
    output wire              s_axis_tready,
    input  wire              s_axis_tlast,     // end of frame

    // To ImageProcessTop
    output wire [DATA_W-1:0] m_axis_tdata,
    output wire              m_axis_tvalid,
    input  wire              m_axis_tready,
    output wire              m_axis_tuser,     // start of frame
    output wire              m_axis_tlast      // end of line
);

    reg [$clog2(WIDTH)-1:0] col;
    reg                     first;            // next beat starts a frame

    assign m_axis_tdata  = s_axis_tdata;
    assign m_axis_tvalid = s_axis_tvalid;
    assign s_axis_tready = m_axis_tready;
    assign m_axis_tuser  = first;
    assign m_axis_tlast  = (col == WIDTH - 1);

    wire beat = s_axis_tvalid && m_axis_tready;

    always @(posedge aclk) begin
        if (!aresetn) begin
            col   <= 0;
            first <= 1'b1;
        end else if (beat) begin
            if (s_axis_tlast) begin
                col   <= 0;
                first <= 1'b1;
            end else begin
                col   <= (col == WIDTH - 1) ? 0 : col + 1'b1;
                first <= 1'b0;
            end
        end
    end

endmodule
