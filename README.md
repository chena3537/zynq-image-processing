# zynq-image-processing

A streaming 3×3 image convolution core written in Verilog, verified with a
UVM testbench against a Python reference model, and running on a Zynq-7000
(Digilent Arty Z7-20) in two ways:

- **Live HDMI video:** 1280×720 at 60 fps from the board's HDMI input,
  filtered in real time and sent to its HDMI output, with no frame buffer.
  The kernel is selected with the board switches or over the UART.
- **Still images through AXI DMA:** frames sent over the UART, processed, and
  checked bit-exactly against the reference model.

Vivado builds the hardware and Vitis builds the bare-metal firmware; both
projects are generated from this repo by scripts. The core uses AXI4-Stream
Video (`tuser` = start of frame, `tlast` = end of line) and processes one
pixel per clock.

---

## Features

- **Five kernels, selectable at run time** — sharpen, box blur, Gaussian blur,
  edge detect and identity (bypass), chosen by the `CTRL` register over
  AXI4-Lite or by board switches `sw[1:0]`. The selection is latched at the
  start of each frame, so every frame uses a single kernel.
- **Same-size output with border handling** — a W×H frame in gives a W×H frame
  out; edge pixels are replicated at the borders.
- **Correct rounding without dividers** — every kernel is built from three
  sums (centre, edge neighbours, corners). Blur normalisation uses a shift
  (÷16) and a reciprocal multiply (÷9), proven equal to exact
  round-half-up division for every reachable value.
- **Saturating output** — results are clamped to \[0, 255\].
- **Full AXI4-Stream flow control** — honours `tready` on both sides. A credit
  counter on the output FIFO means the pipeline never stalls and never
  overflows, and `s_axis_tready` depends only on registers.
- **One pixel per clock** — plus one idle input cycle per line and one idle
  line per frame, which fit inside video blanking.
- **Parameterised** — `WIDTH`, `HEIGHT`, `CHANNELS` (1 = 8-bit grey, 3 = RGB).
- **Frame-sync checking** — a misplaced `tlast` or a mid-frame `tuser` sets a
  sticky error bit; a new `tuser` always restarts cleanly.
- **UVM testbench** — agent, driver, monitor, back-pressure sink and
  scoreboard, checking every output pixel bit-exactly against the reference
  model, plus sideband, register, interrupt and throughput checks.

---

## Architecture

```
            AXI4-Stream Video in (tuser = SOF, tlast = EOL)
                         │
                   ┌─────▼──────┐  two block-RAM line buffers + 3×3 window
                   │ WindowGen  │  replicate-edge borders
                   │            │  frame sync, kernel latched per frame
                   └─────┬──────┘
                         │ 3×3 window + kernel code
                   ┌─────▼──────┐  centre / edge / corner sums
                   │    Conv    │  kernel select, rounding, clamp
                   │            │  4-stage pipeline
                   └─────┬──────┘
                         │ pixel
                   ┌─────▼──────┐  32-deep FIFO; credits gate new input
                   │ OutputFifo │  so the pipeline never stalls
                   └─────┬──────┘
                         │
            AXI4-Stream Video out

            ControlRegs: AXI4-Lite CTRL / STATUS / FRAMES / INFO
```

The block design instantiates the core twice.

**Live video** (`ImageProcessTop_1`: 1280×720, RGB), clocked by the pixel
clock recovered from the HDMI input:

```
HDMI IN ─ dvi2rgb ─ Video In to AXI4-Stream ─ ImageProcessTop_1 ─ AXI4-Stream to Video Out ─ rgb2dvi ─ HDMI OUT
                                                                          │
                                                                 Video Timing Controller (720p)
```

`dvi2rgb` and `rgb2dvi` come from Digilent's
[vivado-library](https://github.com/Digilent/vivado-library) (git submodule in
`ip/digilent`). The board presents a 720p EDID, and the firmware raises
hot-plug detect only once the EDID emulation is ready, so the source reads
it and sends 1280×720 at 60 Hz. LD0 shows the input clock locked and LD1 the
output locked. The video core's registers sit behind an AXI clock converter,
and the firmware only accesses them while the HDMI input clock is present.

**Still images** (`ImageProcessTop_0`: 512×512, grey), where `AxisFramer`
and `AxisDeframer` (`rtl/harness/`) adapt the AXI DMA's
one-transfer-per-frame streams to and from the video protocol:

```
DDR ─ AXI DMA MM2S ─ AxisFramer ─ ImageProcessTop_0 ─ AxisDeframer ─ AXI DMA S2MM ─ DDR
```

### Control registers (`s_axi_ctrl`: `0x43C00000` DMA core, `0x43C10000` video core)

| Offset | Name | Bits |
|---|---|---|
| `0x00` | CTRL | `[0]` kernel source (0 switches, 1 register), `[6:4]` kernel: 0 sharpen, 1 box, 2 Gaussian, 3 edge, 4 identity |
| `0x04` | STATUS | `[0]` sync error (sticky, write 1 to clear), `[1]` frame in progress |
| `0x08` | FRAMES | frames output since reset |
| `0x0C` | INFO | `[15:0]` width, `[31:16]` height |

---

## Repository Structure

