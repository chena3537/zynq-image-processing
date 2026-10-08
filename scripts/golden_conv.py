"""
golden_conv.py

Reference model of the ImageProcessTop convolution, used to check the RTL in
simulation and on hardware. It is written from the kernel definitions, not
from the RTL's arithmetic shortcuts; verify_normalisation() proves those
shortcuts give the same results.

Definition of the output for every pixel (x, y) and channel:
  * 3x3 neighbourhood with replicate-edge borders (coordinates clamped to
    the image), kernel coefficients applied as a plain weighted sum r.
  * Box blur and Gaussian: r / divisor rounded to nearest, halves rounded
    up (r is never negative for these kernels).
  * Result clamped to [0, 255].

Usage:
    python scripts/golden_conv.py input.bmp output.bmp --kernel 2
    python scripts/golden_conv.py --self-test

Only 8-bit greyscale BMPs are supported (as produced by format_image.py).
Pixels are processed in file row order; all kernels and the border rule are
symmetric, so BMP's bottom-up row order does not change the result.
"""

import argparse
import struct
import sys

# code -> (name, 3x3 coefficients row-major, divisor)
KERNELS = {
    0: ("sharpen",  (0, -1, 0, -1, 5, -1, 0, -1, 0),     1),
    1: ("box",      (1, 1, 1, 1, 1, 1, 1, 1, 1),         9),
    2: ("gaussian", (1, 2, 1, 2, 4, 2, 1, 2, 1),         16),
    3: ("edge",     (-1, -1, -1, -1, 8, -1, -1, -1, -1), 1),
    4: ("identity", (0, 0, 0, 0, 1, 0, 0, 0, 0),         1),
}


def round_half_up_div(r, d):
    """r / d rounded to nearest, halves up, for r >= 0 and d > 0."""
    return (2 * r + d) // (2 * d)


def convolve(pixels, width, height, kernel, channels=1):
    """Return the convolved image as bytes (same layout as `pixels`)."""
    _, coeffs, divisor = KERNELS[kernel]
    taps = [(dy, dx, coeffs[(dy + 1) * 3 + (dx + 1)])
            for dy in (-1, 0, 1) for dx in (-1, 0, 1)
            if coeffs[(dy + 1) * 3 + (dx + 1)] != 0]
    out = bytearray(len(pixels))
    stride = width * channels
    for y in range(height):
        rows = {dy: min(max(y + dy, 0), height - 1) * stride for dy in (-1, 0, 1)}
        for x in range(width):
            cols = {dx: min(max(x + dx, 0), width - 1) * channels for dx in (-1, 0, 1)}
            for c in range(channels):
                r = 0
                for dy, dx, k in taps:
                    r += k * pixels[rows[dy] + cols[dx] + c]
                if divisor != 1:
                    r = round_half_up_div(r, divisor)
                out[y * stride + x * channels + c] = min(max(r, 0), 255)
    return bytes(out)


def verify_normalisation():
    """Check the RTL's divider-free normalisation against exact rounding
    for every value the blur kernels can produce."""
    for r in range(0, 9 * 255 + 1):                  # box blur sum
        if (r * 7282 + 32768) >> 16 != round_half_up_div(r, 9):
            raise AssertionError(f"box blur normalisation wrong for r={r}")
    for r in range(0, 16 * 255 + 1):                 # Gaussian sum
        if (r + 8) >> 4 != round_half_up_div(r, 16):
            raise AssertionError(f"Gaussian normalisation wrong for r={r}")


# -----------------------------------------------------------------------------
# BMP I/O (8-bit greyscale with palette)
# -----------------------------------------------------------------------------
def read_bmp(path):
    """Return (header_bytes, width, height, pixels) with pixels unpadded,
    in file row order."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:2] != b"BM":
        raise ValueError(f"{path}: not a BMP file")
    pixel_offset = struct.unpack_from("<I", data, 10)[0]
    width, height = struct.unpack_from("<ii", data, 18)
    bpp = struct.unpack_from("<H", data, 28)[0]
    compression = struct.unpack_from("<I", data, 30)[0]
    if bpp != 8 or compression != 0:
        raise ValueError(f"{path}: need an uncompressed 8-bit BMP (got {bpp}-bit, "
                         f"compression {compression}); convert with format_image.py")
    height = abs(height)
    row_bytes = (width + 3) & ~3
    pixels = bytearray()
    for row in range(height):
        start = pixel_offset + row * row_bytes
        pixels += data[start:start + width]
    if len(pixels) != width * height:
        raise ValueError(f"{path}: file is truncated")
    return data[:pixel_offset], width, height, bytes(pixels)


def write_bmp(path, header, width, height, pixels):
    """Write pixels using an existing 8-bit BMP header (from read_bmp)."""
    row_bytes = (width + 3) & ~3
    pad = bytes(row_bytes - width)
    with open(path, "wb") as f:
        f.write(header)
        for row in range(height):
            f.write(pixels[row * width:(row + 1) * width])
            f.write(pad)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("input", nargs="?", help="8-bit greyscale BMP")
    parser.add_argument("output", nargs="?", help="output BMP")
    parser.add_argument("--kernel", type=int, default=0, choices=sorted(KERNELS),
                        help="0 sharpen, 1 box, 2 gaussian, 3 edge, 4 identity")
    parser.add_argument("--self-test", action="store_true",
                        help="verify the RTL normalisation arithmetic and exit")
    args = parser.parse_args()

    verify_normalisation()
    if args.self_test:
        print("normalisation self-test passed")
        return
    if not args.input or not args.output:
        parser.error("input and output are required")

    header, width, height, pixels = read_bmp(args.input)
    out = convolve(pixels, width, height, args.kernel)
    write_bmp(args.output, header, width, height, out)
    print(f"{KERNELS[args.kernel][0]}: wrote {args.output} ({width}x{height})")


if __name__ == "__main__":
    sys.exit(main())
