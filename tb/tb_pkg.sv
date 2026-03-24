`include "uvm_macros.svh"
import uvm_pkg::*;

package tb_pkg;
    import uvm_pkg::*;
    
    `include "tb_transaction.sv"
    `include "tb_driver.sv"
    `include "tb_monitor.sv"
    `include "tb_scoreboard.sv"
    `include "tb_agent.sv"
    `include "tb_env.sv"
    `include "tb_sequence.sv"
    `include "tb_test.sv"
endpackage