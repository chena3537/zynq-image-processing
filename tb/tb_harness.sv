`timescale 1ns / 1ps
// Directed test of the DMA harness: AxisFramer -> ImageProcessTop ->
// AxisDeframer, driven like AXI DMA MM2S (one transfer per frame, tlast on
// its last byte) with random gaps and random S2MM back-pressure.
//
// Checks that the S2MM side sees exactly WIDTH*HEIGHT beats per frame with
// tlast on the last one only, for several back-to-back frames, and that the
// identity kernel returns the input unchanged. Prints HARNESS PASSED/FAILED.
module tb_harness;
    localparam WIDTH  = 16;
    localparam HEIGHT = 8;
    localparam FRAMES = 4;
    localparam N      = WIDTH * HEIGHT;

    logic clk = 0;
    always #5 clk = ~clk;
    logic aresetn = 0;

    // MM2S side
    logic [7:0] mm2s_tdata;
    logic       mm2s_tvalid = 0, mm2s_tready, mm2s_tlast;
    // Framer -> core -> deframer
    logic [7:0] f_tdata, c_tdata;
    logic       f_tvalid, f_tready, f_tuser, f_tlast;
    logic       c_tvalid, c_tready, c_tuser, c_tlast;
    // S2MM side
    logic [7:0] s2mm_tdata;
    logic       s2mm_tvalid, s2mm_tready = 0, s2mm_tlast;
    // AXI-Lite (used once to select the identity kernel)
    logic [4:0]  awaddr = 0;
    logic        awvalid = 0, awready, wvalid = 0, wready, bvalid, bready = 1;
    logic [31:0] wdata = 0;
    logic        arready, rvalid;
    logic [31:0] rdata;
    logic [1:0]  bresp, rresp;
    logic        intr;

    AxisFramer #(.WIDTH(WIDTH)) u_framer (
        .aclk(clk), .aresetn(aresetn),
        .s_axis_tdata(mm2s_tdata), .s_axis_tvalid(mm2s_tvalid),
        .s_axis_tready(mm2s_tready), .s_axis_tlast(mm2s_tlast),
        .m_axis_tdata(f_tdata), .m_axis_tvalid(f_tvalid), .m_axis_tready(f_tready),
        .m_axis_tuser(f_tuser), .m_axis_tlast(f_tlast));

    ImageProcessTop #(.WIDTH(WIDTH), .HEIGHT(HEIGHT), .CHANNELS(1)) u_core (
        .aclk(clk), .aresetn(aresetn),
        .s_axis_tdata(f_tdata), .s_axis_tvalid(f_tvalid), .s_axis_tready(f_tready),
        .s_axis_tuser(f_tuser), .s_axis_tlast(f_tlast),
        .m_axis_tdata(c_tdata), .m_axis_tvalid(c_tvalid), .m_axis_tready(c_tready),
        .m_axis_tuser(c_tuser), .m_axis_tlast(c_tlast),
        .s_axi_ctrl_awaddr(awaddr), .s_axi_ctrl_awvalid(awvalid), .s_axi_ctrl_awready(awready),
        .s_axi_ctrl_wdata(wdata), .s_axi_ctrl_wstrb(4'hF), .s_axi_ctrl_wvalid(wvalid),
        .s_axi_ctrl_wready(wready), .s_axi_ctrl_bresp(bresp), .s_axi_ctrl_bvalid(bvalid),
        .s_axi_ctrl_bready(bready), .s_axi_ctrl_araddr(5'd0), .s_axi_ctrl_arvalid(1'b0),
        .s_axi_ctrl_arready(arready), .s_axi_ctrl_rdata(rdata), .s_axi_ctrl_rresp(rresp),
        .s_axi_ctrl_rvalid(rvalid), .s_axi_ctrl_rready(1'b1),
        .sw(2'b00), .out_intr(intr));

    AxisDeframer #(.HEIGHT(HEIGHT)) u_deframer (
        .aclk(clk), .aresetn(aresetn),
        .s_axis_tdata(c_tdata), .s_axis_tvalid(c_tvalid), .s_axis_tready(c_tready),
        .s_axis_tuser(c_tuser), .s_axis_tlast(c_tlast),
        .m_axis_tdata(s2mm_tdata), .m_axis_tvalid(s2mm_tvalid), .m_axis_tready(s2mm_tready),
        .m_axis_tlast(s2mm_tlast));

    byte unsigned img [FRAMES][N];
    int errors = 0;

    // S2MM: random back-pressure
    always @(posedge clk) s2mm_tready <= ($urandom_range(99) >= 40);

    // MM2S: one transfer per frame, random gaps
    initial begin
        foreach (img[f, i]) img[f][i] = $urandom;
        repeat (10) @(posedge clk);
        aresetn <= 1;
        // CTRL: kernel source = register, kernel 4 (identity)
        @(posedge clk);
        awaddr <= 5'h00; wdata <= 32'h41; awvalid <= 1; wvalid <= 1;
        do @(posedge clk); while (!awready);
        awvalid <= 0; wvalid <= 0;
        repeat (5) @(posedge clk);

        for (int f = 0; f < FRAMES; f++)
            for (int i = 0; i < N; i++) begin
                while ($urandom_range(99) < 25) begin
                    mm2s_tvalid <= 0;
                    @(posedge clk);
                end
                mm2s_tdata  <= img[f][i];
                mm2s_tlast  <= (i == N - 1);
                mm2s_tvalid <= 1;
                do @(posedge clk); while (!mm2s_tready);
                mm2s_tvalid <= 0;
            end
    end

    // S2MM checker
    initial begin
        int f = 0, i = 0;
        @(posedge aresetn);
        while (f < FRAMES) begin
            @(posedge clk);
            if (s2mm_tvalid && s2mm_tready) begin
                if (s2mm_tdata !== img[f][i]) begin
                    if (errors < 10) $display("ERROR frame %0d beat %0d: data %0d, expected %0d",
                                              f, i, s2mm_tdata, img[f][i]);
                    errors++;
                end
                if (s2mm_tlast !== (i == N - 1)) begin
                    if (errors < 10) $display("ERROR frame %0d beat %0d: tlast=%0b", f, i, s2mm_tlast);
                    errors++;
                end
                i++;
                if (i == N) begin
                    i = 0;
                    f++;
                end
            end
        end
        repeat (50) @(posedge clk);
        if (s2mm_tvalid) begin
            $display("ERROR: extra output after %0d frames", FRAMES);
            errors++;
        end
        if (errors == 0)
            $display("HARNESS PASSED");
        else
            $display("HARNESS FAILED (%0d errors)", errors);
        $finish;
    end

    initial begin
        #(FRAMES * N * 10ns * 20);
        $display("HARNESS FAILED (timeout)");
        $finish;
    end
endmodule
