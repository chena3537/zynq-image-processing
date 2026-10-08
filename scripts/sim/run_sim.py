"""
run_sim.py

UVM regression for ImageProcessTop using Vivado's simulator (xvlog / xelab /
xsim) directly, without a Vivado project.

For each test it generates the stimulus and the expected output of every
frame with scripts/golden_conv.py, runs the testbench, and checks the UVM
report. The DUT is compiled once per (WIDTH, HEIGHT, CHANNELS) and reused.

Usage (from the repo root):
    python scripts/sim/run_sim.py                  # all tests
    python scripts/sim/run_sim.py small_stress     # selected tests
    python scripts/sim/run_sim.py --list
    python scripts/sim/run_sim.py --waves small_kernels

Outputs go to build/sim/<test>/: stim.raw, expected_f<N>.raw, out.raw,
xsim.log, and out_f<N>.bmp for tests that use tb/input.bmp. With --waves,
waves.wdb can be opened in Vivado (Flow > Open Static Simulation).

Environment: XILINX_VIVADO selects the Vivado install
(default C:/AMDDesignTools/2025.2/Vivado). Exit code 1 if any test fails.
"""

import argparse
import os
import random
import re
import subprocess
import sys
import time

# Forward slashes throughout: xsim treats backslashes in plusargs as escapes.
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..")).replace("\\", "/")
sys.path.insert(0, os.path.join(REPO_ROOT, "scripts"))
import golden_conv as golden  # noqa: E402

VIVADO   = os.environ.get("XILINX_VIVADO", r"C:\AMDDesignTools\2025.2\Vivado")
TOOL_EXT = ".bat" if os.name == "nt" else ""
BUILD    = REPO_ROOT + "/build/sim"
IMAGE    = REPO_ROOT + "/tb/input.bmp"

# Each frame is (image source, kernel). Sources: "rand" (random pixels),
# "bmp" (tb/input.bmp), "bmp_inv" (tb/input.bmp inverted).
TESTS = [
    dict(name="small_kernels", size=(16, 8, 1), check_rate=True,
         frames=[("rand", k) for k in (0, 1, 2, 3, 4)],
         doc="every kernel, back-to-back frames, full rate"),
    dict(name="small_stress", size=(16, 8, 1), gap=30, stall=50,
         frames=[("rand", k) for k in (3, 1, 4, 0, 2, 2, 1, 3)],
         doc="random input gaps and output back-pressure"),
    dict(name="small_midframe", size=(16, 8, 1), gap=10, stall=20, midframe=True,
         frames=[("rand", k) for k in (1, 3, 0, 2)],
         doc="kernel register written mid-frame applies from the next frame"),
    dict(name="small_switches", size=(16, 8, 1), use_sw=True,
         frames=[("rand", k) for k in (2, 0, 3, 1)],
         doc="kernel selected by the board switches"),
    dict(name="small_sync", size=(16, 8, 1), junk=37, bad_tlast_frame=1,
         frames=[("rand", k) for k in (0, 2, 3)],
         doc="junk before the first tuser; misplaced tlast sets STATUS"),
    dict(name="odd_size", size=(13, 7, 1), gap=20, stall=20,
         frames=[("rand", k) for k in (1, 3, 2)],
         doc="non-power-of-two frame size"),
    dict(name="rgb_stress", size=(16, 8, 3), gap=20, stall=30,
         frames=[("rand", k) for k in (0, 1, 2, 3, 4)],
         doc="3-channel (RGB) core"),
    dict(name="image_kernels", size=(512, 512, 1), check_rate=True,
         frames=[("bmp", k) for k in (0, 1, 2, 3, 4)],
         doc="tb/input.bmp through every kernel at full rate"),
    dict(name="image_stress", size=(512, 512, 1), gap=25, stall=40,
         frames=[("bmp", 2), ("bmp_inv", 3)],
         doc="512x512 frames with gaps and back-pressure"),
    dict(name="hd_rgb", size=(1280, 720, 3), check_rate=True,
         frames=[("rand", 2), ("rand", 3)],
         doc="720p RGB at full rate (HDMI configuration)"),
    # Directed (non-UVM) tests: a self-checking top module that prints a marker
    dict(name="dma_harness", directed="tb_harness", marker="HARNESS PASSED",
         doc="AxisFramer -> core -> AxisDeframer, as used with the AXI DMA"),
]


def tool(name):
    return VIVADO.replace("\\", "/") + "/bin/" + name + TOOL_EXT


def command_line(args):
    """The Xilinx tools are .bat wrappers on Windows, and cmd splits batch
    arguments at '=', ',' and ';'. Quote such arguments (and ones with
    spaces) so they reach the tool intact."""
    if os.name != "nt":
        return args
    return " ".join(f'"{a}"' if any(c in a for c in ' =,;') else a for a in args)


