# zynq-image-processing

A pipelined 3×3 image convolution engine written in RTL Verilog and verified
with a UVM testbench. Designed for the Digilent Arty Z7-20 (Zynq-7000 SoC)
using Vivado for RTL synthesis and Vitis for firmware, though the RTL is
portable to any AXI4-Stream capable Xilinx device.

The project demonstrates two things in parallel: a hardware design that is
worth deploying (pipelined, parameterisable, AXI4-Stream compliant), and a
verification environment that reflects industry practice (UVM agent/driver/
monitor/scoreboard structure, rather than a simple self-checking testbench).

---

## Features

- **Configurable 3×3 kernel** — signed 8-bit coefficients support smoothing
  filters (box blur, Gaussian) and derivative filters (Sobel, Laplacian).
  Kernel coefficients are set in `conv.v`; no structural changes required.
- **Saturating output** — post-normalisation results are clamped to \[0, 255\]
  rather than wrapping, producing correct output for mixed-sign kernels.
- **AXI4-Stream I/O** — slave input and master output use standard
  `tvalid/tready/tdata` handshaking, making the core straightforward to
  integrate into a Zynq PS-PL pipeline via AXI DMA.
- **Circular line buffer architecture** — four line buffers operated as a
  ring avoid the need to copy or shift row data; only the read/write index
  advances between rows.
- **Fully parametric** — image width (`LINE_LEN`), number of line buffers
  (`NUM_LINES`), and kernel size (`NUM_TAPS`) are all module parameters.
- **UVM testbench** — stimulus, monitoring, and checking are structured into
  reusable UVM components (agent, driver, monitor, scoreboard) to reflect
  industry-standard verification methodology.

---

## Architecture

```
                    AXI4-Stream slave
                         │
                   ┌─────▼──────┐
                   │imageControl│  circular ring of 4 line buffers
                   │            │  streams 72-bit 3×3 pixel windows
                   └─────┬──────┘  once 3 full rows are buffered
                         │ 72-bit pixel window (9 × 8-bit pixels)
                   ┌─────▼──────┐
                   │    conv    │  signed 3×3 kernel multiply-accumulate
                   │            │  saturating normalisation, 2-cycle latency
                   └─────┬──────┘
                         │ 8-bit convolved pixel
                   ┌─────▼──────┐
                   │outputBuffer│  Xilinx AXI-stream FIFO IP
                   │  (FIFO)    │  back-pressure via axis_prog_full
                   └─────┬──────┘
                    AXI4-Stream master
```

### imageControl

Incoming pixels are written one byte per cycle into whichever line buffer
is currently active. Once 512 pixels have been written, the write index
advances to the next buffer in the ring (0→1→2→3→0→...). A depth counter
(`totalPixelCounter`) tracks buffered-but-unread pixels; once it reaches
1536 (three full rows), the read FSM activates.

During a read pass, three consecutive buffers are enabled simultaneously.
Each buffer outputs three adjacent pixels combinationally (24 bits), and
the three 24-bit outputs are concatenated into a 72-bit window word for
the convolver. After 512 columns the pass completes, `out_intr` pulses for
one cycle to signal the testbench to supply the next row, and the read
window slides forward by one buffer.

### conv

Each of the nine pixels in the 72-bit window is multiplied in parallel by
its signed kernel coefficient (stage 1, registered). The nine products are
summed combinationally, divided by `KERNEL_SUM`, and the result is
saturated to \[0, 255\] before being registered as output (stage 2). Total
pipeline latency is 2 clock cycles.

Pixels are unsigned 8-bit; coefficients are signed 8-bit. To avoid
misinterpreting pixel values ≥ 128 as negative, each pixel is
zero-extended to a signed 9-bit value before multiplying.

### outputBuffer

A Xilinx AXI4-Stream FIFO IP instance. `axis_prog_full` is fed back to
`s_axis_tready` on the input port to throttle the upstream source before
the FIFO fills.

---

## Repository structure

