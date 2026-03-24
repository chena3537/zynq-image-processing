import serial
import time

PORT        = 'COM4'
BAUD_RATE   = 115200
IMAGE_IN    = "../images/input.bmp"
IMAGE_OUT   = "../images/output.bmp"
HEADER_SIZE = 1078
IMAGE_SIZE  = 512 * 512
CHUNK_SIZE  = 1024

def main():
    ser = serial.Serial(PORT, BAUD_RATE, timeout=30)
    print(f"Connected to {PORT}")

    with open(IMAGE_IN, 'rb') as f:
        header = f.read(HEADER_SIZE)
        pixel_data = f.read(IMAGE_SIZE)

    # Handshake
    print("Performing handshake...")
    time.sleep(1)
    ser.write(b'\xff')
    ser.flush()
    ack = ser.read(1)
    if ack != b'\xff':
        print(f"Handshake failed: {ack}")
        ser.close()
        return
    print("Handshake successful!")

    # Send image in chunks waiting for ACK each time
    print(f"Sending {IMAGE_SIZE} bytes in {IMAGE_SIZE//CHUNK_SIZE} chunks...")
    for i in range(0, IMAGE_SIZE, CHUNK_SIZE):
        chunk = pixel_data[i:i+CHUNK_SIZE]
        ser.write(chunk)
        ser.flush()
        ack = ser.read(1)
        if ack != b'\xaa':
            print(f"Bad ACK at chunk {i//CHUNK_SIZE}: {ack}")
            ser.close()
            return
        if (i // CHUNK_SIZE) % 64 == 0:
            print(f"Sent {i+CHUNK_SIZE}/{IMAGE_SIZE} bytes")

    print("Image sent, waiting for processed image...")

    # Receive processed pixels
    output_pixels = bytearray()
    while len(output_pixels) < IMAGE_SIZE:
        chunk = ser.read(IMAGE_SIZE - len(output_pixels))
        if chunk:
            output_pixels.extend(chunk)
            print(f"Received {len(output_pixels)}/{IMAGE_SIZE} bytes")

    with open(IMAGE_OUT, 'wb') as f:
        f.write(header)
        f.write(output_pixels)

    print(f"Output saved to {IMAGE_OUT}")
    ser.close()

if __name__ == '__main__':
    main()