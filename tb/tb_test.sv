// Single configurable test (see tb_config for the plusargs). Sends the
// requested frames, selects each frame's kernel through the CTRL register or
// the switches, then checks the status registers, the out_intr count and,
// with +CHECK_RATE, the throughput.
class tb_test extends uvm_test;
    `uvm_component_utils(tb_test)

    localparam bit [4:0] REG_CTRL   = 5'h00;
    localparam bit [4:0] REG_STATUS = 5'h04;
    localparam bit [4:0] REG_FRAMES = 5'h08;
    localparam bit [4:0] REG_INFO   = 5'h0C;

    localparam realtime CLK_PERIOD = 10ns;

    tb_env               env;
    tb_config            cfg;
    virtual tb_stream_if vif;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        cfg = tb_config::type_id::create("cfg");
        if (!uvm_config_db #(int)::get(this, "", "width", cfg.width) ||
            !uvm_config_db #(int)::get(this, "", "height", cfg.height) ||
            !uvm_config_db #(int)::get(this, "", "channels", cfg.channels))
            `uvm_fatal("CFG", "DUT parameters not set by tb_top")
        if (!uvm_config_db #(virtual tb_stream_if)::get(this, "", "vif", vif))
            `uvm_fatal("NO_VIF", "Test could not get virtual interface")
        cfg.load_plusargs();
        uvm_config_db #(tb_config)::set(this, "*", "cfg", cfg);
        env = tb_env::type_id::create("env", this);

        // Watchdog: generous bound on cycles per frame, scaled for stalls
        uvm_top.set_timeout(cfg.frames * (cfg.width + 1) * (cfg.height + 1) * CLK_PERIOD *
                            (4 + cfg.gap_pct / 10 + cfg.stall_pct / 5) + 100us, 0);
        begin
            string opts = "";
            if (cfg.use_sw)     opts = {opts, ", switches"};
            if (cfg.midframe)   opts = {opts, ", mid-frame kernel changes"};
            if (cfg.check_rate) opts = {opts, ", rate check"};
            `uvm_info("TEST", $sformatf("%0dx%0dx%0d, %0d frames, gap %0d%%, stall %0d%%%s",
                                        cfg.width, cfg.height, cfg.channels, cfg.frames,
                                        cfg.gap_pct, cfg.stall_pct, opts), UVM_LOW)
        end
    endfunction

    // Make `kernel` the selection for the next frame to start
    task select_kernel(int kernel);
        if (cfg.use_sw) begin
            vif.sw <= kernel[1:0];
            repeat (4) @(posedge vif.clk);   // through the 2-flop synchroniser
        end else begin
            vif.axil_write(REG_CTRL, {25'd0, kernel[2:0], 3'd0, 1'b1});
        end
    endtask

    task run_phase(uvm_phase phase);
        tb_sequence  seq;
        logic [31:0] value;

        phase.raise_objection(this);
        wait (vif.aresetn === 1'b1);
        repeat (5) @(posedge vif.clk);

        select_kernel(cfg.kernels[0]);

        for (int f = 0; f < cfg.frames; f++) begin
            seq           = tb_sequence::type_id::create($sformatf("frame%0d", f));
            seq.cfg       = cfg;
            seq.frame     = f;
            seq.junk      = (f == 0) ? cfg.junk : 0;
            seq.bad_tlast = (f == cfg.bad_tlast_frame);
            fork
                seq.start(env.agt.seqr);
                if (cfg.midframe && f + 1 < cfg.frames) begin
                    wait (seq.sent >= cfg.width * cfg.height / 2);
                    select_kernel(cfg.kernels[f + 1]);
                end
            join
            if (!cfg.midframe && f + 1 < cfg.frames)
                select_kernel(cfg.kernels[f + 1]);
        end

        wait (env.scb.frames_done == cfg.frames);
        repeat (20) @(posedge vif.clk);

        check_registers();
        if (env.agt.mon.intr_count != cfg.frames)
            `uvm_error("TEST", $sformatf("out_intr pulsed %0d times for %0d frames",
                                         env.agt.mon.intr_count, cfg.frames))
        if (cfg.check_rate)
            check_rate();

        phase.drop_objection(this);
    endtask

    task check_registers();
        logic [31:0] value;
        bit          expect_err = (cfg.bad_tlast_frame >= 0);

        vif.axil_read(REG_FRAMES, value);
        if (value != cfg.frames)
            `uvm_error("TEST", $sformatf("FRAMES register = %0d, expected %0d", value, cfg.frames))

        vif.axil_read(REG_INFO, value);
        if (value != {cfg.height[15:0], cfg.width[15:0]})
            `uvm_error("TEST", $sformatf("INFO register = 0x%08h", value))

        vif.axil_read(REG_STATUS, value);
        if (value[0] != expect_err)
            `uvm_error("TEST", $sformatf("STATUS.sync_error = %0b, expected %0b", value[0], expect_err))
        if (value[1] != 1'b0)
            `uvm_error("TEST", "STATUS.in_frame still set after the last frame")
        if (expect_err) begin
            vif.axil_write(REG_STATUS, 32'h1);
            vif.axil_read(REG_STATUS, value);
            if (value[0] != 1'b0)
                `uvm_error("TEST", "STATUS.sync_error did not clear on write-1")
        end
    endtask

    // Steady-state frame period must not exceed the slot count (one extra
    // column per line, one extra line per frame) plus a little slack.
    task check_rate();
        realtime limit = ((cfg.width + 1) * (cfg.height + 1) + 16) * CLK_PERIOD;
        for (int f = 1; f < env.scb.frame_end_time.size(); f++) begin
            realtime period = env.scb.frame_end_time[f] - env.scb.frame_end_time[f - 1];
            if (period > limit)
                `uvm_error("TEST", $sformatf("frame %0d took %0t, limit %0t", f, period, limit))
            else
                `uvm_info("TEST", $sformatf("frame %0d period %0d cycles (%0d pixels)", f,
                                            int'(period / CLK_PERIOD), cfg.width * cfg.height),
                          UVM_LOW)
        end
    endtask

    function void report_phase(uvm_phase phase);
        uvm_report_server srv = uvm_report_server::get_server();
        if (srv.get_severity_count(UVM_ERROR) == 0 && srv.get_severity_count(UVM_FATAL) == 0)
            `uvm_info("TEST", "TEST PASSED", UVM_NONE)
        else
            `uvm_info("TEST", "TEST FAILED", UVM_NONE)
    endfunction
endclass