```
zynq-image-processing/
├── rtl/
│   ├── imageProcessTop.v   top-level AXI4-Stream wrapper
│   ├── imageControl.v      line buffer management and pixel window assembly
│   ├── conv.v              3×3 signed convolution kernel
│   └── lineBuffer.v        single-row pixel storage with 3-pixel read port
├── tb/
│   ├── tb_top.sv           UVM testbench top — clock, reset, DUT, config db
│   ├── tb_pkg.sv           package that includes all UVM component files
│   ├── pixel_stream_if.sv  SystemVerilog interface for DUT signal grouping
│   ├── pixel_test.sv       UVM test — creates env, starts sequence
│   ├── pixel_env.sv        UVM environment — instantiates agent and scoreboard
│   ├── pixel_agent.sv      UVM agent — owns driver, monitor, sequencer
│   ├── pixel_driver.sv     drives pixel transactions onto the DUT interface
│   ├── pixel_monitor.sv    observes DUT output, writes output BMP, feeds scoreboard
│   ├── pixel_scoreboard.sv checks pixel count and flags X/Z on output
│   ├── pixel_sequence.sv   reads input BMP, sends pixel transactions to driver
│   └── pixel_transaction.sv UVM sequence item — single 8-bit pixel
├── firmware/               Vitis firmware for PS-PL communication (Zynq)
├── scripts/                utility scripts (file copy, simulation setup)
└── README.md
```

---

## Simulation

The testbench reads a 512×512 greyscale BMP (`input.bmp`), streams all
pixels through the DUT, and writes the convolved result to `output.bmp`.
The UVM scoreboard verifies that exactly 262,144 pixels are received and
that no X or Z values appear on the output.

UVM was chosen over a basic self-checking testbench to build familiarity
with the component hierarchy and methodology used in industry verification
environments. For a design of this size it is admittedly heavier than
necessary, but the structure scales cleanly to more complex designs.

**Requirements:**
- Vivado 2020.1 or later (earlier versions may work)
- A 512×512 greyscale BMP named `input.bmp` in the simulation working directory

**Steps (Vivado GUI):**
1. Create a new project and add all files under `rtl/` and `tb/` as sources.
2. Set `tb_top.sv` as the top-level simulation source.
3. Copy `input.bmp` into the simulation working directory
   (`<project>.sim/sim_1/behav/xsim/`).
4. Run behavioural simulation. The scoreboard will report pass/fail in the
   Tcl console on completion.

---

## Changing the kernel

Open `rtl/conv.v` and edit the `initial` block and `KERNEL_SUM` parameter:

```verilog
// Sharpen kernel
initial begin
    KERNEL[0] = -8'sd1; KERNEL[1] = -8'sd1; KERNEL[2] = -8'sd1;
    KERNEL[3] = -8'sd1; KERNEL[4] =  8'sd9; KERNEL[5] = -8'sd1;
    KERNEL[6] = -8'sd1; KERNEL[7] = -8'sd1; KERNEL[8] = -8'sd1;
end
```
```verilog
parameter KERNEL_SUM = 1  // must equal the sum of all coefficients above
```

Kernels with a zero coefficient sum (Sobel, Laplacian) are not compatible
with the divide-normalisation step and require modification to the output
stage.

---

## Hardware target

| | |
|---|---|
| Board | Digilent Arty Z7-20 |
| SoC | Xilinx Zynq-7000 (XC7Z020) |
| RTL toolchain | Vivado |
| Firmware | Vitis |

The RTL is portable to other AXI4-Stream capable Xilinx devices. The
`outputBuffer` instance is a Xilinx FIFO IP and would need to be
regenerated or substituted when retargeting.

---

## Potential extensions

- **PS-PL integration** — connect the pipeline to the Zynq PS via AXI DMA
  for full end-to-end image processing from Linux userspace.
- **Variable image dimensions** — `LINE_LEN` and `NUM_ROWS` are already
  parameters; runtime-configurable dimensions would require AXI-Lite
  register control.
- **Derivative filter support** — extend the output stage with an absolute
  value option to support zero-sum kernels such as Sobel without modifying
  the normalisation path.
- **Colour image support** — replicate the pipeline three times (R, G, B)
  or add a channel-interleave stage upstream.
