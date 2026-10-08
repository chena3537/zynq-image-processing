// Compares the DUT output bit-exactly against expected_f<N>.raw (produced by
// scripts/golden_conv.py) and checks that tuser marks the first pixel of each
// frame and tlast the last pixel of each line.
class tb_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(tb_scoreboard)

    localparam int MAX_REPORTS = 10;

    uvm_analysis_imp #(tb_transaction, tb_scoreboard) analysis_export;
    tb_config cfg;

    byte unsigned expected[];
    int           frame;          // frame currently being received
    int           index;          // pixel index within the frame
    int           frames_done;
    int           mismatches;
    int           sideband_errors;
    realtime      frame_end_time[$];

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        analysis_export = new("analysis_export", this);
        if (!uvm_config_db #(tb_config)::get(this, "", "cfg", cfg))
            `uvm_fatal("NO_CFG", "Scoreboard could not get tb_config")
    endfunction

    function void start_of_simulation_phase(uvm_phase phase);
        load_expected(0);
    endfunction

    function void load_expected(int f);
        string path = $sformatf("%s/expected_f%0d.raw", cfg.dir, f);
        if (!tb_read_bytes(path, 0, cfg.frame_bytes(), expected))
            `uvm_fatal("SCB", $sformatf("cannot read %0d bytes from %s", cfg.frame_bytes(), path))
    endfunction

    function void write(tb_transaction tx);
        int x = index % cfg.width;
        int y = index / cfg.width;

        if (frame >= cfg.frames) begin
            `uvm_error("SCB", $sformatf("unexpected output beat after %0d frames: %s",
                                         cfg.frames, tx.convert2string()))
            return;
        end

        if (tx.user != (index == 0) || tx.last != (x == cfg.width - 1)) begin
            if (sideband_errors < MAX_REPORTS)
                `uvm_error("SCB", $sformatf("frame %0d (%0d,%0d): tuser=%0b tlast=%0b, expected %0b %0b",
                                            frame, x, y, tx.user, tx.last,
                                            index == 0, x == cfg.width - 1))
            sideband_errors++;
        end

        for (int c = 0; c < cfg.channels; c++) begin
            byte unsigned exp = expected[index * cfg.channels + c];
            byte unsigned got = tx.data[c*8 +: 8];
            if (got != exp) begin
                if (mismatches < MAX_REPORTS)
                    `uvm_error("SCB", $sformatf("frame %0d (%0d,%0d) ch%0d: got %0d, expected %0d",
                                                frame, x, y, c, got, exp))
                mismatches++;
            end
        end

        index++;
        if (index == cfg.width * cfg.height) begin
            frame_end_time.push_back($realtime);
            `uvm_info("SCB", $sformatf("frame %0d complete (kernel %0d)", frame, cfg.kernels[frame]),
                      UVM_LOW)
            index = 0;
            frame++;
            frames_done = frame;
            if (frame < cfg.frames)
                load_expected(frame);
        end
    endfunction

    function void check_phase(uvm_phase phase);
        super.check_phase(phase);
        if (frames_done != cfg.frames)
            `uvm_error("SCB", $sformatf("received %0d of %0d frames (%0d extra pixels)",
                                        frames_done, cfg.frames, index))
        if (mismatches > 0)
            `uvm_error("SCB", $sformatf("%0d pixel mismatches against the golden model", mismatches))
        if (sideband_errors > 0)
            `uvm_error("SCB", $sformatf("%0d tuser/tlast errors", sideband_errors))
        `uvm_info("SCB", $sformatf("frames %0d/%0d, pixel mismatches %0d, sideband errors %0d",
                                   frames_done, cfg.frames, mismatches, sideband_errors), UVM_LOW)
    endfunction
endclass
