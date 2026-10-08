// One AXI4-Stream Video beat (one pixel).
class tb_transaction extends uvm_sequence_item;
    `uvm_object_utils(tb_transaction)

    bit [23:0] data;     // channel 0 in bits [7:0]
    bit        user;     // start of frame
    bit        last;     // end of line

    function new(string name = "tb_transaction");
        super.new(name);
    endfunction

    function string convert2string();
        return $sformatf("data=0x%06h user=%0b last=%0b", data, user, last);
    endfunction
endclass
