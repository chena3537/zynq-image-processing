`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: ImageProcessTop
//
// Description:
// 3x3 convolution core with AXI4-Stream Video in and out (UG934:
// tuser = start of frame, tlast = end of line) and an AXI4-Lite control
// port. A WIDTH x HEIGHT frame in produces a WIDTH x HEIGHT frame out,
// with edge pixels replicated at the borders.
//
//   s_axis -> WindowGen -> Conv -> OutputFifo -> m_axis
//
// Throughput: one pixel per clock, plus one idle input cycle per line and
// one idle input line per frame (used to finish the right and bottom
// borders). Fits within video blanking.
//
// Back-pressure: the pipeline never stalls. A credit counter tracks windows
// issued but not yet sent on m_axis; new work is issued only while it is
// below the FIFO depth, so the FIFO can never overflow. s_axis_tready
// depends only on registers, not combinationally on m_axis_tready.
//
// Kernel selection: board switches sw[1:0] (synchronised here) or the
// CTRL register; see ControlRegs for the register map. The selected kernel
// is sampled at each start of frame.
//
// out_intr pulses for one cycle when the last pixel of a frame is sent.
// Single clock domain: all ports are synchronous to aclk.
//////////////////////////////////////////////////////////////////////////////////

module ImageProcessTop #(
    parameter WIDTH    = 512,
    parameter HEIGHT   = 512,
    parameter CHANNELS = 1      // 1 = 8-bit grey, 3 = 24-bit RGB
)(
    input  wire                   aclk,
    input  wire                   aresetn,

    // AXI4-Stream Video input
    input  wire [CHANNELS*8-1:0]  s_axis_tdata,
    input  wire                   s_axis_tvalid,
    output wire                   s_axis_tready,
    input  wire                   s_axis_tuser,
    input  wire                   s_axis_tlast,

    // AXI4-Stream Video output
    output wire [CHANNELS*8-1:0]  m_axis_tdata,
    output wire                   m_axis_tvalid,
    input  wire                   m_axis_tready,
    output wire                   m_axis_tuser,
    output wire                   m_axis_tlast,

    // AXI4-Lite control
    input  wire [4:0]             s_axi_ctrl_awaddr,
    input  wire                   s_axi_ctrl_awvalid,
    output wire                   s_axi_ctrl_awready,
    input  wire [31:0]            s_axi_ctrl_wdata,
    input  wire [3:0]             s_axi_ctrl_wstrb,
    input  wire                   s_axi_ctrl_wvalid,
    output wire                   s_axi_ctrl_wready,
    output wire [1:0]             s_axi_ctrl_bresp,
    output wire                   s_axi_ctrl_bvalid,
    input  wire                   s_axi_ctrl_bready,
    input  wire [4:0]             s_axi_ctrl_araddr,
    input  wire                   s_axi_ctrl_arvalid,
    output wire                   s_axi_ctrl_arready,
    output wire [31:0]            s_axi_ctrl_rdata,
    output wire [1:0]             s_axi_ctrl_rresp,
    output wire                   s_axi_ctrl_rvalid,
    input  wire                   s_axi_ctrl_rready,

    // Board switches (asynchronous)
    input  wire [1:0]             sw,

    // One-cycle pulse per completed output frame
    output reg                    out_intr
);

    localparam FIFO_DEPTH = 32;
    localparam PW         = CHANNELS * 8;

    reg rst;
    always @(posedge aclk)
        rst <= ~aresetn;

    // -------------------------------------------------------------------------
    // Switch synchroniser
    // -------------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) reg [1:0] sw_meta, sw_sync;
    always @(posedge aclk) begin
        sw_meta <= sw;
        sw_sync <= sw_meta;
    end

    // -------------------------------------------------------------------------
    // Pipeline
    // -------------------------------------------------------------------------
    wire [2:0]          kernel_sel;
    wire                issue_en;
    wire                issue_out;
    wire                sync_err;
    wire                in_frame;

    wire [9*PW-1:0]     win_data;
    wire                win_valid, win_user, win_last, win_eof;
    wire [2:0]          win_kernel;

    wire [PW-1:0]       conv_data;
    wire                conv_valid, conv_user, conv_last, conv_eof;

    WindowGen #(
        .WIDTH    (WIDTH),
        .HEIGHT   (HEIGHT),
        .CHANNELS (CHANNELS)
    ) u_WindowGen (
        .clk        (aclk),
        .rst        (rst),
        .s_tdata    (s_axis_tdata),
        .s_tvalid   (s_axis_tvalid),
        .s_tready   (s_axis_tready),
        .s_tuser    (s_axis_tuser),
        .s_tlast    (s_axis_tlast),
        .issue_en   (issue_en),
        .kernel_sel (kernel_sel),
        .issue_out  (issue_out),
        .win_data   (win_data),
        .win_valid  (win_valid),
        .win_user   (win_user),
        .win_last   (win_last),
        .win_eof    (win_eof),
        .win_kernel (win_kernel),
        .sync_err   (sync_err),
        .in_frame   (in_frame)
    );

    Conv #(
        .CHANNELS (CHANNELS)
    ) u_Conv (
        .clk       (aclk),
        .rst       (rst),
        .in_data   (win_data),
        .in_valid  (win_valid),
        .in_user   (win_user),
        .in_last   (win_last),
        .in_eof    (win_eof),
        .in_kernel (win_kernel),
        .out_data  (conv_data),
        .out_valid (conv_valid),
        .out_user  (conv_user),
        .out_last  (conv_last),
        .out_eof   (conv_eof)
    );

    wire          fifo_eof;
    wire          out_fire = m_axis_tvalid && m_axis_tready;

    OutputFifo #(
        .DEPTH  (FIFO_DEPTH),
        .DATA_W (PW + 3)
    ) u_OutputFifo (
        .clk      (aclk),
        .rst      (rst),
        .wr_en    (conv_valid),
        .wr_data  ({conv_eof, conv_last, conv_user, conv_data}),
        .rd_valid (m_axis_tvalid),
        .rd_data  ({fifo_eof, m_axis_tlast, m_axis_tuser, m_axis_tdata}),
        .rd_en    (m_axis_tready)
    );

    // -------------------------------------------------------------------------
    // Credit counter: windows issued and not yet sent on m_axis
    // -------------------------------------------------------------------------
    reg [$clog2(FIFO_DEPTH):0] credits_used;

    assign issue_en = (credits_used < FIFO_DEPTH);

    always @(posedge aclk) begin
        if (rst)
            credits_used <= 0;
        else
            credits_used <= credits_used + issue_out - out_fire;
    end

    always @(posedge aclk) begin
        if (rst)
            out_intr <= 1'b0;
        else
            out_intr <= out_fire && fifo_eof;
    end

    // -------------------------------------------------------------------------
    // Control registers
    // -------------------------------------------------------------------------
    ControlRegs #(
        .WIDTH  (WIDTH),
        .HEIGHT (HEIGHT)
    ) u_ControlRegs (
        .clk           (aclk),
        .rst           (rst),
        .s_axi_awaddr  (s_axi_ctrl_awaddr),
        .s_axi_awvalid (s_axi_ctrl_awvalid),
        .s_axi_awready (s_axi_ctrl_awready),
        .s_axi_wdata   (s_axi_ctrl_wdata),
        .s_axi_wstrb   (s_axi_ctrl_wstrb),
        .s_axi_wvalid  (s_axi_ctrl_wvalid),
        .s_axi_wready  (s_axi_ctrl_wready),
        .s_axi_bresp   (s_axi_ctrl_bresp),
        .s_axi_bvalid  (s_axi_ctrl_bvalid),
        .s_axi_bready  (s_axi_ctrl_bready),
        .s_axi_araddr  (s_axi_ctrl_araddr),
        .s_axi_arvalid (s_axi_ctrl_arvalid),
        .s_axi_arready (s_axi_ctrl_arready),
        .s_axi_rdata   (s_axi_ctrl_rdata),
        .s_axi_rresp   (s_axi_ctrl_rresp),
        .s_axi_rvalid  (s_axi_ctrl_rvalid),
        .s_axi_rready  (s_axi_ctrl_rready),
        .sw_sync       (sw_sync),
        .kernel_sel    (kernel_sel),
        .sync_err      (sync_err),
        .in_frame      (in_frame),
        .frame_done    (out_intr)
    );

endmodule
