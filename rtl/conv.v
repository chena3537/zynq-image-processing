`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: Conv
//
// Description:
// Applies a 3x3 signed convolution kernel to a stream of 9-pixel windows.
//
// Kernel coefficients are signed 8-bit, set in the
// initial block below. Update KERNEL_SUM to match the sum of coefficients.
// Kernels with a zero coefficient sum (Sobel, Laplacian) are not compatible
// with the divide-normalisation step without modifying the output stage.
//
// Pipeline latency: 2 clock cycles.
//   Stage 1: nine parallel signed multiplies (registered).
//   Stage 2: product accumulator, divide by KERNEL_SUM,
//            saturating clamp to [0, 255], registered output.
//
//////////////////////////////////////////////////////////////////////////////////

module Conv #(
    parameter NUM_TAPS   = 9,  // 3×3 kernel - do not change without resizing accumulator
    parameter KERNEL_SUM = 1   // sum of all kernel coefficients; must match values below
)(
    input  wire        clk,

    input  wire [71:0] in_pixel_data,
    input  wire        in_pixel_data_valid,

    output reg  [7:0]  out_conv_data,
    output reg         out_conv_data_valid
);

    // =========================================================================
    // Pixel-to-kernel index mapping
    //   KERNEL[0] → row 0 col 0,  KERNEL[1] → row 0 col 1,  KERNEL[2] → row 0 col 2
    //   KERNEL[3] → row 1 col 0,  KERNEL[4] → row 1 col 1,  KERNEL[5] → row 1 col 2
    //   KERNEL[6] → row 2 col 0,  KERNEL[7] → row 2 col 1,  KERNEL[8] → row 2 col 2
    // =========================================================================

    reg signed [7:0] KERNEL [0:NUM_TAPS-1];
    integer k;
    initial begin
        KERNEL[0] =  0; KERNEL[1] = -1; KERNEL[2] =  0;
        KERNEL[3] = -1; KERNEL[4] =  5; KERNEL[5] = -1;
        KERNEL[6] =  0; KERNEL[7] = -1; KERNEL[8] =  0;
    end

    
    reg signed [15:0] products [0:NUM_TAPS-1];
    reg               productsValid;

    genvar g;
    generate
        for (g = 0; g < NUM_TAPS; g = g + 1) begin : MULT
            always @(posedge clk) begin
                // Zero-extend unsigned pixel to signed 9-bit, then multiply by
                // signed 8-bit coefficient to get a correct signed 16-bit product.
                products[g] <= $signed({1'b0, in_pixel_data[g*8 +: 8]}) * KERNEL[g];
            end
        end
    endgenerate

    always @(posedge clk)
        productsValid <= in_pixel_data_valid;

    
    integer i;
    reg signed [19:0] acc;   // combinational accumulator
    reg signed [19:0] normalised;

    always @(*) begin
        acc = 20'sd0;
        for (i = 0; i < NUM_TAPS; i = i + 1)
            acc = acc + products[i];

        normalised = acc / $signed(KERNEL_SUM);
    end

    always @(posedge clk) begin
        out_conv_data_valid <= productsValid;

        // Saturating clamp to unsigned [0, 255]
        if (normalised < 20'sd0)
            out_conv_data <= 8'd0;           // clamp negative to black
        else if (normalised > 20'sd255)
            out_conv_data <= 8'd255;         // clamp overflow to white
        else
            out_conv_data <= normalised[7:0]; // in range - take lower 8 bits
    end

endmodule
