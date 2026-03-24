from PIL import Image

img = Image.open("messi.jpg").convert('L').resize((512, 512))
img.save("C:/Users/alexa/Projects/ArtyZ7/ImageProcessing/ImageProcessing.sim/sim_1/behav/xsim/input.bmp")