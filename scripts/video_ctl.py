"""
video_ctl.py

Status and control of the HDMI 720p video path over the board's USB-UART
(the firmware must be running; see firmware/main.cpp for the protocol).

Usage (from the repo root):
    python scripts/video_ctl.py status            # lock state, frame count, errors
    python scripts/video_ctl.py fps               # measure the output frame rate
    python scripts/video_ctl.py kernel 4          # select a kernel (4 = identity / bypass)
    python scripts/video_ctl.py kernel sw         # return kernel control to the switches
    python scripts/video_ctl.py replug            # pulse hot-plug detect (source re-reads EDID)

Kernels: 0 sharpen, 1 box blur, 2 Gaussian, 3 edge detect, 4 identity.
The switches select kernels 0-3 whenever the kernel source is "switches"
(the state after reset). Exit code 1 if the video path is not running.

Requirements: pyserial (pip install pyserial)
"""

import argparse
import os
import struct
import sys
import time

import serial

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from golden_conv import KERNELS                              # noqa: E402
from hw_test import STATUS, find_port, read_exact, wait_for_magic  # noqa: E402

KERNEL_SWITCHES = 0xFF
KERNEL_KEEP     = 0xFE
KERNEL_REPLUG   = 0xFD


def video_request(ser, kernel):
    """Send a video request; return a dict with the board's answer."""
    ser.reset_input_buffer()
    ser.write(b"ZVID" + bytes([kernel]))
    ser.flush()
    wait_for_magic(ser, b"ZVST", timeout=3)
    status, locked, frames, core_status, core_ctrl = struct.unpack(
        "<BBIII", read_exact(ser, 14, "video status"))
    return dict(status=status, in_locked=bool(locked & 1), out_locked=bool(locked & 2),
                frames=frames, sync_error=bool(core_status & 1),
                from_register=bool(core_ctrl & 1), kernel=(core_ctrl >> 4) & 7,
                time=time.time())


def describe(s):
    lines = [f"HDMI input clock locked:  {'yes' if s['in_locked'] else 'no'}",
             f"HDMI output locked:       {'yes' if s['out_locked'] else 'no'}"]
    if s["in_locked"]:
        source = (f"register, {s['kernel']} ({KERNELS.get(s['kernel'], ('?',))[0]})"
                  if s["from_register"] else "switches")
        lines += [f"frames processed:         {s['frames']}",
                  f"frame sync error seen:    {'yes' if s['sync_error'] else 'no'}",
                  f"kernel source:            {source}"]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="HDMI video path status and control")
    parser.add_argument("command", choices=["status", "fps", "kernel", "replug"])
    parser.add_argument("value", nargs="?", help="kernel: 0-4 or 'sw'")
    parser.add_argument("--port", help="serial port (default: auto-detect the Arty Z7)")
    parser.add_argument("--baud", type=int, default=921600)
    parser.add_argument("--seconds", type=float, default=5.0, help="fps measurement time")
    args = parser.parse_args()

    if args.command == "kernel":
        if args.value == "sw":
            code = KERNEL_SWITCHES
        elif args.value is not None and args.value.isdigit() and int(args.value) in KERNELS:
            code = int(args.value)
        else:
            parser.error("kernel needs 0-4 or 'sw'")
    elif args.command == "replug":
        code = KERNEL_REPLUG
    else:
        code = KERNEL_KEEP

    with serial.Serial(args.port or find_port(), args.baud, timeout=2) as ser:
        first = video_request(ser, code)
        if first["status"] != 0:
            print(f"board status: {STATUS.get(first['status'], first['status'])}")
        if args.command == "fps" and first["in_locked"]:
            time.sleep(args.seconds)
            last = video_request(ser, KERNEL_KEEP)
            rate = (last["frames"] - first["frames"]) / (last["time"] - first["time"])
            print(describe(last))
            print(f"output frame rate:        {rate:.2f} fps")
        else:
            print(describe(first))

    return 0 if first["status"] == 0 and first["in_locked"] and first["out_locked"] else 1


if __name__ == "__main__":
    sys.exit(main())
