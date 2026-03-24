class tb_env extends uvm_env;
    `uvm_component_utils(tb_env)
    
    tb_agent      agt;
    tb_scoreboard scb;
    
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        agt = tb_agent::type_id::create("agt", this);
        scb = tb_scoreboard::type_id::create("scb", this);
    endfunction
    
    function void connect_phase(uvm_phase phase);
        agt.mon.ap.connect(scb.analysis_export);
    endfunction
    
endclass