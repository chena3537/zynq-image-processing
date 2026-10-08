// Test configuration, filled from plusargs by tb_test and shared with all
// components through uvm_config_db.
//
// Plusargs (prepared by scripts/sim/run_sim.py):
//   +DIR=<path>          directory holding stim.raw (all frames back to back)
//                        and expected_f<N>.raw (expected output of frame N);
//                        out.raw is written there
//   +FRAMES=<n>          number of frames to send
//   +KERNELS=<a,b,...>   kernel code per frame (0..4)
//   +GAP_PCT=<p>         chance (%) of an idle input cycle before each pixel
//   +STALL_PCT=<p>       chance (%) that m_axis_tready is low in a cycle
//   +USE_SW              select kernels with the switches instead of CTRL
//   +MIDFRAME            change the kernel in the middle of each frame
//                        (it must apply only from the next frame)
//   +JUNK=<n>            send n pixels without tuser before the first frame
//   +BAD_TLAST_FRAME=<f> put one misplaced tlast in frame f (sync error)
//   +CHECK_RATE          require one output pixel per clock (no stalls)
class tb_config extends uvm_object;
    `uvm_object_utils(tb_config)

    // DUT parameters (from tb_top)
    int width;
    int height;
    int channels;

    string dir;
    int    frames          = 1;
    int    kernels[$];
    int    gap_pct         = 0;
    int    stall_pct       = 0;
    bit    use_sw          = 0;
    bit    midframe        = 0;
    int    junk            = 0;
    int    bad_tlast_frame = -1;
    bit    check_rate      = 0;

    function new(string name = "tb_config");
        super.new(name);
    endfunction

    function void load_plusargs();
        string s;
        if (!$value$plusargs("DIR=%s", dir))
            `uvm_fatal("CFG", "+DIR=<test directory> is required")
        void'($value$plusargs("FRAMES=%d", frames));
        void'($value$plusargs("GAP_PCT=%d", gap_pct));
        void'($value$plusargs("STALL_PCT=%d", stall_pct));
        void'($value$plusargs("JUNK=%d", junk));
        void'($value$plusargs("BAD_TLAST_FRAME=%d", bad_tlast_frame));
        use_sw     = $test$plusargs("USE_SW");
        midframe   = $test$plusargs("MIDFRAME");
        check_rate = $test$plusargs("CHECK_RATE");

        if (!$value$plusargs("KERNELS=%s", s))
            s = "0";
        foreach (s[i])
            if (s[i] >= "0" && s[i] <= "9")
                kernels.push_back(s[i] - "0");
        if (kernels.size() != frames)
            `uvm_fatal("CFG", $sformatf("+KERNELS lists %0d kernels for %0d frames",
                                         kernels.size(), frames))
    endfunction

    function int frame_bytes();
        return width * height * channels;
    endfunction
endclass

// Read `count` bytes starting at `offset` from a binary file. Returns 0 if
// the file cannot be opened or is too short. Uses $fgetc: in this testbench,
// $fread into a dynamic array crashed xsim 2025.2 (the simulator kernel when
// reading into a class property, xelab when the array is a ref argument).
function automatic bit tb_read_bytes(string path, int offset, int count,
                                     ref byte unsigned data[]);
    int fd = $fopen(path, "rb");
    int c;
    if (fd == 0)
        return 0;
    void'($fseek(fd, offset, 0));
    data = new[count];
    for (int i = 0; i < count; i++) begin
        c = $fgetc(fd);
        if (c < 0) begin
            $fclose(fd);
            return 0;
        end
        data[i] = c;
    end
    $fclose(fd);
    return 1;
endfunction
