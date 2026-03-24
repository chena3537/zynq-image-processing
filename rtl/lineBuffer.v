`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: lineBuffer
//
// Description:
// Single-row pixel store with a 3-pixel wide combinational read port.
//
// Pixels are written sequentially via in_data/in_wr_en. On each cycle
// that in_rd_en is asserted, out_data presents three consecutive pixels
// starting at the current read pointer.
//////////////////////////////////////////////////////////////////////////////////

module LineBuffer #(
    parameter LINE_LEN = 512   // number of pixels per line
)(
    input  wire        clk,
    input  wire        rst,

    // Write port
    input  wire [7:0]  in_data,
    input  wire        in_wr_en,

    // Read port
    input  wire        in_rd_en,
    output wire [23:0] out_data
);

    reg [7:0] mem [0:LINE_LEN-1];

    reg [$clog2(LINE_LEN)-1:0] wrPtr;

    reg [$clog2(LINE_LEN)-1:0] rdPtr;

    always @(posedge clk) begin
        if (rst) begin
            wrPtr <= {($clog2(LINE_LEN)){1'b0}};
        end else if (in_wr_en) begin
            mem[wrPtr] <= in_data;
            wrPtr <= (wrPtr == LINE_LEN - 1) ? {($clog2(LINE_LEN)){1'b0}} : wrPtr + 1'b1;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            rdPtr <= {($clog2(LINE_LEN)){1'b0}};
        end else if (in_rd_en) begin
            rdPtr <= (rdPtr == LINE_LEN - 1) ? {($clog2(LINE_LEN)){1'b0}} : rdPtr + 1'b1;
        end
    end

    //2nd and 3rd pixel pointers
    wire [$clog2(LINE_LEN)-1:0] rdPtr1 = (rdPtr == LINE_LEN - 1) ? {($clog2(LINE_LEN)){1'b0}} : rdPtr + 1'b1;
    wire [$clog2(LINE_LEN)-1:0] rdPtr2 = (rdPtr >= LINE_LEN - 2) ? rdPtr - (LINE_LEN - 2) : rdPtr + 2'd2;

    assign out_data = {mem[rdPtr2], mem[rdPtr1], mem[rdPtr]};

endmodule
