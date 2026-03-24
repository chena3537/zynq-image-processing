`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: BufferCtrl
//
// Description:
// Controls line buffers and assembles 3x3 pixel
// windows for the downstream convolver.
//
// Incoming pixels are written one byte per cycle into the active line
// buffer. After every LINE_LEN pixels the write index advances to the
// next buffer. Once three full rows are buffered
// (totalPixelCounter >= 3*LINE_LEN), the read FSM activates and streams
// 512 consecutive 72-bit windows - one per column - to the convolver.
// Each window is assembled from three simultaneous 24-bit reads across
// three consecutive buffers. out_intr pulses for one cycle at the end of
// each read pass, signalling the upstream source to supply the next row.
//
// Output word layout:
//   bits [23: 0]  row N,   pixels at col c, c+1, c+2
//   bits [47:24]  row N+1, pixels at col c, c+1, c+2
//   bits [71:48]  row N+2, pixels at col c, c+1, c+2
//////////////////////////////////////////////////////////////////////////////////

module BufferCtrl #(
    parameter LINE_LEN   = 512,    //pixels per row
    parameter NUM_LINES  = 4       //# of line buffers
)(
    input  wire        clk,
    input  wire        rst,

    input  wire [7:0]  in_pixel_data,
    input  wire        in_pixel_data_valid,

    output reg  [71:0] out_pixel_data,
    output wire        out_pixel_data_valid,

    output reg         out_intr
);

    localparam CNT_W      = $clog2(LINE_LEN) + 1;
    localparam RING_W     = $clog2(NUM_LINES);
    localparam FILL_THRESHOLD = 3 * LINE_LEN;

    reg [$clog2(NUM_LINES * LINE_LEN + 1)-1:0] totalPixelCounter;

    reg [CNT_W-1:0]  wrPixelCnt;       // counts pixels within current row (0..LINE_LEN-1)
    reg [RING_W-1:0] wrBufIdx;          // which line buffer is currently being written

    localparam IDLE      = 1'b0;
    localparam RD_BUFFER = 1'b1;

    reg                rdState;
    reg                rd_active;        // '1' while reading; drives rd_en on line buffers
    reg [CNT_W-1:0]   rdColCnt;          // counts columns during a read pass
    reg [RING_W-1:0]  rdBufBase;         // oldest of the three buffers being read

    wire [23:0]          lbData [0:NUM_LINES-1]; // 3-pixel output from each line buffer
    reg  [NUM_LINES-1:0] lbWrEn;                 // one-hot write-enable, bit N -> buffer N
    reg  [NUM_LINES-1:0] lbRdEn;                 // one-hot read-enable,  bit N -> buffer N

    genvar g;
    generate
        for (g = 0; g < NUM_LINES; g = g + 1) begin : LB
            LineBuffer #(.LINE_LEN(LINE_LEN)) u_lb (
                .clk      (clk),
                .rst      (rst),
                .in_data  (in_pixel_data),
                .in_wr_en (lbWrEn[g]),
                .in_rd_en (lbRdEn[g]),
                .out_data (lbData[g])
            );
        end
    endgenerate

    // set one-hot write enable
    always @(*) begin
        lbWrEn = in_pixel_data_valid ? ({{(NUM_LINES-1){1'b0}}, 1'b1} << wrBufIdx) : {NUM_LINES{1'b0}};
    end

    // indexes of buffers to read
    wire [RING_W-1:0] rdBuf0 = rdBufBase;
    wire [RING_W-1:0] rdBuf1 = rdBufBase + 2'd1;
    wire [RING_W-1:0] rdBuf2 = rdBufBase + 2'd2;

    // set read enable for 3 buffers being read
    always @(*) begin
        lbRdEn = rd_active ? (  ({{(NUM_LINES-1){1'b0}}, 1'b1} << rdBuf0)
                               | ({{(NUM_LINES-1){1'b0}}, 1'b1} << rdBuf1)
                               | ({{(NUM_LINES-1){1'b0}}, 1'b1} << rdBuf2)) : {NUM_LINES{1'b0}};
    end

    // 3x3 pixel output
    always @(*) begin
        out_pixel_data = {lbData[rdBuf2], lbData[rdBuf1], lbData[rdBuf0]};
    end

    assign out_pixel_data_valid = rd_active;

    always @(posedge clk) begin
        if (rst) begin
            totalPixelCounter <= 12'd0;
        end else begin
            // Increment on each pixel written, decrement on each pixel read.
            // Both/neither active = no change
            case ({in_pixel_data_valid, rd_active})
                2'b10:   totalPixelCounter <= totalPixelCounter + 1'b1; // write only
                2'b01:   totalPixelCounter <= totalPixelCounter - 1'b1; // read only
                default: ;                                              // both or neither
            endcase
        end
    end

    
    always @(posedge clk) begin
        if (rst) begin
            wrPixelCnt <= {CNT_W{1'b0}};
            wrBufIdx   <= {RING_W{1'b0}};
        end else if (in_pixel_data_valid) begin
            if (wrPixelCnt == LINE_LEN - 1) begin
                wrPixelCnt <= {CNT_W{1'b0}};
                // Advance to the next line buffer
                wrBufIdx   <= (wrBufIdx == NUM_LINES - 1) ? {RING_W{1'b0}} : wrBufIdx + 1'b1;
            end else begin
                wrPixelCnt <= wrPixelCnt + 1'b1;
            end
        end
    end

    // Read-side FSM
    always @(posedge clk) begin
        if (rst) begin
            rdState   <= IDLE;
            rd_active <= 1'b0;
            out_intr  <= 1'b0;
            rdColCnt  <= {CNT_W{1'b0}};
            rdBufBase <= {RING_W{1'b0}};
        end else begin
            out_intr <= 1'b0;

            case (rdState)
                IDLE: begin
                    // Wait until three full rows are buffered
                    if (totalPixelCounter >= FILL_THRESHOLD) begin
                        rd_active <= 1'b1;
                        rdColCnt  <= {CNT_W{1'b0}};
                        rdState   <= RD_BUFFER;
                    end
                end

                RD_BUFFER: begin
                    if (rdColCnt == LINE_LEN - 1) begin
                        // Finished reading one full row-set
                        rd_active <= 1'b0;
                        out_intr  <= 1'b1;

                        // read from next buffer
                        rdBufBase <= (rdBufBase == NUM_LINES - 1) ? {RING_W{1'b0}} : rdBufBase + 1'b1;

                        rdState   <= IDLE;
                    end else begin
                        rdColCnt <= rdColCnt + 1'b1;
                    end
                end

                default: rdState <= IDLE;
            endcase
        end
    end

endmodule
