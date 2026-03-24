class tb_transaction extends uvm_sequence_item;
    `uvm_object_utils(tb_transaction)
    
    rand bit [7:0] tb_data;
    
    function new(string name = "tb_transaction");
        super.new(name);
    endfunction
    
    function string convert2string();
        return $sformatf("tb_data=0x%0h", tb_data);
    endfunction
endclass
