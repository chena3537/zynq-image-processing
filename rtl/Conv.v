`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: Conv
//
// Description:
// Applies a selectable 3x3 signed convolution kernel to a stream of
// 9-pixel windows.
//
// kernel_select chooses one of four preset kernels:
//   00 sharpen, 01 box blur, 10 Gaussian blur, 11 edge detect.
//
// Each preset uses a matching divisor in the normalisation stage.
//
// Pipeline latency: 2 clock cycles.
//   Stage 1: nine parallel signed multiplies (registered).
//   Stage 2: product accumulator, divide by preset divisor,
//            saturating clamp to [0, 255], registered output.
//
//////////////////////////////////////////////////////////////////////////////////

module Conv #(
    parameter NUM_TAPS   = 9   // 3x3 kernel - do not change without resizing accumulator
)(
    input  wire        clk,
    input  wire [1:0]  kernel_select,

    input  wire [71:0] in_pixel_data,
    input  wire        in_pixel_data_valid,

    output reg  [7:0]  out_conv_data,
    output reg         out_conv_data_valid
);

    localparam [1:0] KERNEL_SHARPEN  = 2'b00;
    localparam [1:0] KERNEL_BOX_BLUR = 2'b01;
    localparam [1:0] KERNEL_GAUSS    = 2'b10;
    localparam [1:0] KERNEL_EDGE     = 2'b11;

    function signed [7:0] kernel_coeff;
        input [1:0] sel;
        input integer idx;
        begin
            case (sel)
                KERNEL_SHARPEN: begin
                    case (idx)
                        0: kernel_coeff = 8'sd0;
                        1: kernel_coeff = -8'sd1;
                        2: kernel_coeff = 8'sd0;
                        3: kernel_coeff = -8'sd1;
                        4: kernel_coeff = 8'sd5;
                        5: kernel_coeff = -8'sd1;
                        6: kernel_coeff = 8'sd0;
                        7: kernel_coeff = -8'sd1;
                        default: kernel_coeff = 8'sd0;
                    endcase
                end
                KERNEL_BOX_BLUR: begin
                    kernel_coeff = 8'sd1;
                end
                KERNEL_GAUSS: begin
                    case (idx)
                        0: kernel_coeff = 8'sd1;
                        1: kernel_coeff = 8'sd2;
                        2: kernel_coeff = 8'sd1;
                        3: kernel_coeff = 8'sd2;
                        4: kernel_coeff = 8'sd4;
                        5: kernel_coeff = 8'sd2;
                        6: kernel_coeff = 8'sd1;
                        7: kernel_coeff = 8'sd2;
                        default: kernel_coeff = 8'sd1;
                    endcase
                end
                default: begin
                    case (idx)
                        0: kernel_coeff = -8'sd1;
                        1: kernel_coeff = -8'sd1;
                        2: kernel_coeff = -8'sd1;
                        3: kernel_coeff = -8'sd1;
                        4: kernel_coeff = 8'sd8;
                        5: kernel_coeff = -8'sd1;
                        6: kernel_coeff = -8'sd1;
                        7: kernel_coeff = -8'sd1;
                        default: kernel_coeff = -8'sd1;
                    endcase
                end
            endcase
        end
    endfunction

    function signed [7:0] kernel_divisor;
        input [1:0] sel;
        begin
            case (sel)
                KERNEL_BOX_BLUR: kernel_divisor = 8'sd9;
                KERNEL_GAUSS:    kernel_divisor = 8'sd16;
                default:         kernel_divisor = 8'sd1;
            endcase
        end
    endfunction

    
    reg signed [15:0] products [0:NUM_TAPS-1];
    reg               productsValid;
    reg        [1:0]  kernel_select_d;

    genvar g;
    generate
        for (g = 0; g < NUM_TAPS; g = g + 1) begin : MULT
            always @(posedge clk) begin
                // Zero-extend unsigned pixel to signed 9-bit, then multiply by
                // signed 8-bit coefficient to get a correct signed 16-bit product.
                products[g] <= $signed({1'b0, in_pixel_data[g*8 +: 8]}) * kernel_coeff(kernel_select, g);
            end
        end
    endgenerate

    always @(posedge clk)
        productsValid <= in_pixel_data_valid;

    always @(posedge clk)
        kernel_select_d <= kernel_select;

    
    integer i;
    reg signed [19:0] acc;   // combinational accumulator
    reg signed [19:0] normalised;
    reg signed [7:0]  divisor;

    always @(*) begin
        acc = 20'sd0;
        for (i = 0; i < NUM_TAPS; i = i + 1)
            acc = acc + products[i];

        divisor = kernel_divisor(kernel_select_d);
        normalised = acc / $signed(divisor);
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