```
zynq-image-processing/
├── rtl/          synthesisable Verilog (core); rtl/harness/ DMA adapters
├── tb/           UVM testbench, DMA harness test, sample image
├── bd/           block design as a Tcl script (write_bd_tcl)
├── constraints/  pin and timing constraints
├── ip/digilent/  Digilent vivado-library (git submodule: dvi2rgb, rgb2dvi)
├── firmware/     Vitis bare-metal application
├── scripts/      build, simulation, reference model and hardware test scripts
├── docs/         supplementary documentation
└── README.md
```

---

## Simulation

```bat
python scripts/sim/run_sim.py            :: full regression (~11 min)
python scripts/sim/run_sim.py --list     :: list tests
python scripts/sim/run_sim.py --waves small_stress
```

`run_sim.py` drives Vivado's simulator directly (no project needed). For each
test it generates stimulus and the expected output of every frame with
`scripts/golden_conv.py`, compiles the design once per frame size, runs the
UVM testbench and checks the report. Tests cover every kernel, back-to-back
frames, random input gaps and output back-pressure, mid-frame kernel changes
(applied from the next frame), switch control, frame-sync errors, a
non-power-of-two size, RGB, 512×512 images and 720p RGB at full rate. Results
are in `build/sim/<test>/`, including viewable `out_f<N>.bmp` images for the
512×512 tests.

*UVM was chosen over a basic self-checking testbench to build familiarity
with the component hierarchy and methodology used in industry verification
environments. For a design of this size it is admittedly heavier than
necessary, but the structure scales cleanly to more complex designs.

---

## Build and run on hardware

Requires Vivado and Vitis 2025.2 and Python 3 with `pyserial`. Clone with
`git clone --recursive`, or run `git submodule update --init` to fetch the
Digilent IP. From the repo root, with the board connected over USB:

```bat
vivado -mode batch -source scripts/vivado/create_project.tcl   :: project from repo sources
vivado -mode batch -source scripts/vivado/build.tcl            :: bitstream + XSA (fails if timing is not met)
vitis  -s scripts/vitis/build_app.py                           :: platform + firmware
xsdb   scripts/hw/program.tcl                                  :: program over JTAG and run
python scripts/hw_test.py                                      :: still images, checked against the model
```

### Live video

Connect an HDMI source (for example a laptop, mirrored or extended) to
**HDMI IN** and a monitor to **HDMI OUT**. After programming, the board
appears to the source as a 720p display, and the processed video appears on
the monitor. Switches SW1 SW0 select the kernel (00 sharpen, 01 box blur,
10 Gaussian, 11 edge detect). Over the UART:

```bat
python scripts/video_ctl.py status       :: lock state, frames processed, sync errors
python scripts/video_ctl.py fps          :: measure the output frame rate
python scripts/video_ctl.py kernel 4     :: select a kernel (4 = bypass)
python scripts/video_ctl.py kernel sw    :: back to the switches
python scripts/video_ctl.py replug       :: pulse hot-plug detect (source re-reads the EDID)
```

The core is built for 1280×720; other resolutions are rejected (the
`STATUS` sync-error bit is set and no frames are output). If the source picks
another mode, set that display to 1280×720 at 60 Hz.

The Vivado and Vitis projects are generated into `build/` (not tracked);
sources are referenced from the repo, so edits made in either IDE land in the
repo. `scripts/vivado/synth_core.tcl` checks the core's timing on its own.

`hw_test.py` sends `tb/input.bmp` (or `--input`) to the board, receives the
result and compares it bit-exactly with the reference model. Images must be
512×512 8-bit greyscale BMPs; `scripts/format_image.py` converts other images.

---

## Results

| | |
|---|---|
| Live HDMI video (Arty Z7-20) | 1280×720 at 60.0 fps in and out, all five kernels switched live without frame-sync errors |
| Still-image test (Arty Z7-20) | 50/50 frames bit-exact against the reference model (5 kernels × 10 frames, 512×512); bit-exact again with live video running |
| Processing time per 512×512 frame | 2.64 ms in the PL (263,169 cycles at 100 MHz: one pixel per clock plus the border slots) |
| System timing (100 MHz PS clock, 74.25 MHz pixel clock) | met, WNS +1.122 ns |
| Core alone, 150 MHz (out of context) | 720p RGB: WNS +0.458 ns (≈161 MHz); 512×512 grey: WNS +0.762 ns (≈169 MHz) |
| Core resources, 512×512 grey | 277 LUTs, 362 flip-flops, 1 block RAM, 1 DSP |
| Simulation | 11/11 tests pass, including 720p RGB at full rate (923,601 cycles per frame, within 720p60's 1,237,500) |

The still-image round trip is about 5.7 s per frame, almost all of it the
921600-baud UART transfer. That UART link occasionally loses bytes (in both
directions, depending on the host's USB setup); `hw_test.py` detects this
through CRCs and retries the frame, and pipeline results are unaffected.

---

## PS-PL System Integration

![PS-PL block design](docs/block_diagram.png)
*Vivado block design — the HDMI video path (dvi2rgb, video in, ImageProcessTop_1,
video out, rgb2dvi) and the still-image path (AXI DMA, AxisFramer,
ImageProcessTop_0, AxisDeframer); the PS controls both cores over AXI4-Lite.*

---

## Hardware Target

| | |
|---|---|
| Board | Digilent Arty Z7-20 |
| SoC | Xilinx Zynq-7000 (XC7Z020) |
| RTL toolchain | Vivado 2025.2 |
| Firmware | Vitis 2025.2 |