def run(cmd, cwd, log_name):
    """Run a tool; return (ok, output). Output is also saved in cwd/log_name."""
    proc = subprocess.run(command_line(cmd), cwd=cwd, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, text=True, errors="replace")
    with open(os.path.join(cwd, log_name), "w") as f:
        f.write(proc.stdout)
    return proc.returncode == 0, proc.stdout


def rtl_sources():
    """All Verilog under rtl/, including subdirectories such as rtl/harness."""
    files = []
    for root, _, names in os.walk(REPO_ROOT + "/rtl"):
        files += [root.replace("\\", "/") + "/" + n for n in names if n.endswith(".v")]
    return sorted(files)


def compile_snapshot(width, height, channels, waves):
    """Compile RTL + testbench for one DUT size; return (snapshot dir, error)."""
    cfg = f"{width}x{height}x{channels}" + ("_waves" if waves else "")
    work = BUILD + "/_compile/" + cfg
    os.makedirs(work, exist_ok=True)

    tb_dir = REPO_ROOT + "/tb"
    steps = [
        ([tool("xvlog")] + rtl_sources(), "xvlog_rtl.log"),
        ([tool("xvlog"), "-sv", "-L", "uvm", "-i", tb_dir,
          tb_dir + "/tb_top.sv"], "xvlog_tb.log"),
        ([tool("xelab"), "tb_top", "-L", "uvm", "-s", "tb", "-timescale", "1ns/1ps",
          "-debug", "typical" if waves else "off",
          "-generic_top", f"WIDTH={width}",
          "-generic_top", f"HEIGHT={height}",
          "-generic_top", f"CHANNELS={channels}"], "xelab.log"),
    ]
    for cmd, log in steps:
        ok, out = run(cmd, work, log)
        if not ok:
            errors = [l for l in out.splitlines() if "ERROR" in l]
            return work, "\n".join(errors[:20]) or f"{log} failed"
    return work, None


def run_directed(test, waves):
    """Compile and run a self-checking top module; pass on its marker line."""
    top = test["directed"]
    tdir = BUILD + "/" + test["name"]
    work = BUILD + "/_compile/" + top + ("_waves" if waves else "")
    os.makedirs(tdir, exist_ok=True)
    os.makedirs(work, exist_ok=True)
    steps = [
        ([tool("xvlog")] + rtl_sources(), "xvlog_rtl.log"),
        ([tool("xvlog"), "-sv", REPO_ROOT + "/tb/" + top + ".sv"], "xvlog_tb.log"),
        ([tool("xelab"), top, "-s", top, "-timescale", "1ns/1ps",
          "-debug", "typical" if waves else "off"], "xelab.log"),
    ]
    for cmd, log in steps:
        ok, out = run(cmd, work, log)
        if not ok:
            errors = [l for l in out.splitlines() if "ERROR" in l]
            return False, f"compile failed ({work}):\n" + ("\n".join(errors[:20]) or log)
    cmd = [tool("xsim"), top, "-log", tdir + "/xsim.log"]
    if waves:
        with open(tdir + "/waves.tcl", "w") as f:
            f.write("log_wave -recursive *\nrun all\nquit\n")
        cmd += ["-wdb", tdir + "/waves.wdb", "-tclbatch", tdir + "/waves.tcl"]
    else:
        cmd += ["-R"]
    run(cmd, work, "xsim_" + test["name"] + ".log")
    log = open(tdir + "/xsim.log", errors="replace").read() if os.path.exists(tdir + "/xsim.log") else ""
    if test["marker"] in log:
        return True, ""
    problems = [l.strip() for l in log.splitlines() if "ERROR" in l or "FAILED" in l]
    return False, "\n".join(problems[:15]) or f"no result; see {tdir}/xsim.log"


def make_frames(test, seed):
    width, height, channels = test["size"]
    rng = random.Random(seed)
    images = {}
    if any(src.startswith("bmp") for src, _ in test["frames"]):
        header, w, h, pixels = golden.read_bmp(IMAGE)
        if (w, h, channels) != (width, height, 1):
            raise ValueError(f"{IMAGE} is {w}x{h}, test needs {width}x{height}x{channels}")
        images["bmp"] = pixels
        images["bmp_inv"] = bytes(255 - p for p in pixels)
        images["header"] = header

    stim = bytearray()
    expected = []
    for src, kernel in test["frames"]:
        if src == "rand":
            img = bytes(rng.getrandbits(8) for _ in range(width * height * channels))
        else:
            img = images[src]
        stim += img
        expected.append(golden.convolve(img, width, height, kernel, channels))
    return bytes(stim), expected, images.get("header")


