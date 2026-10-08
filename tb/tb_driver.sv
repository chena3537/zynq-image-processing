// Drives the DUT's AXI4-Stream input. Each beat is held until accepted
// (tvalid && tready); with GAP_PCT > 0, random idle cycles are inserted
// between beats.
class tb_driver extends uvm_driver #(tb_transaction);
    `uvm_component_utils(tb_driver)

    virtual tb_stream_if vif;
    tb_config            cfg;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual tb_stream_if)::get(this, "", "vif", vif))
            `uvm_fatal("NO_VIF", "Driver could not get virtual interface")
        if (!uvm_config_db #(tb_config)::get(this, "", "cfg", cfg))
            `uvm_fatal("NO_CFG", "Driver could not get tb_config")
    endfunction

    task run_phase(uvm_phase phase);
        tb_transaction tx;
        vif.s_tvalid <= 1'b0;
        vif.s_tdata  <= '0;
        vif.s_tuser  <= 1'b0;
        vif.s_tlast  <= 1'b0;
        wait (vif.aresetn === 1'b1);
        forever begin
            seq_item_port.get_next_item(tx);
            while ($urandom_range(99) < cfg.gap_pct) begin
                vif.s_tvalid <= 1'b0;
                @(posedge vif.clk);
            end
            vif.s_tdata  <= tx.data;
            vif.s_tuser  <= tx.user;
            vif.s_tlast  <= tx.last;
            vif.s_tvalid <= 1'b1;
            do @(posedge vif.clk); while (!vif.s_tready);
            vif.s_tvalid <= 1'b0;
            seq_item_port.item_done();
        end
    endtask
endclass
