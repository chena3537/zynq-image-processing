`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: WindowGen
//
// Description:
// Turns an AXI4-Stream Video pixel stream (tuser = start of frame, tlast =
// end of line) into a stream of 3x3 windows, one per output pixel, with
// replicate-edge border handling. A WIDTH x HEIGHT frame in produces exactly
// WIDTH x HEIGHT windows out.
//
// Operation:
// The module walks an extended raster of (HEIGHT+1) x (WIDTH+1) "slots".
// Slot (i, j) with i < HEIGHT and j < WIDTH consumes input pixel p(i, j);
// the extra column j == WIDTH and the extra row i == HEIGHT consume nothing
// (s_tready is low) and exist only to finish the right and bottom borders.
// Slot (i, j) with i >= 1 and j >= 1 emits the window centred on output
// pixel (i-1, j-1).
//
//   Stage A (issue): choose the next slot, accept the pixel, read both line
//                    buffers at column j.
//   Stage B:         form the 3-pixel column {p(i, j), p(i-1, j), p(i-2, j)},
//                    replicating at the top/bottom border, shift it into the
//                    3x3 window (replicating at the left/right border) and
//                    update the line buffers.
//
// Flow control: a slot is only issued when issue_en is high (the parent
// guarantees space for every window in flight), so the pipeline never
// stalls once a slot is issued and s_tready depends only on registers.
//
// Frame sync: pixels are discarded until one with tuser arrives. A tuser in
// the middle of a frame abandons that frame and starts a new one; a tlast
// in the wrong place is flagged but does not move the counters. Either
// raises sync_err for one cycle.
//
// Window layout (per channel, 8 bits each, row-major from the top left):
//   win[ 7: 0] p0  win[15: 8] p1  win[23:16] p2      p0 p1 p2
//   win[31:24] p3  win[39:32] p4  win[47:40] p5      p3 p4 p5
//   win[55:48] p6  win[63:56] p7  win[71:64] p8      p6 p7 p8
// With CHANNELS > 1 each pi is CHANNELS*8 bits wide (channel 0 in the LSBs).
//////////////////////////////////////////////////////////////////////////////////

module WindowGen #(
    parameter WIDTH    = 512,
    parameter HEIGHT   = 512,
    parameter CHANNELS = 1
)(
    input  wire                      clk,
    input  wire                      rst,

    // Input video stream
    input  wire [CHANNELS*8-1:0]     s_tdata,
    input  wire                      s_tvalid,
    output wire                      s_tready,
    input  wire                      s_tuser,
    input  wire                      s_tlast,

    // Flow control and per-frame kernel
    input  wire                      issue_en,     // room downstream for another window
    input  wire [2:0]                kernel_sel,   // sampled at start of frame
    output wire                      issue_out,    // a window-producing slot was issued

    // Window stream (fixed one-slot latency after issue, never stalls)
    output reg  [9*CHANNELS*8-1:0]   win_data,
    output reg                       win_valid,
    output reg                       win_user,     // first window of the frame
    output reg                       win_last,     // last window of a line
    output reg                       win_eof,      // last window of the frame
    output reg  [2:0]                win_kernel,

    // Status
    output reg                       sync_err,     // one-cycle pulse
    output wire                      in_frame
);

    localparam PW = CHANNELS * 8;           // bits per pixel
    localparam CW = 3 * PW;                 // bits per window column
    localparam AW = $clog2(WIDTH);          // line buffer address width
    localparam IW = $clog2(HEIGHT + 1);     // slot row counter width
    localparam JW = $clog2(WIDTH + 1);      // slot column counter width

    // -------------------------------------------------------------------------
    // Stage A: slot issue
    // -------------------------------------------------------------------------
    localparam WAIT_SOF = 1'b0;
    localparam RUN      = 1'b1;

    reg          state;
    reg [IW-1:0] slot_i;
    reg [JW-1:0] slot_j;
    reg [2:0]    frame_kernel;

    wire needs_input = (state == WAIT_SOF) || (slot_i < HEIGHT && slot_j < WIDTH);
    wire accept      = s_tvalid && s_tready;

    assign s_tready = issue_en && needs_input;
    assign in_frame = (state == RUN);

    // A pixel carrying tuser always starts a frame at slot (0, 0).
    wire start_frame = accept && s_tuser;
    wire fire        = start_frame ||
                       (state == RUN && issue_en && (needs_input ? s_tvalid : 1'b1));

    wire [IW-1:0] issue_i = start_frame ? {IW{1'b0}} : slot_i;
    wire [JW-1:0] issue_j = start_frame ? {JW{1'b0}} : slot_j;
    wire [2:0]    issue_k = start_frame ? kernel_sel  : frame_kernel;

    assign issue_out = fire && (issue_i != 0) && (issue_j != 0);

    always @(posedge clk) begin
        if (rst) begin
            state        <= WAIT_SOF;
            slot_i       <= {IW{1'b0}};
            slot_j       <= {JW{1'b0}};
            frame_kernel <= 3'd0;
            sync_err     <= 1'b0;
        end else begin
            sync_err <= 1'b0;

            if (start_frame) begin
                frame_kernel <= kernel_sel;
                state        <= RUN;
                slot_i       <= {IW{1'b0}};
                slot_j       <= 1;
                // tuser mid-frame, or tlast on the first pixel of a line
                if (state == RUN || (s_tlast != (WIDTH == 1)))
                    sync_err <= 1'b1;
            end else if (fire) begin
                if (needs_input && (s_tlast != (slot_j == WIDTH - 1)))
                    sync_err <= 1'b1;

                if (slot_j == WIDTH) begin
                    slot_j <= {JW{1'b0}};
                    if (slot_i == HEIGHT) begin
                        slot_i <= {IW{1'b0}};
                        state  <= WAIT_SOF;      // frame complete
                    end else begin
                        slot_i <= slot_i + 1'b1;
                    end
                end else begin
                    slot_j <= slot_j + 1'b1;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Line buffers: lb1 holds row i-1, lb2 holds row i-2 (indexed by column).
    // Read at issue (stage A), data available in stage B.
    // -------------------------------------------------------------------------
    reg          b_valid;
    reg [IW-1:0] b_i;
    reg [JW-1:0] b_j;
    reg [PW-1:0] b_pix;
    reg [2:0]    b_kernel;

    wire [PW-1:0] lb1_q;   // p(i-1, j)
    wire [PW-1:0] lb2_q;   // p(i-2, j)
    wire          lb_we = b_valid && (b_j < WIDTH);

    LineBuffer #(.DEPTH(WIDTH), .DATA_W(PW)) u_lb1 (
        .clk     (clk),
        .wr_en   (lb_we),
        .wr_addr (b_j[AW-1:0]),
        .wr_data (b_pix),
        .rd_addr (issue_j[AW-1:0]),
        .rd_data (lb1_q)
    );

    LineBuffer #(.DEPTH(WIDTH), .DATA_W(PW)) u_lb2 (
        .clk     (clk),
        .wr_en   (lb_we),
        .wr_addr (b_j[AW-1:0]),
        .wr_data (lb1_q),
        .rd_addr (issue_j[AW-1:0]),
        .rd_data (lb2_q)
    );

    always @(posedge clk) begin
        if (rst) begin
            b_valid <= 1'b0;
        end else begin
            b_valid <= fire;
        end
        b_i      <= issue_i;
        b_j      <= issue_j;
        b_pix    <= s_tdata;
        b_kernel <= issue_k;
    end

    // -------------------------------------------------------------------------
    // Stage B: column assembly with top/bottom replication, window shift with
    // left/right replication.
    // -------------------------------------------------------------------------
    // Column format: {bottom, middle, top}, each PW bits.
    wire [PW-1:0] col_top = (b_i == 1)      ? lb1_q : lb2_q;
    wire [PW-1:0] col_mid = lb1_q;
    wire [PW-1:0] col_bot = (b_i == HEIGHT) ? lb1_q : b_pix;

    reg  [CW-1:0] w0, w1, w2;   // newest (right) .. oldest (left) column
    wire [CW-1:0] new_col = (b_j == WIDTH) ? w0 : {col_bot, col_mid, col_top};

    always @(posedge clk) begin
        if (b_valid) begin
            w2 <= w1;
            w1 <= (b_j == 0) ? new_col : w0;
            w0 <= new_col;
        end
    end

    // Window registers and sideband, aligned with the shifted columns
    wire [CW-1:0] n_w2 = w1;
    wire [CW-1:0] n_w1 = (b_j == 0) ? new_col : w0;
    wire [CW-1:0] n_w0 = new_col;

    always @(posedge clk) begin
        if (rst) begin
            win_valid <= 1'b0;
        end else begin
            win_valid <= b_valid && (b_i != 0) && (b_j != 0);
        end
        win_user   <= (b_i == 1) && (b_j == 1);
        win_last   <= (b_j == WIDTH);
        win_eof    <= (b_i == HEIGHT) && (b_j == WIDTH);
        win_kernel <= b_kernel;
        //            row 2 (bottom)                        row 1 (middle)                        row 0 (top)
        win_data   <= {n_w0[3*PW-1:2*PW], n_w1[3*PW-1:2*PW], n_w2[3*PW-1:2*PW],
                       n_w0[2*PW-1:PW],   n_w1[2*PW-1:PW],   n_w2[2*PW-1:PW],
                       n_w0[PW-1:0],      n_w1[PW-1:0],      n_w2[PW-1:0]};
    end

endmodule
