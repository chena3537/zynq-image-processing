class tb_monitor extends uvm_monitor;
    `uvm_component_utils(tb_monitor)
    
    virtual tb_stream_if vif;
    uvm_analysis_port #(tb_transaction) ap;
    
    int input_file;
    int output_file;
    
    
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        ap = new("ap", this);
        if(!uvm_config_db #(virtual tb_stream_if)::get(this, "", "vif", vif))
            `uvm_fatal("NO_VIF", "Monitor could not get virtual interface")
    endfunction
    
    task run_phase(uvm_phase phase);
        tb_transaction tx;
        byte unsigned header_byte;
        int i;
        
        `uvm_info("MON", "run_phase started", UVM_LOW)
        
        input_file = $fopen("input.bmp", "rb");
        if(input_file == 0)
            `uvm_fatal("MON", "Monitor could not open input.bmp to read header")
        `uvm_info("MON", "input.bmp opened successfully", UVM_LOW)
        
        output_file = $fopen("output.bmp", "wb");
        if(output_file == 0)
            `uvm_fatal("MON", "Monitor could not open output.bmp for writing")
        `uvm_info("MON", "output.bmp opened successfully", UVM_LOW)
        
        for(i = 0; i < 1080; i++) begin
            $fscanf(input_file, "%c", header_byte);
            $fwrite(output_file, "%c", header_byte);
        end
        $fclose(input_file);
        `uvm_info("MON", "Header copied successfully", UVM_LOW)
        
        forever begin
            @(posedge vif.clk);
            if(vif.out_data_valid) begin
                tx = tb_transaction::type_id::create("tx");
                tx.tb_data = vif.out_data;
                $fwrite(output_file, "%c", tx.tb_data);
                ap.write(tx);
            end
        end 
    endtask
    
    function void final_phase(uvm_phase phase);
        super.final_phase(phase);
        $fclose(output_file);
    endfunction
    
endclass