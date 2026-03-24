`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: conv
//
// Description:
//   Applies a 3×3 convolution kernel to a stream of 9-pixel windows.
//
//   Input:  in_pixel_data [71:0]  - nine 8-bit pixels packed as
//                                   {pix8, pix7, ..., pix1, pix0}
//                                   where pix0 = bits [7:0], pix8 = bits [71:64].
//           in_pixel_data_valid   - qualifies the input word.
//
//   Output: out_conv_data  [7:0]  - result byte, saturated to [0, 255].
//           out_conv_data_valid   - qualifies the output (registered, 2 cycles
//                                   after the input arrives).
//
//   Kernel: signed 8-bit coefficients (range -128 to +127), supporting both
//           smoothing filters (all-positive, e.g. box blur) and derivative
//           filters (mixed-sign, e.g. Sobel, Laplacian).
//           Set coefficients in the 'initial' block below.
//           Set KERNEL_SUM to the sum of all coefficients (must be non-zero).
//
//   Saturation: after dividing by KERNEL_SUM the signed result is clamped to
//           the unsigned 8-bit range [0, 255] before output.  Negative results
//           clamp to 0; results above 255 clamp to 255.
//
//   Pipeline (2-stage, latency = 2 clock cycles):
//     Stage 1: Multiply each of the 9 unsigned pixels by its signed coefficient.
//              The pixel is zero-extended to signed before multiplying so that
//              the full unsigned range [0,255] is preserved.
//              Products are signed 16-bit (max magnitude 255×127 = 32,385).
//     Stage 2: Sum all 9 products (signed 20-bit accumulator, max magnitude
//              9×32,385 = 291,465), divide by KERNEL_SUM, saturate, register.
//
//   Bit-width justification:
//     Product  : 255 × 127 = 32,385  → fits in signed 16-bit (max 32,767) ✓
//     Neg prod : 255 × 128 = 32,640  → fits in signed 16-bit (min -32,768) ✓
//     Sum      : 9 × 32,640 = 293,760 → fits in signed 20-bit (max 524,287) ✓
//////////////////////////////////////////////////////////////////////////////////

module conv #(
    parameter NUM_TAPS   = 9,  // 3×3 kernel - do not change without resizing accumulator
    parameter KERNEL_SUM = 1   // sum of all kernel coefficients; must match values below
)(
    input  wire        clk,

    // Input: 9 pixels packed into 72 bits (unsigned, LSB = pixel 0)
    input  wire [71:0] in_pixel_data,
    input  wire        in_pixel_data_valid,

    // Output: convolved pixel, saturated to unsigned [0, 255]
    output reg  [7:0]  out_conv_data,
    output reg         out_conv_data_valid
);

    // =========================================================================
    // Kernel coefficients - signed 8-bit, range [-128, +127].
    // Edit values here and update KERNEL_SUM parameter to match their sum.
    //
    // Example - box blur (current):
    //   1 1 1
    //   1 1 1     sum = 9  → KERNEL_SUM = 9
    //   1 1 1
    //
    // Example - Sobel X (horizontal edge detection):
    //  -1  0 +1
    //  -2  0 +2   sum = 0  → not suitable for divide normalisation;
    //  -1  0 +1   remove divide or use abs-value output instead.
    //
    // Pixel-to-kernel index mapping (see imageControl output word layout):
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

    // =========================================================================
    // Stage 1: signed multiply
    //
    // The pixel is unsigned [7:0].  Verilog multiplication is only signed when
    // BOTH operands are declared signed, so we zero-extend the pixel to a
    // signed 9-bit value ({1'b0, pixel}) before multiplying.  This preserves
    // the full unsigned range [0, 255] while keeping the operation signed so
    // that negative kernel coefficients produce negative products correctly.
    //
    // Product width: 9-bit signed × 8-bit signed = 16-bit signed.
    //   Max positive: 255 ×  127 =  32,385  (fits in signed 16-bit: max  32,767)
    //   Max negative: 255 × -128 = -32,640  (fits in signed 16-bit: min -32,768)
    // =========================================================================
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

    // =========================================================================
    // Stage 2: accumulate, divide, saturate, register
    //
    // Accumulator is signed 20-bit.
    //   Max magnitude: 9 × 32,640 = 293,760  (fits in signed 20-bit: max 524,287)
    //
    // After dividing by KERNEL_SUM the result is clamped to [0, 255]:
    //   - Negative  → 0
    //   - Above 255 → 255
    //   - Otherwise → pass through as-is
    // =========================================================================
    integer i;
    reg signed [19:0] acc;   // combinational accumulator
    reg signed [19:0] normalised; // acc / KERNEL_SUM, before saturation

    always @(*) begin
        acc = 20'sd0;
        for (i = 0; i < NUM_TAPS; i = i + 1)
            acc = acc + products[i];

        // Divide by kernel sum to normalise.  For a pure averaging filter this
        // gives the mean; for asymmetric filters the caller sets KERNEL_SUM to
        // whatever normalisation factor is appropriate.
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
