class tb_agent extends uvm_agent;
    `uvm_component_utils(tb_agent)
    
    tb_driver   drv;
    tb_monitor  mon;
    uvm_sequencer #(tb_transaction) seqr;
    
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        drv  = tb_driver::type_id::create("drv", this);
        mon  = tb_monitor::type_id::create("mon", this);
        seqr = uvm_sequencer #(tb_transaction)::type_id::create("seqr", this);
    endfunction
    
    function void connect_phase(uvm_phase phase);
        drv.seq_item_port.connect(seqr.seq_item_export);
    endfunction
    
endclass