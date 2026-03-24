`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: lineBuffer
//
// Description:
//   Stores one horizontal line of pixels (LINE_LEN pixels wide, 8 bits each).
//   - Pixels are written sequentially via in_data / in_wr_en.
//   - On a read strobe (in_rd_en), outputs three consecutive pixels starting at
//     the current read pointer as a 24-bit word: {pix[rdPtr+2], pix[rdPtr+1], pix[rdPtr]}.
//   - Both read and write pointers wrap automatically at LINE_LEN.
//   - Reset clears both pointers; pixel memory is not cleared (don't-care on reset).
//////////////////////////////////////////////////////////////////////////////////

module lineBuffer #(
    parameter LINE_LEN = 512   // number of pixels per line
)(
    input  wire        clk,
    input  wire        rst,

    // Write port
    input  wire [7:0]  in_data,   // pixel byte to write
    input  wire        in_wr_en,  // write enable (one pixel per cycle)

    // Read port
    input  wire        in_rd_en,             // advance read pointer by 1 each cycle asserted
    output wire [23:0] out_data              // {pix[rdPtr+2], pix[rdPtr+1], pix[rdPtr]}
);

    // -----------------------------------------------------------------------
    // Pixel storage
    // -----------------------------------------------------------------------
    reg [7:0] mem [0:LINE_LEN-1];

    // Write pointer - wraps at LINE_LEN
    reg [$clog2(LINE_LEN)-1:0] wrPtr;

    // Read pointer - wraps at LINE_LEN
    // We need rdPtr+2, so pointer arithmetic uses full width; indices wrap via modulo
    reg [$clog2(LINE_LEN)-1:0] rdPtr;

    // -----------------------------------------------------------------------
    // Write logic
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            wrPtr <= {($clog2(LINE_LEN)){1'b0}};
        end else if (in_wr_en) begin
            mem[wrPtr] <= in_data;
            // Wrap pointer without modulo operator for synthesis friendliness
            wrPtr <= (wrPtr == LINE_LEN - 1) ? {($clog2(LINE_LEN)){1'b0}} : wrPtr + 1'b1;
        end
    end

    // -----------------------------------------------------------------------
    // Read pointer logic
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            rdPtr <= {($clog2(LINE_LEN)){1'b0}};
        end else if (in_rd_en) begin
            rdPtr <= (rdPtr == LINE_LEN - 1) ? {($clog2(LINE_LEN)){1'b0}} : rdPtr + 1'b1;
        end
    end

    // -----------------------------------------------------------------------
    // Read data - combinational, three consecutive pixels.
    // Wrap indices explicitly so synthesis doesn't infer latches.
    // -----------------------------------------------------------------------
    wire [$clog2(LINE_LEN)-1:0] rdPtr1 = (rdPtr == LINE_LEN - 1) ? {($clog2(LINE_LEN)){1'b0}} : rdPtr + 1'b1;
    wire [$clog2(LINE_LEN)-1:0] rdPtr2 = (rdPtr >= LINE_LEN - 2) ? rdPtr - (LINE_LEN - 2) : rdPtr + 2'd2;

    assign out_data = {mem[rdPtr2], mem[rdPtr1], mem[rdPtr]};

endmodule
