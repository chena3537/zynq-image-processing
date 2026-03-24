`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: imageControl
//
// Description:
//   Accepts a stream of 8-bit grayscale pixels belonging to a 512×512 image and
//   routes them into a ring of four line buffers (LB0-LB3).  Once three complete
//   rows have accumulated, the module reads three consecutive buffers in lock-step
//   and assembles a 72-bit output word that carries the 3×3 neighbourhood needed
//   by the downstream convolver (9 pixels × 8 bits = 72 bits).
//
//   Line-buffer ring (circular, 4 slots, write pointer advances every 512 pixels):
//     Slot 0 → Slot 1 → Slot 2 → Slot 3 → Slot 0 → ...
//
//   Read groups (three consecutive slots relative to write head):
//     After slot k has just finished filling, the three oldest full rows live in
//     slots (k-2), (k-1), and (k), i.e. the convolver window spans those rows.
//
//   Output word bit layout (matches original):
//     out_pixel_data[23: 0]  = row N   pixels at column c, c+1, c+2
//     out_pixel_data[47:24]  = row N+1 pixels at column c, c+1, c+2
//     out_pixel_data[71:48]  = row N+2 pixels at column c, c+1, c+2
//
//   Interrupt (out_intr):
//     Pulses for one clock cycle every time a full 512-pixel read pass completes,
//     signalling the testbench to supply the next row.
//
//   Backpressure / flow control:
//     totalPixelCounter tracks pixels queued (written but not yet read).
//     Reading only starts when ≥ 3×512 = 1536 pixels are buffered.
//     Writing and reading are mutually exclusive in the counter (either write XOR
//     read is active in the original design - preserved here).
//////////////////////////////////////////////////////////////////////////////////

module imageControl #(
    parameter LINE_LEN   = 512,   // pixels per row
    parameter NUM_LINES  = 4      // number of line buffers in the ring
)(
    input  wire        clk,
    input  wire        rst,

    // Input pixel stream (one byte per valid cycle)
    input  wire [7:0]  in_pixel_data,
    input  wire        in_pixel_data_valid,

    // Output 3×3 pixel window (72 bits = 9 × 8-bit pixels)
    output reg  [71:0] out_pixel_data,
    output wire        out_pixel_data_valid,

    // Interrupt: pulses one cycle when a 512-pixel read pass finishes
    output reg         out_intr
);

    // =========================================================================
    // Local parameters
    // =========================================================================
    localparam CNT_W      = $clog2(LINE_LEN) + 1; // wide enough to count 0..LINE_LEN
    localparam RING_W     = $clog2(NUM_LINES);     // 2 bits for 4 buffers
    localparam FILL_THRESHOLD = 3 * LINE_LEN;      // 1536 - three full rows

    // =========================================================================
    // Shared pixel counter (tracks depth of valid pixels queued)
    // Increments on write, decrements on read, they don't overlap.
    // =========================================================================
    reg [$clog2(NUM_LINES * LINE_LEN + 1)-1:0] totalPixelCounter;

    // =========================================================================
    // Write-side control
    // =========================================================================
    reg [CNT_W-1:0]  wrPixelCnt;       // counts pixels within current row (0..LINE_LEN-1)
    reg [RING_W-1:0] wrBufIdx;          // which line buffer is currently being written

    // =========================================================================
    // Read-side FSM
    // =========================================================================
    localparam IDLE      = 1'b0;
    localparam RD_BUFFER = 1'b1;

    reg                rdState;
    reg                rd_active;        // '1' while reading; drives rd_en on line buffers
    reg [CNT_W-1:0]   rdColCnt;          // counts columns during a read pass (0..LINE_LEN-1)
    reg [RING_W-1:0]  rdBufBase;         // oldest of the three rows being read

    // =========================================================================
    // Line buffer signals
    // =========================================================================
    wire [23:0]          lbData [0:NUM_LINES-1]; // 3-pixel output from each line buffer
    reg  [NUM_LINES-1:0] lbWrEn;                 // one-hot write-enable, bit N -> buffer N
    reg  [NUM_LINES-1:0] lbRdEn;                 // one-hot read-enable,  bit N -> buffer N

    // =========================================================================
    // Instantiate four line buffers via generate
    // =========================================================================
    genvar g;
    generate
        for (g = 0; g < NUM_LINES; g = g + 1) begin : LB
            lineBuffer #(.LINE_LEN(LINE_LEN)) u_lb (
                .clk      (clk),
                .rst      (rst),
                .in_data  (in_pixel_data),
                .in_wr_en (lbWrEn[g]),
                .in_rd_en (lbRdEn[g]),
                .out_data (lbData[g])
            );
        end
    endgenerate

    // =========================================================================
    // Write-enable decode: place a single 1 at position wrBufIdx (one-hot).
    // Shifting 1 left by wrBufIdx is equivalent to a binary-to-one-hot decoder.
    // All bits are 0 when no pixel is being written.
    // =========================================================================
    always @(*) begin
        lbWrEn = in_pixel_data_valid ? ({{(NUM_LINES-1){1'b0}}, 1'b1} << wrBufIdx) : {NUM_LINES{1'b0}};
    end

    // =========================================================================
    // Read-enable mux:
    //   Three consecutive buffers (rdBufBase, rdBufBase+1, rdBufBase+2 mod 4)
    //   are read in lock-step while rd_active is asserted.
    // =========================================================================
    // Natural 2-bit wrap gives modulo-4 for free: 2'b11 + 1 = 2'b00, etc.
    wire [RING_W-1:0] rdBuf0 = rdBufBase;
    wire [RING_W-1:0] rdBuf1 = rdBufBase + 2'd1;
    wire [RING_W-1:0] rdBuf2 = rdBufBase + 2'd2;

    // Three buffers are enabled simultaneously for reading (one-hot OR of three decoded positions).
    always @(*) begin
        lbRdEn = rd_active ? (  ({{(NUM_LINES-1){1'b0}}, 1'b1} << rdBuf0)
                               | ({{(NUM_LINES-1){1'b0}}, 1'b1} << rdBuf1)
                               | ({{(NUM_LINES-1){1'b0}}, 1'b1} << rdBuf2)) : {NUM_LINES{1'b0}};
    end

    // =========================================================================
    // Output pixel data mux:
    //   Assembles {row2[23:0], row1[23:0], row0[23:0]} from the three active
    //   read buffers.  Ordering matches the original: bits[23:0] = oldest row.
    // =========================================================================
    always @(*) begin
        out_pixel_data = {lbData[rdBuf2], lbData[rdBuf1], lbData[rdBuf0]};
    end

    assign out_pixel_data_valid = rd_active;

    // =========================================================================
    // totalPixelCounter: tracks how many pixels are buffered but not yet read
    // =========================================================================
    always @(posedge clk) begin
        if (rst) begin
            totalPixelCounter <= 12'd0;
        end else begin
            // Increment on each pixel written, decrement on each pixel read.
            // Both can be active simultaneously (write and read overlap), in
            // which case the net change is zero and no assignment is needed.
            case ({in_pixel_data_valid, rd_active})
                2'b10:   totalPixelCounter <= totalPixelCounter + 1'b1; // write only
                2'b01:   totalPixelCounter <= totalPixelCounter - 1'b1; // read only
                default: ;                                               // both or neither
            endcase
        end
    end

    // =========================================================================
    // Write-side pixel and buffer counters
    // =========================================================================
    always @(posedge clk) begin
        if (rst) begin
            wrPixelCnt <= {CNT_W{1'b0}};
            wrBufIdx   <= {RING_W{1'b0}};
        end else if (in_pixel_data_valid) begin
            if (wrPixelCnt == LINE_LEN - 1) begin
                wrPixelCnt <= {CNT_W{1'b0}};
                // Advance to the next line buffer in the ring
                wrBufIdx   <= (wrBufIdx == NUM_LINES - 1) ? {RING_W{1'b0}} : wrBufIdx + 1'b1;
            end else begin
                wrPixelCnt <= wrPixelCnt + 1'b1;
            end
        end
    end

    // =========================================================================
    // Read-side FSM and column counter
    // =========================================================================
    always @(posedge clk) begin
        if (rst) begin
            rdState   <= IDLE;
            rd_active <= 1'b0;
            out_intr  <= 1'b0;
            rdColCnt  <= {CNT_W{1'b0}};
            rdBufBase <= {RING_W{1'b0}};
        end else begin
            out_intr <= 1'b0;  // default: interrupt is a single-cycle pulse

            case (rdState)
                // -----------------------------------------------------------------
                IDLE: begin
                    // Wait until three full rows are buffered
                    if (totalPixelCounter >= FILL_THRESHOLD) begin
                        rd_active <= 1'b1;
                        rdColCnt  <= {CNT_W{1'b0}};
                        rdState   <= RD_BUFFER;
                    end
                end

                // -----------------------------------------------------------------
                RD_BUFFER: begin
                    if (rdColCnt == LINE_LEN - 1) begin
                        // Finished reading one full row-set
                        rd_active <= 1'b0;
                        out_intr  <= 1'b1;

                        // Slide the read window forward by one row
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
