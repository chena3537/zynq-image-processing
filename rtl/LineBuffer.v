`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: LineBuffer
//
// Description:
// One image line of storage: a simple dual-port RAM with one write port and
// one synchronous read port (one cycle read latency), so it infers block RAM.
//
// Reading and writing the same address in the same cycle is not supported;
// WindowGen never does (its read and write addresses are always one slot
// apart).
//////////////////////////////////////////////////////////////////////////////////

module LineBuffer #(
    parameter DEPTH  = 512,   // pixels per line
    parameter DATA_W = 8      // bits per pixel
)(
    input  wire                     clk,

    input  wire                     wr_en,
    input  wire [$clog2(DEPTH)-1:0] wr_addr,
    input  wire [DATA_W-1:0]        wr_data,

    input  wire [$clog2(DEPTH)-1:0] rd_addr,
    output reg  [DATA_W-1:0]        rd_data
);

    (* ram_style = "block" *)
    reg [DATA_W-1:0] mem [0:DEPTH-1];

    always @(posedge clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;
    end

    always @(posedge clk) begin
        rd_data <= mem[rd_addr];
    end

endmodule
