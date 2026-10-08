`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: AxisDeframer
//
// Description:
// Adapts ImageProcessTop's AXI4-Stream Video output (tuser = start of
// frame, tlast = end of line) to an AXI DMA S2MM stream, which ends a
// transfer on tlast: tlast is passed on only for the last line of a frame.
//
// Data and handshake pass straight through (no added latency). The line
// counter restarts on tuser.
//////////////////////////////////////////////////////////////////////////////////

module AxisDeframer #(
    parameter HEIGHT = 512,     // lines per frame
    parameter DATA_W = 8
)(
    input  wire              aclk,
    input  wire              aresetn,

    // From ImageProcessTop
    input  wire [DATA_W-1:0] s_axis_tdata,
    input  wire              s_axis_tvalid,
    output wire              s_axis_tready,
    input  wire              s_axis_tuser,     // start of frame
    input  wire              s_axis_tlast,     // end of line

    // To AXI DMA S2MM
    output wire [DATA_W-1:0] m_axis_tdata,
    output wire              m_axis_tvalid,
    input  wire              m_axis_tready,
    output wire              m_axis_tlast      // end of frame
);

    reg [$clog2(HEIGHT)-1:0] line;

    // tuser marks line 0 even if the counter has drifted
    wire [$clog2(HEIGHT)-1:0] cur_line = s_axis_tuser ? 0 : line;

    assign m_axis_tdata  = s_axis_tdata;
    assign m_axis_tvalid = s_axis_tvalid;
    assign s_axis_tready = m_axis_tready;
    assign m_axis_tlast  = s_axis_tlast && (cur_line == HEIGHT - 1);

    always @(posedge aclk) begin
        if (!aresetn)
            line <= 0;
        else if (s_axis_tvalid && m_axis_tready && s_axis_tlast)
            line <= (cur_line == HEIGHT - 1) ? 0 : cur_line + 1'b1;
        else if (s_axis_tvalid && m_axis_tready && s_axis_tuser)
            line <= cur_line;
    end

endmodule
