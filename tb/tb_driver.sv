class tb_driver extends uvm_driver #(tb_transaction);
    `uvm_component_utils(tb_driver)
    
    virtual tb_stream_if vif;
    
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if(!uvm_config_db #(virtual tb_stream_if)::get(this, "", "vif", vif))
            `uvm_fatal("NO_VIF", "Driver could not get virtual interface")
    endfunction
    
    task run_phase(uvm_phase phase);
        tb_transaction tx;
        vif.in_data_valid <= 0;
        vif.in_data       <= 0;
        `uvm_info("DRV", "Waiting for reset", UVM_LOW)
        @(posedge vif.rst);
        `uvm_info("DRV", "Reset released, starting to drive", UVM_LOW)
        forever begin
            seq_item_port.get_next_item(tx);
            @(posedge vif.clk);
            vif.in_data       <= tx.tb_data;
            vif.in_data_valid <= 1;
            @(posedge vif.clk);
            vif.in_data_valid <= 0;
            seq_item_port.item_done();
        end
    endtask
endclass