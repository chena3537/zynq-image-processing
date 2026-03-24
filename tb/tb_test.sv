class tb_test extends uvm_test;
    `uvm_component_utils(tb_test)
    
    tb_env env;
    tb_sequence seq;
    
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = tb_env::type_id::create("env", this);
    endfunction
    
    task run_phase(uvm_phase phase);
        seq = tb_sequence::type_id::create("seq");
        seq.img_path   = "input.bmp";
        seq.num_pixels = 512*512;
        phase.raise_objection(this);
        seq.start(env.agt.seqr);
        @(env.scb.all_pixels_received);
        $fflush();
        phase.drop_objection(this);
    endtask
    
endclass
