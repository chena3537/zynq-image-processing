// Drives m_axis_tready: always ready, or randomly low STALL_PCT% of cycles
// to exercise back-pressure.
class tb_sink extends uvm_component;
    `uvm_component_utils(tb_sink)

    virtual tb_stream_if vif;
    tb_config            cfg;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual tb_stream_if)::get(this, "", "vif", vif))
            `uvm_fatal("NO_VIF", "Sink could not get virtual interface")
        if (!uvm_config_db #(tb_config)::get(this, "", "cfg", cfg))
            `uvm_fatal("NO_CFG", "Sink could not get tb_config")
    endfunction

    task run_phase(uvm_phase phase);
        forever begin
            vif.m_tready <= ($urandom_range(99) >= cfg.stall_pct);
            @(posedge vif.clk);
        end
    endtask
endclass
