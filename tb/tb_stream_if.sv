// Signals of ImageProcessTop as seen by the testbench, plus AXI4-Lite access
// tasks used by the test. Pixel buses are 24 bits wide (enough for RGB);
// with CHANNELS = 1 only the low byte is used.
interface tb_stream_if (input logic clk);
    logic        aresetn;
    logic [1:0]  sw;
    logic        out_intr;

    // AXI4-Stream Video into the DUT
    logic [23:0] s_tdata;
    logic        s_tvalid;
    logic        s_tready;
    logic        s_tuser;
    logic        s_tlast;

    // AXI4-Stream Video out of the DUT
    logic [23:0] m_tdata;
    logic        m_tvalid;
    logic        m_tready;
    logic        m_tuser;
    logic        m_tlast;

    // AXI4-Lite control port
    logic [4:0]  awaddr;
    logic        awvalid;
    logic        awready;
    logic [31:0] wdata;
    logic [3:0]  wstrb;
    logic        wvalid;
    logic        wready;
    logic [1:0]  bresp;
    logic        bvalid;
    logic        bready;
    logic [4:0]  araddr;
    logic        arvalid;
    logic        arready;
    logic [31:0] rdata;
    logic [1:0]  rresp;
    logic        rvalid;
    logic        rready;

    task automatic axil_write(input logic [4:0] addr, input logic [31:0] data);
        @(posedge clk);
        awaddr  <= addr;
        awvalid <= 1'b1;
        wdata   <= data;
        wstrb   <= 4'hF;
        wvalid  <= 1'b1;
        bready  <= 1'b1;
        fork
            begin
                do @(posedge clk); while (!awready);
                awvalid <= 1'b0;
            end
            begin
                do @(posedge clk); while (!wready);
                wvalid <= 1'b0;
            end
        join
        while (!bvalid) @(posedge clk);
        @(posedge clk);
        bready <= 1'b0;
    endtask

    task automatic axil_read(input logic [4:0] addr, output logic [31:0] data);
        @(posedge clk);
        araddr  <= addr;
        arvalid <= 1'b1;
        rready  <= 1'b1;
        do @(posedge clk); while (!arready);
        arvalid <= 1'b0;
        while (!rvalid) @(posedge clk);
        data = rdata;
        @(posedge clk);
        rready <= 1'b0;
    endtask
endinterface
