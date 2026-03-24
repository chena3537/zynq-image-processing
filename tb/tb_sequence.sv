class tb_sequence extends uvm_sequence #(tb_transaction);
    `uvm_object_utils(tb_sequence)
    
    string img_path;
    int    unsigned num_pixels;
    
    function new(string name = "tb_sequence");
        super.new(name);
    endfunction
    
    task body();
        tb_transaction tx;
        int file;
        byte unsigned data;
        int unsigned i;
        
        file = $fopen(img_path, "rb");
        if(file == 0)
            `uvm_fatal("SEQ", $sformatf("Could not open image file: %s", img_path))
        
        // Skip header
        for(i = 0; i < 1080; i++) begin
            $fscanf(file, "%c", data);
        end
        
        // Send pixels
        for(i = 0; i < num_pixels; i++) begin
            tx = tb_transaction::type_id::create("tx");
            start_item(tx);
            $fscanf(file, "%c", data);
            tx.tb_data = data;
            finish_item(tx);
        end
        
        for(i = 0; i < 2*512; i++) begin
            tx = tb_transaction::type_id::create("tx");
            start_item(tx);
            tx.tb_data = 8'h00;
            finish_item(tx);
        end
        
        $fclose(file);
    endtask
    
endclass