`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: Conv
//
// Description:
// Applies one of five fixed 3x3 kernels to a stream of windows from
// WindowGen. Each sample carries its own kernel code, so a kernel change
// takes effect exactly at a frame boundary. Channels are processed
// independently with the same kernel.
//
// All kernels are built from three sums over the window (C = centre pixel,
// E = the four edge neighbours, K = the four corners), so no general
// multipliers or dividers are needed:
//
//   code  kernel                           sum r               normalisation
//   0     sharpen [0 -1 0;-1 5 -1;0 -1 0]   5C - E              none
//   1     box blur (all ones) / 9           C + E + K           (r*7282 + 32768) >> 16
//   2     Gaussian [1 2 1;2 4 2;1 2 1]/16   4C + 2E + K         (r + 8) >> 4
//   3     edge [-1 -1 -1;-1 8 -1;-1 -1 -1]  8C - E - K          none
//   4     identity (bypass)                C                   none
//   5-7   reserved, treated as identity
//
// Both blur normalisations equal r / divisor rounded to nearest, halves
// rounded up (verified for every reachable r by scripts/golden_conv.py).
// The result is clamped to [0, 255].
//
// Pipeline latency: 4 cycles, no stalls (valid and sideband travel along).
//   S1: C, E, K       S2: kernel sum r       S3: r * 7282
//   S4: normalise and clamp
//////////////////////////////////////////////////////////////////////////////////

module Conv #(
    parameter CHANNELS = 1
)(
    input  wire                     clk,
    input  wire                     rst,

    input  wire [9*CHANNELS*8-1:0]  in_data,
    input  wire                     in_valid,
    input  wire                     in_user,
    input  wire                     in_last,
    input  wire                     in_eof,
    input  wire [2:0]               in_kernel,

    output wire [CHANNELS*8-1:0]    out_data,
    output reg                      out_valid,
    output reg                      out_user,
    output reg                      out_last,
    output reg                      out_eof
);

    localparam [2:0] K_SHARPEN  = 3'd0;
    localparam [2:0] K_BOX_BLUR = 3'd1;
    localparam [2:0] K_GAUSS    = 3'd2;
    localparam [2:0] K_EDGE     = 3'd3;

    localparam PW = CHANNELS * 8;

    // -------------------------------------------------------------------------
    // Valid, sideband and kernel code pipeline (shared by all channels)
    // -------------------------------------------------------------------------
    reg [3:1] v_p, user_p, last_p, eof_p;
    reg [2:0] k_s1, k_s2, k_s3;

    always @(posedge clk) begin
        if (rst) begin
            v_p       <= 3'b000;
            out_valid <= 1'b0;
        end else begin
            v_p       <= {v_p[2:1], in_valid};
            out_valid <= v_p[3];
        end
        user_p   <= {user_p[2:1], in_user};
        last_p   <= {last_p[2:1], in_last};
        eof_p    <= {eof_p[2:1],  in_eof};
        out_user <= user_p[3];
        out_last <= last_p[3];
        out_eof  <= eof_p[3];
        k_s1     <= in_kernel;
        k_s2     <= k_s1;
        k_s3     <= k_s2;
    end

    // -------------------------------------------------------------------------
    // Per-channel datapath
    // -------------------------------------------------------------------------
    genvar ch;
    generate
        for (ch = 0; ch < CHANNELS; ch = ch + 1) begin : CH
            // Pixel n of the window for this channel
            wire [7:0] p [0:8];
            genvar n;
            for (n = 0; n < 9; n = n + 1) begin : PIX
                assign p[n] = in_data[n*PW + ch*8 +: 8];
            end

            // S1: centre, edge-neighbour sum, corner sum (all unsigned)
            reg [7:0] c_s1;
            reg [9:0] e_s1, k_sum_s1;
            always @(posedge clk) begin
                c_s1     <= p[4];
                e_s1     <= (p[1] + p[3]) + (p[5] + p[7]);
                k_sum_s1 <= (p[0] + p[2]) + (p[6] + p[8]);
            end

            // S2: kernel sum, signed. Range -2040 .. 4080, so 13 bits.
            wire signed [12:0] c = $signed({5'd0, c_s1});
            wire signed [12:0] e = $signed({3'd0, e_s1});
            wire signed [12:0] k = $signed({3'd0, k_sum_s1});
            reg  signed [12:0] r_s2;
            always @(posedge clk) begin
                case (k_s1)
                    K_SHARPEN:  r_s2 <= (c <<< 2) + c - e;
                    K_BOX_BLUR: r_s2 <= c + e + k;
                    K_GAUSS:    r_s2 <= (c <<< 2) + (e <<< 1) + k;
                    K_EDGE:     r_s2 <= (c <<< 3) - e - k;
                    default:    r_s2 <= c;
                endcase
            end

            // S3: reciprocal multiply for the box blur (r <= 2295, so the
            // product fits in 24 bits); r is carried alongside.
            reg signed [12:0] r_s3;
            reg        [23:0] prod_s3;
            always @(posedge clk) begin
                r_s3    <= r_s2;
                prod_s3 <= r_s2[11:0] * 24'd7282;
            end

            // S4: normalise and clamp to [0, 255]
            reg signed [12:0] norm;
            always @(*) begin
                case (k_s3)
                    K_BOX_BLUR: norm = $signed({1'b0, prod_s3[23:16] + prod_s3[15]});
                    K_GAUSS:    norm = (r_s3 + 13'sd8) >>> 4;
                    default:    norm = r_s3;
                endcase
            end

            reg [7:0] y;
            always @(posedge clk) begin
                if (norm < 0)
                    y <= 8'd0;
                else if (norm > 255)
                    y <= 8'd255;
                else
                    y <= norm[7:0];
            end

            assign out_data[ch*8 +: 8] = y;
        end
    endgenerate

endmodule
