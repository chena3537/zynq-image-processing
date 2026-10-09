"""
hw_test.py

Host side of the image pipeline hardware test. Sends a greyscale BMP to the
board over the USB-UART, receives the processed frame, and checks it
bit-exactly against the reference model (golden_conv.py).

The board must be running the firmware (scripts/hw/program.tcl). The
protocol is documented at the top of firmware/main.cpp.

Usage (from the repo root):
    python scripts/hw_test.py                         # every kernel, tb/input.bmp
    python scripts/hw_test.py --kernels 2 --frames 10
    python scripts/hw_test.py --input my.bmp --port COM7

Outputs build/hw/out_k<kernel>.bmp (the last frame for each kernel).
Exit code 1 if any frame fails.

UART transfer errors (a dropped or corrupted byte, reported by the board as
RX_TIMEOUT or BAD_CRC, or a corrupted response) are retried up to --retries
times and counted in the summary; occasional receive overruns have been
seen on the board's UART at 921600 baud. Pipeline errors (pixel mismatches,
DMA or frame-sync errors) are never retried.

Requirements: pyserial (pip install pyserial)
"""

import argparse
import os
import struct
import sys
import time
import zlib

import serial
import serial.tools.list_ports

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import golden_conv as golden  # noqa: E402

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

STATUS = {
    0: "OK",
    1: "BAD_SIZE (frame size differs from the core's)",
    2: "BAD_KERNEL",
    3: "BAD_CRC (request corrupted on the UART)",
    4: "DMA_ERROR",
    5: "DMA_TIMEOUT",
    6: "SYNC_ERROR (core saw a malformed frame)",
    7: "SHORT_FRAME (S2MM received the wrong byte count)",
    8: "RX_TIMEOUT (request stopped arriving)",
    9: "NO_VIDEO (no HDMI input clock)",
}


def describe(status, value):
    """Status text, with the receive details the board reports for RX_TIMEOUT."""
    text = STATUS.get(status, f"unknown status {status}")
    if status == 8:
        flags = [name for bit, name in ((1, "overrun"), (2, "framing"), (4, "parity"))
                 if (value >> 24) & bit]
        text += f": {value & 0xFFFFFF} bytes received, UART errors: {', '.join(flags) or 'none'}"
    return text


def find_port():
    """The Arty Z7's FT2232 exposes its UART as the only FTDI COM port."""
    ports = [p for p in serial.tools.list_ports.comports() if p.vid == 0x0403]
    if len(ports) != 1:
        found = ", ".join(f"{p.device} ({p.description})" for p in
                          serial.tools.list_ports.comports()) or "none"
        sys.exit(f"Cannot pick the board's serial port automatically (found: {found}); "
                 f"use --port")
    return ports[0].device


def read_exact(ser, n, what):
    data = bytearray()
    while len(data) < n:
        chunk = ser.read(n - len(data))
        if not chunk:
            raise TimeoutError(f"timed out reading {what} ({len(data)}/{n} bytes)")
        data += chunk
    return bytes(data)


def wait_for_magic(ser, magic, timeout):
    """Skip anything before the response magic (e.g. the boot banner)."""
    deadline = time.time() + timeout
    window = b""
    while time.time() < deadline:
        b = ser.read(1)
        if b:
            window = (window + b)[-len(magic):]
            if window == magic:
                return
    raise TimeoutError("no response from the board (is the firmware running?)")


def process(ser, pixels, width, height, kernel):
    """Send one frame; return (status, value, output bytes or None). value is the
    PL processing time in microseconds for OK, or error detail."""
    ser.reset_input_buffer()
    ser.write(b"ZIMG" + struct.pack("<BHH", kernel, width, height) + pixels +
              struct.pack("<I", zlib.crc32(pixels)))
    ser.flush()

    # Board receives, processes (milliseconds), then replies
    wait_for_magic(ser, b"ZRES", timeout=len(pixels) * 10 / ser.baudrate + 10)
    status, w, h, value = struct.unpack("<BHHI", read_exact(ser, 9, "header"))
    if status != 0:
        return status, value, None
    if (w, h) != (width, height):
        raise ValueError(f"response is {w}x{h}, sent {width}x{height}")
    out = read_exact(ser, width * height, "pixels")
    crc = struct.unpack("<I", read_exact(ser, 4, "CRC"))[0]
    if crc != zlib.crc32(out):
        raise ValueError("response CRC mismatch (corrupted on the UART)")
    return status, value, out


