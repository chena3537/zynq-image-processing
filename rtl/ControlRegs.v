`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: ControlRegs
//
// Description:
// AXI4-Lite control/status registers for ImageProcessTop. Runs on the
// pixel clock; in a block design with a different AXI clock, the
// interconnect (SmartConnect) performs the clock conversion.
//
// Register map (32-bit, byte addresses):
//   0x00 CTRL    [0]   kernel source: 0 = board switches, 1 = KERNEL field
//                [6:4] kernel when source = 1:
//                      0 sharpen, 1 box blur, 2 Gaussian, 3 edge, 4 identity
//   0x04 STATUS  [0]   sync error seen (sticky; write 1 to clear)
//                [1]   frame in progress (read only)
//   0x08 FRAMES  number of frames output since reset (read only, wraps)
//   0x0C INFO    [15:0] WIDTH, [31:16] HEIGHT (read only)
//
// Kernel changes take effect at the next start of frame.
// Writes ignore WSTRB (all registers are written as whole words).
//////////////////////////////////////////////////////////////////////////////////

module ControlRegs #(
    parameter WIDTH  = 512,
    parameter HEIGHT = 512
)(
    input  wire        clk,
    input  wire        rst,

    // AXI4-Lite slave
    input  wire [4:0]  s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output reg         s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output reg         s_axi_wready,
    output wire [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [4:0]  s_axi_araddr,
    input  wire        s_axi_arvalid,
    output reg         s_axi_arready,
    output reg  [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,

    // Core interface
    input  wire [1:0]  sw_sync,        // board switches, already synchronised
    output wire [2:0]  kernel_sel,
    input  wire        sync_err,       // one-cycle pulse
    input  wire        in_frame,
    input  wire        frame_done      // one-cycle pulse per output frame
);

    localparam ADDR_CTRL   = 3'd0;
    localparam ADDR_STATUS = 3'd1;
    localparam ADDR_FRAMES = 3'd2;
    localparam ADDR_INFO   = 3'd3;

    reg        kernel_from_reg;
    reg [2:0]  kernel_reg;
    reg        sync_err_sticky;
    reg [31:0] frame_count;

    assign kernel_sel  = kernel_from_reg ? kernel_reg : {1'b0, sw_sync};
    assign s_axi_bresp = 2'b00;
    assign s_axi_rresp = 2'b00;

    // -------------------------------------------------------------------------
    // Write channel: wait for address and data together, raise both READYs
    // for one cycle (the handshake), then respond on B in the next cycle.
    // -------------------------------------------------------------------------
    wire do_write = s_axi_awready && s_axi_awvalid && s_axi_wready && s_axi_wvalid;
    wire [2:0] waddr = s_axi_awaddr[4:2];

    always @(posedge clk) begin
        if (rst) begin
            s_axi_awready   <= 1'b0;
            s_axi_wready    <= 1'b0;
            s_axi_bvalid    <= 1'b0;
            kernel_from_reg <= 1'b0;
            kernel_reg      <= 3'd0;
            sync_err_sticky <= 1'b0;
        end else begin
            s_axi_awready <= !s_axi_awready && s_axi_awvalid && s_axi_wvalid && !s_axi_bvalid;
            s_axi_wready  <= !s_axi_awready && s_axi_awvalid && s_axi_wvalid && !s_axi_bvalid;

            if (do_write)
                s_axi_bvalid <= 1'b1;
            else if (s_axi_bready)
                s_axi_bvalid <= 1'b0;

            if (do_write && waddr == ADDR_CTRL) begin
                kernel_from_reg <= s_axi_wdata[0];
                kernel_reg      <= s_axi_wdata[6:4];
            end

            // Set wins over a simultaneous clear
            if (sync_err)
                sync_err_sticky <= 1'b1;
            else if (do_write && waddr == ADDR_STATUS && s_axi_wdata[0])
                sync_err_sticky <= 1'b0;
        end
    end

    always @(posedge clk) begin
        if (rst)
            frame_count <= 32'd0;
        else if (frame_done)
            frame_count <= frame_count + 1'b1;
    end

    // -------------------------------------------------------------------------
    // Read channel: one-cycle ARREADY, data returned in the following cycle
    // -------------------------------------------------------------------------
    wire do_read = s_axi_arready && s_axi_arvalid;

    always @(posedge clk) begin
        if (rst) begin
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rdata   <= 32'd0;
        end else begin
            s_axi_arready <= !s_axi_arready && s_axi_arvalid && !s_axi_rvalid;

            if (do_read) begin
                s_axi_rvalid <= 1'b1;
                case (s_axi_araddr[4:2])
                    ADDR_CTRL:   s_axi_rdata <= {25'd0, kernel_reg, 3'd0, kernel_from_reg};
                    ADDR_STATUS: s_axi_rdata <= {30'd0, in_frame, sync_err_sticky};
                    ADDR_FRAMES: s_axi_rdata <= frame_count;
                    ADDR_INFO:   s_axi_rdata <= {HEIGHT[15:0], WIDTH[15:0]};
                    default:     s_axi_rdata <= 32'd0;
                endcase
            end else if (s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

endmodule
