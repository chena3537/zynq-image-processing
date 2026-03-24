`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 03/01/2026 01:14:37 AM
// Design Name: 
// Module Name: tb_scoreboard
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


class tb_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(tb_scoreboard)
    
    uvm_analysis_imp #(tb_transaction, tb_scoreboard) analysis_export;
    
    int unsigned pixels_out;
    int unsigned x_z_errors;
    event all_pixels_received;
    
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        analysis_export = new("analysis_export", this);
        pixels_out = 0;
        x_z_errors = 0;
    endfunction
    
    // Called by monitor via ap.write()
    function void write(tb_transaction tx);
        pixels_out++;
        if($isunknown(tx.tb_data)) begin
            x_z_errors++;
            `uvm_error("SCOREBOARD", $sformatf("X/Z detected on output: pixel %0d", pixels_out))
        end
        if(pixels_out % 10000 == 0)
            `uvm_info("SCOREBOARD", $sformatf("Pixels received so far: %0d", pixels_out), UVM_LOW)
        if(pixels_out == 262144)
            ->all_pixels_received;
    endfunction
    
    function void check_phase(uvm_phase phase);
        super.check_phase(phase);
        `uvm_info("SCOREBOARD", $sformatf("Pixels Received: %0d  X/Z errors: %0d",
                  pixels_out, x_z_errors), UVM_LOW)
        if(pixels_out !== 32'd262144)
            `uvm_error("SCOREBOARD", $sformatf("Pixel count mismatch! Expected 262144, got %0d", pixels_out))
        if(x_z_errors > 0)
            `uvm_error("SCOREBOARD", "X/Z errors detected in output stream")
        else
            `uvm_info("SCOREBOARD", "PASS - all checks completed successfully", UVM_LOW)
    endfunction
    
endclass