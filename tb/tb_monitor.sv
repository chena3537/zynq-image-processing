// Observes the DUT's AXI4-Stream output: every accepted beat is written to
// <DIR>/out.raw and sent to the scoreboard. Also counts out_intr pulses.
class tb_monitor extends uvm_monitor;
    `uvm_component_utils(tb_monitor)

    virtual tb_stream_if vif;
    tb_config            cfg;
    uvm_analysis_port #(tb_transaction) ap;

    int intr_count;
    int out_file;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        ap = new("ap", this);
        if (!uvm_config_db #(virtual tb_stream_if)::get(this, "", "vif", vif))
            `uvm_fatal("NO_VIF", "Monitor could not get virtual interface")
        if (!uvm_config_db #(tb_config)::get(this, "", "cfg", cfg))
            `uvm_fatal("NO_CFG", "Monitor could not get tb_config")
    endfunction

    task run_phase(uvm_phase phase);
        tb_transaction tx;
        out_file = $fopen({cfg.dir, "/out.raw"}, "wb");
        if (out_file == 0)
            `uvm_fatal("MON", $sformatf("cannot create %s/out.raw", cfg.dir))
        forever begin
            @(posedge vif.clk);
            if (vif.aresetn !== 1'b1)
                continue;
            if (vif.out_intr === 1'b1)
                intr_count++;
            if (vif.m_tvalid === 1'b1 && vif.m_tready === 1'b1) begin
                tx = tb_transaction::type_id::create("tx");
                tx.data = vif.m_tdata;
                tx.user = vif.m_tuser;
                tx.last = vif.m_tlast;
                for (int c = 0; c < cfg.channels; c++)
                    $fwrite(out_file, "%c", tx.data[c*8 +: 8]);
                ap.write(tx);
                if ($isunknown({vif.m_tdata, vif.m_tuser, vif.m_tlast}))
                    `uvm_error("MON", "X/Z on m_axis during a transfer")
            end
        end
    endtask

    function void final_phase(uvm_phase phase);
        super.final_phase(phase);
        if (out_file != 0)
            $fclose(out_file);
    endfunction
endclass