# Board statuses caused by the UART link rather than the image pipeline
TRANSPORT_STATUSES = (3, 8)     # BAD_CRC, RX_TIMEOUT


def transfer(ser, pixels, width, height, kernel, max_retries, label):
    """process() with retries for UART transfer errors only.
    Returns (status, value, out, host_error, retries_used)."""
    for attempt in range(max_retries + 1):
        try:
            status, value, out = process(ser, pixels, width, height, kernel)
            if status not in TRANSPORT_STATUSES:
                return status, value, out, None, attempt
            problem = f"board status {describe(status, value)}"
        except (TimeoutError, ValueError) as e:
            problem = str(e)
            time.sleep(1.5)        # let the board abandon a partial request
        if attempt < max_retries:
            print(f"{label}  retry {attempt + 1}/{max_retries}: {problem}")
    return None, 0, None, f"{problem} (after {max_retries} retries)", max_retries


def main():
    parser = argparse.ArgumentParser(description="Image pipeline hardware test")
    parser.add_argument("--port", help="serial port (default: auto-detect the Arty Z7)")
    parser.add_argument("--baud", type=int, default=921600)
    parser.add_argument("--input", default=os.path.join(REPO_ROOT, "tb", "input.bmp"),
                        help="8-bit greyscale BMP matching the core size (default tb/input.bmp)")
    parser.add_argument("--kernels", default="0,1,2,3,4",
                        help="comma-separated kernel codes: 0 sharpen, 1 box, 2 gaussian, "
                             "3 edge, 4 identity")
    parser.add_argument("--frames", type=int, default=1, help="frames per kernel")
    parser.add_argument("--retries", type=int, default=2,
                        help="resend a frame up to this many times after a UART transfer "
                             "error (pipeline errors are never retried)")
    parser.add_argument("--out", default=os.path.join(REPO_ROOT, "build", "hw"),
                        help="directory for output BMPs")
    args = parser.parse_args()

    kernels = [int(k) for k in args.kernels.split(",")]
    header, width, height, pixels = golden.read_bmp(args.input)
    os.makedirs(args.out, exist_ok=True)
    port = args.port or find_port()

    print(f"{port} @ {args.baud} baud, {os.path.basename(args.input)} {width}x{height}")
    failures = 0
    retries = 0
    with serial.Serial(port, args.baud, timeout=5) as ser:
        for kernel in kernels:
            name = golden.KERNELS[kernel][0]
            expected = golden.convolve(pixels, width, height, kernel)
            for frame in range(args.frames):
                start = time.time()
                label = f"kernel {kernel} {name:9} frame {frame + 1}/{args.frames}"
                status, value, out, error, used = transfer(ser, pixels, width, height,
                                                           kernel, args.retries, label)
                retries += used
                if error:
                    print(f"{label}  FAIL  {error}")
                    failures += 1
                    continue
                if status != 0:
                    print(f"{label}  FAIL  board status {describe(status, value)}")
                    failures += 1
                    continue
                mismatches = sum(a != b for a, b in zip(out, expected))
                golden.write_bmp(os.path.join(args.out, f"out_k{kernel}.bmp"),
                                 header, width, height, out)
                verdict = "PASS" if mismatches == 0 else f"FAIL  {mismatches} pixels differ"
                print(f"{label}  {verdict}  (PL {value / 1000:.2f} ms, "
                      f"round trip {time.time() - start:.1f} s)")
                failures += mismatches != 0

    total = len(kernels) * args.frames
    print(f"\n{total - failures}/{total} frames passed, {retries} UART retries; "
          f"outputs in {args.out}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