def run_test(test, seed, waves):
    if "directed" in test:
        return run_directed(test, waves)
    width, height, channels = test["size"]
    tdir = BUILD + "/" + test["name"]
    os.makedirs(tdir, exist_ok=True)
    for f in os.listdir(tdir):
        os.remove(os.path.join(tdir, f))

    stim, expected, bmp_header = make_frames(test, seed)
    with open(os.path.join(tdir, "stim.raw"), "wb") as f:
        f.write(stim)
    for n, exp in enumerate(expected):
        with open(os.path.join(tdir, f"expected_f{n}.raw"), "wb") as f:
            f.write(exp)

    snapshot, err = compile_snapshot(width, height, channels, waves)
    if err:
        return False, f"compile failed ({snapshot}):\n{err}"

    kernels = ",".join(str(k) for _, k in test["frames"])
    plusargs = [f"DIR={tdir}", f"FRAMES={len(test['frames'])}", f"KERNELS={kernels}",
                f"GAP_PCT={test.get('gap', 0)}", f"STALL_PCT={test.get('stall', 0)}",
                f"JUNK={test.get('junk', 0)}",
                f"BAD_TLAST_FRAME={test.get('bad_tlast_frame', -1)}"]
    for flag, name in (("use_sw", "USE_SW"), ("midframe", "MIDFRAME"),
                       ("check_rate", "CHECK_RATE")):
        if test.get(flag):
            plusargs.append(name)

    cmd = [tool("xsim"), "tb", "-sv_seed", str(seed), "-log", tdir + "/xsim.log"]
    for p in plusargs:
        cmd += ["-testplusarg", p]
    if waves:
        tcl = tdir + "/waves.tcl"
        with open(tcl, "w") as f:
            f.write("log_wave -recursive *\nrun all\nquit\n")
        cmd += ["-wdb", tdir + "/waves.wdb", "-tclbatch", tcl]
    else:
        cmd += ["-R"]
    run(cmd, snapshot, "xsim_" + test["name"] + ".log")

    log_path = os.path.join(tdir, "xsim.log")
    log = open(log_path, errors="replace").read() if os.path.exists(log_path) else ""

    if bmp_header is not None and os.path.exists(os.path.join(tdir, "out.raw")):
        out = open(os.path.join(tdir, "out.raw"), "rb").read()
        size = width * height
        for n in range(len(out) // size):
            golden.write_bmp(os.path.join(tdir, f"out_f{n}.bmp"), bmp_header,
                             width, height, out[n * size:(n + 1) * size])

    n_err = re.search(r"UVM_ERROR\s*:\s*(\d+)", log)
    n_fatal = re.search(r"UVM_FATAL\s*:\s*(\d+)", log)
    passed = ("TEST PASSED" in log and n_err and n_fatal
              and int(n_err.group(1)) == 0 and int(n_fatal.group(1)) == 0)
    if passed:
        return True, ""
    problems = [l.strip() for l in log.splitlines()
                if re.match(r"\s*(UVM_ERROR|UVM_FATAL|ERROR|Fatal)", l) and " : " not in l]
    return False, "\n".join(problems[:15]) or f"no UVM summary; see {log_path}"


def main():
    parser = argparse.ArgumentParser(description="ImageProcessTop UVM regression")
    parser.add_argument("tests", nargs="*", help="tests to run (default: all)")
    parser.add_argument("--list", action="store_true", help="list tests and exit")
    parser.add_argument("--seed", type=int, default=1,
                        help="seed for random images and simulator randomisation")
    parser.add_argument("--waves", action="store_true",
                        help="record all signals to build/sim/<test>/waves.wdb")
    args = parser.parse_args()

    if args.list:
        for t in TESTS:
            size = "x".join(map(str, t["size"])) if "size" in t else "directed"
            print(f"{t['name']:16} {size:12} {t['doc']}")
        return 0

    by_name = {t["name"]: t for t in TESTS}
    unknown = [n for n in args.tests if n not in by_name]
    if unknown:
        parser.error(f"unknown test(s): {', '.join(unknown)} (see --list)")
    selected = [by_name[n] for n in args.tests] if args.tests else TESTS

    golden.verify_normalisation()
    results = []
    for test in selected:
        start = time.time()
        print(f"{test['name']:16} ... ", end="", flush=True)
        ok, detail = run_test(test, args.seed, args.waves)
        print(f"{'PASS' if ok else 'FAIL'}  ({time.time() - start:.0f} s)")
        if not ok:
            print("    " + detail.replace("\n", "\n    "))
        results.append(ok)

    print(f"\n{sum(results)}/{len(results)} tests passed")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
