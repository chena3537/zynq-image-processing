// Sends one frame from stim.raw as AXI4-Stream Video beats (tuser on the
// first pixel, tlast on the last pixel of each line), optionally preceded by
// junk pixels and with one deliberately misplaced tlast.
class tb_sequence extends uvm_sequence #(tb_transaction);
    `uvm_object_utils(tb_sequence)

    tb_config cfg;
    int       frame;            // index of the frame in stim.raw
    int       junk;             // pixels without tuser to send first
    bit       bad_tlast;        // misplace one tlast in this frame
    int       sent;             // pixels of the frame sent so far

    function new(string name = "tb_sequence");
        super.new(name);
    endfunction

    task body();
        tb_transaction tx;
        byte unsigned  pix[];
        int            bpp = cfg.channels;

        if (!tb_read_bytes({cfg.dir, "/stim.raw"}, frame * cfg.frame_bytes(),
                           cfg.frame_bytes(), pix))
            `uvm_fatal("SEQ", $sformatf("cannot read frame %0d from %s/stim.raw", frame, cfg.dir))

        for (int i = 0; i < junk; i++) begin
            tx = tb_transaction::type_id::create("junk");
            start_item(tx);
            tx.data = $urandom;
            tx.user = 0;
            tx.last = (i % 5 == 4);
            finish_item(tx);
        end

        sent = 0;
        for (int y = 0; y < cfg.height; y++) begin
            for (int x = 0; x < cfg.width; x++) begin
                int base = (y * cfg.width + x) * bpp;
                tx = tb_transaction::type_id::create("tx");
                start_item(tx);
                tx.data = 0;
                for (int c = 0; c < bpp; c++)
                    tx.data[c*8 +: 8] = pix[base + c];
                tx.user = (x == 0 && y == 0);
                tx.last = (x == cfg.width - 1);
                if (bad_tlast && y == cfg.height / 2 && x == cfg.width / 2)
                    tx.last = !tx.last;
                finish_item(tx);
                sent++;
            end
        end
    endtask
endclass
