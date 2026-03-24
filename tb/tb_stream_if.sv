interface tb_stream_if(input logic clk);
    logic        rst;
    logic [7:0]  in_data;
    logic        in_data_valid;
    logic        out_data_ready;
    logic [7:0]  out_data;
    logic        out_data_valid;
    logic        in_data_ready;
    logic        out_intr;
endinterface