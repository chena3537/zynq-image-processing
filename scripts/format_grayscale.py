"""
format_grayscale.py

Converts an input image to a 512x512 8-bit grayscale BMP format 
compatible with zynq image processing pipeline

"""

from PIL import Image

input_file = "input.jpg"
output_file = "input.bmp"

# Read source image, convert to grayscale, and resize to the expected frame size.
img = Image.open("../images/input.jpg").convert("L").resize((512, 512))

# Write output BMP,file to be used as input to pipeline
img.save("../images/input.bmp")