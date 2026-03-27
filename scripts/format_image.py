"""
format_image.py
 
Converts an input image to a 512x512 greyscale BMP file compatible
with zynq-image-processing pipeline.
 
Usage:
    python format_image.py <input> <output>
 
Arguments:
    input   path to the source image (any format supported by PIL,
            e.g. .jpg, .png, .tiff)
    output  path for the output .bmp file
 
Requirements:
    Pillow  (pip install Pillow)
"""

import argparse
from PIL import Image

parser = argparse.ArgumentParser(description="Convert an image to a 512x512 greyscale BMP for the zynq-image-processing pipeline.")
parser.add_argument("input",  help="path to the source image (any format PIL supports)")
parser.add_argument("output", help="path for the output BMP file")
args = parser.parse_args()

img = Image.open(args.input).convert("L").resize((512, 512))
img.save(args.output)

print(f"Saved: {args.output}")