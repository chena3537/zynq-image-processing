`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: OutputFifo
//
// Description:
// Small first-word-fall-through FIFO (distributed RAM) between the
// convolution pipeline and the AXI4-Stream master port. The pipeline cannot
// stall, so the parent only issues work when the FIFO is guaranteed to have
// room (see the credit counter in ImageProcessTop); wr_en is never asserted
// while full.
//////////////////////////////////////////////////////////////////////////////////

module OutputFifo #(
    parameter DEPTH  = 32,     // power of two
    parameter DATA_W = 11
)(
    input  wire              clk,
    input  wire              rst,

    input  wire              wr_en,
    input  wire [DATA_W-1:0] wr_data,

    output wire              rd_valid,
    output wire [DATA_W-1:0] rd_data,
    input  wire              rd_en       // pop; only meaningful when rd_valid
);

    localparam AW = $clog2(DEPTH);

    (* ram_style = "distributed" *)
    reg [DATA_W-1:0] mem [0:DEPTH-1];

    reg [AW:0] wr_ptr, rd_ptr;           // one extra bit distinguishes full/empty

    assign rd_valid = (wr_ptr != rd_ptr);
    assign rd_data  = mem[rd_ptr[AW-1:0]];

    always @(posedge clk) begin
        if (wr_en)
            mem[wr_ptr[AW-1:0]] <= wr_data;
    end

    always @(posedge clk) begin
        if (rst) begin
            wr_ptr <= {(AW+1){1'b0}};
            rd_ptr <= {(AW+1){1'b0}};
        end else begin
            if (wr_en)
                wr_ptr <= wr_ptr + 1'b1;
            if (rd_en && rd_valid)
                rd_ptr <= rd_ptr + 1'b1;
        end
    end

endmodule
