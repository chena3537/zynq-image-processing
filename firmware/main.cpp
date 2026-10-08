// =============================================================================
// Image pipeline firmware (Arty Z7-20, bare metal)
//
// Receives a greyscale frame over the USB-UART, streams it through the PL
// convolution core with the AXI DMA (MM2S -> AxisFramer -> ImageProcessTop
// -> AxisDeframer -> S2MM), and sends the result back. Requests are served
// in a loop; scripts/hw_test.py is the host side.
//
// UART: 921600 baud, 8N1. Nothing else is printed once requests start, so
// the byte stream carries only protocol data.
//
// Request (host -> board), little endian:
//   "ZIMG" | kernel u8 | width u16 | height u16 | pixels[width*height] | crc32 u32
// Response (board -> host):
//   "ZRES" | status u8 | width u16 | height u16 | value u32
//   then, only if status == OK: pixels[width*height] | crc32 u32
//
// crc32 is the IEEE CRC-32 of the pixel bytes (same as Python zlib.crc32).
// value: for OK, the DMA time in microseconds from the first transfer start
// to completion. For RX_TIMEOUT, bits [23:0] = request bytes received after
// the magic, bits [31:24] = UART receive errors (bit 0 overrun, bit 1
// framing, bit 2 parity). Otherwise 0.
// =============================================================================

#include <string.h>
#include "xaxidma.h"
#include "xparameters.h"
#include "xuartps.h"
#include "xil_cache.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "xiltimer.h"     // XTime_GetTime, COUNTS_PER_SECOND (xiltimer library)
#include "sleep.h"

// -----------------------------------------------------------------------------
// Configuration
// -----------------------------------------------------------------------------
#define UART_BAUD        921600
#define MAX_PIXELS       (512 * 512)
#define BYTE_TIMEOUT_US  1000000U     // abandon a request after 1 s of silence
#define DMA_TIMEOUT_US   1000000U

// Peripherals (system-device-tree BSPs look drivers up by base address)
#define DMA_BASEADDR     XPAR_XAXIDMA_0_BASEADDR
#define UART_BASEADDR    XPAR_XUARTPS_0_BASEADDR
#ifdef XPAR_IMAGEPROCESSTOP_0_BASEADDR
#define CORE_BASEADDR    XPAR_IMAGEPROCESSTOP_0_BASEADDR
#else
#define CORE_BASEADDR    0x43C00000U  // bd/image_pipeline.tcl address map
#endif

// ImageProcessTop registers (rtl/ControlRegs.v)
#define CORE_CTRL        0x00
#define CORE_STATUS      0x04
#define CORE_FRAMES      0x08
#define CORE_INFO        0x0C
#define CTRL_KERNEL_REG  0x1          // kernel from CTRL[6:4], not the switches
#define STATUS_SYNC_ERR  0x1

// PS system-level control registers, used to reset the PL
#define SLCR_LOCK        0xF8000004U
#define SLCR_UNLOCK      0xF8000008U
#define SLCR_FPGA_RST    0xF8000240U
#define SLCR_LOCK_KEY    0x767BU
#define SLCR_UNLOCK_KEY  0xDF0DU

#define NUM_KERNELS      5

enum Status : u8 {
    ST_OK          = 0,
    ST_BAD_SIZE    = 1,   // width/height differ from the core's
    ST_BAD_KERNEL  = 2,
    ST_BAD_CRC     = 3,   // request payload corrupted
    ST_DMA_ERROR   = 4,   // DMA refused a transfer or reported an error
    ST_DMA_TIMEOUT = 5,
    ST_SYNC_ERROR  = 6,   // core saw a malformed frame
    ST_SHORT_FRAME = 7,   // S2MM received the wrong number of bytes
    ST_RX_TIMEOUT  = 8,   // request stopped arriving before it was complete
};

static XAxiDma axidma;
static XUartPs uart;
static u32     core_width;
static u32     core_height;
static u32     crc_table[256];

static u8 in_buf[MAX_PIXELS]  __attribute__((aligned(64)));
static u8 out_buf[MAX_PIXELS] __attribute__((aligned(64)));

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------
static u32 now_us()
{
    XTime t;
    XTime_GetTime(&t);
    return (u32)(t / (COUNTS_PER_SECOND / 1000000U));
}

static void crc_init()
{
    for (u32 i = 0; i < 256; i++) {
        u32 c = i;
        for (int k = 0; k < 8; k++)
            c = (c & 1) ? (0xEDB88320U ^ (c >> 1)) : (c >> 1);
        crc_table[i] = c;
    }
}

static u32 crc32(const u8* data, u32 len)
{
    u32 c = 0xFFFFFFFFU;
    for (u32 i = 0; i < len; i++)
        c = crc_table[(c ^ data[i]) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFFU;
}

static u32 core_read(u32 reg)          { return Xil_In32(CORE_BASEADDR + reg); }
static void core_write(u32 reg, u32 v) { Xil_Out32(CORE_BASEADDR + reg, v); }

// --- UART ---------------------------------------------------------------------
// Returns false if no byte arrives within BYTE_TIMEOUT_US.
static bool uart_get(u8* b)
{
    u32 start = now_us();
    while (!XUartPs_IsReceiveData(UART_BASEADDR)) {
        if (now_us() - start > BYTE_TIMEOUT_US)
            return false;
    }
    *b = XUartPs_RecvByte(UART_BASEADDR);
    return true;
}

// Returns the number of bytes received (n unless a byte timed out).
static u32 uart_get_n(u8* buf, u32 n)
{
    for (u32 i = 0; i < n; i++)
        if (!uart_get(&buf[i]))
            return i;
    return n;
}

// Receive errors latched in the UART status since the last call:
// bit 0 overrun, bit 1 framing, bit 2 parity.
static u32 uart_take_errors()
{
    u32 isr = XUartPs_ReadReg(UART_BASEADDR, XUARTPS_ISR_OFFSET);
    XUartPs_WriteReg(UART_BASEADDR, XUARTPS_ISR_OFFSET,
                     XUARTPS_IXR_OVER | XUARTPS_IXR_FRAMING | XUARTPS_IXR_PARITY);
    return ((isr & XUARTPS_IXR_OVER)    ? 1 : 0) |
           ((isr & XUARTPS_IXR_FRAMING) ? 2 : 0) |
           ((isr & XUARTPS_IXR_PARITY)  ? 4 : 0);
}

static void uart_put_n(const u8* buf, u32 n)
{
    for (u32 i = 0; i < n; i++)
        XUartPs_SendByte(UART_BASEADDR, buf[i]);
}

static void put_u16(u8* p, u16 v) { p[0] = v & 0xFF; p[1] = v >> 8; }
static void put_u32(u8* p, u32 v) { for (int i = 0; i < 4; i++) p[i] = (v >> (8 * i)) & 0xFF; }
static u16  get_u16(const u8* p)  { return p[0] | (p[1] << 8); }
static u32  get_u32(const u8* p)  { return p[0] | (p[1] << 8) | (p[2] << 16) | ((u32)p[3] << 24); }

// Block until the 4-byte request magic has been received.
static void wait_for_magic()
{
    static const u8 magic[4] = {'Z', 'I', 'M', 'G'};
    u32 matched = 0;
    while (matched < 4) {
        while (!XUartPs_IsReceiveData(UART_BASEADDR))
            ;
        u8 b = XUartPs_RecvByte(UART_BASEADDR);
        if (b == magic[matched])
            matched++;
        else
            matched = (b == magic[0]) ? 1 : 0;
    }
}

// --- PL and DMA -----------------------------------------------------------------
// Pulse FCLK_RESET0_N: resets the DMA, interconnect and the whole image
// pipeline (core, framer, deframer) so a failed transfer cannot leave them
// out of step with the next frame.
static void pl_reset()
{
    Xil_Out32(SLCR_UNLOCK, SLCR_UNLOCK_KEY);
    Xil_Out32(SLCR_FPGA_RST, 0x1);
    for (volatile int i = 0; i < 1000; i++)
        ;
    Xil_Out32(SLCR_FPGA_RST, 0x0);
    Xil_Out32(SLCR_LOCK, SLCR_LOCK_KEY);
    for (volatile int i = 0; i < 1000; i++)   // proc_sys_reset hold time
        ;
}

static int dma_init()
{
    XAxiDma_Config* cfg = XAxiDma_LookupConfig(DMA_BASEADDR);
    if (!cfg || XAxiDma_CfgInitialize(&axidma, cfg) != XST_SUCCESS)
        return XST_FAILURE;
    if (XAxiDma_HasSg(&axidma))
        return XST_FAILURE;

    XAxiDma_Reset(&axidma);
    u32 start = now_us();
    while (!XAxiDma_ResetIsDone(&axidma)) {
        if (now_us() - start > DMA_TIMEOUT_US)
            return XST_FAILURE;
    }
    XAxiDma_IntrDisable(&axidma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrDisable(&axidma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);
    return XST_SUCCESS;
}

static u32 dma_errors()
{
    u32 mm2s = XAxiDma_ReadReg(DMA_BASEADDR, XAXIDMA_TX_OFFSET + XAXIDMA_SR_OFFSET);
    u32 s2mm = XAxiDma_ReadReg(DMA_BASEADDR, XAXIDMA_RX_OFFSET + XAXIDMA_SR_OFFSET);
    return (mm2s | s2mm) & XAXIDMA_ERR_ALL_MASK;
}

// Run one frame through the pipeline. Returns a Status.
static u8 process_frame(u32 pixels, u8 kernel, u32* elapsed_us)
{
    core_write(CORE_CTRL, (kernel << 4) | CTRL_KERNEL_REG);
    core_write(CORE_STATUS, STATUS_SYNC_ERR);           // clear sticky error

    Xil_DCacheFlushRange((UINTPTR)in_buf, pixels);
    Xil_DCacheInvalidateRange((UINTPTR)out_buf, pixels);

    u32 start = now_us();
    if (XAxiDma_SimpleTransfer(&axidma, (UINTPTR)out_buf, pixels,
                               XAXIDMA_DEVICE_TO_DMA) != XST_SUCCESS)
        return ST_DMA_ERROR;
    if (XAxiDma_SimpleTransfer(&axidma, (UINTPTR)in_buf, pixels,
                               XAXIDMA_DMA_TO_DEVICE) != XST_SUCCESS)
        return ST_DMA_ERROR;

    while (XAxiDma_Busy(&axidma, XAXIDMA_DEVICE_TO_DMA) ||
           XAxiDma_Busy(&axidma, XAXIDMA_DMA_TO_DEVICE)) {
        if (dma_errors())
            return ST_DMA_ERROR;
        if (now_us() - start > DMA_TIMEOUT_US)
            return ST_DMA_TIMEOUT;
    }
    *elapsed_us = now_us() - start;

    if (dma_errors())
        return ST_DMA_ERROR;
    u32 received = XAxiDma_ReadReg(DMA_BASEADDR, XAXIDMA_RX_OFFSET + XAXIDMA_BUFFLEN_OFFSET);
    if (received != pixels)
        return ST_SHORT_FRAME;
    if (core_read(CORE_STATUS) & STATUS_SYNC_ERR)
        return ST_SYNC_ERROR;

    Xil_DCacheInvalidateRange((UINTPTR)out_buf, pixels);
    return ST_OK;
}

// -----------------------------------------------------------------------------
// Request handling
// -----------------------------------------------------------------------------
static void send_response(u8 status, u16 width, u16 height, u32 value, u32 pixels)
{
    u8 hdr[13] = {'Z', 'R', 'E', 'S'};
    hdr[4] = status;
    put_u16(&hdr[5], width);
    put_u16(&hdr[7], height);
    put_u32(&hdr[9], value);
    uart_put_n(hdr, sizeof(hdr));
    if (status == ST_OK) {
        u8 crc[4];
        put_u32(crc, crc32(out_buf, pixels));
        uart_put_n(out_buf, pixels);
        uart_put_n(crc, sizeof(crc));
    }
}

// The request stopped arriving: report how far it got and why, if known.
static void send_rx_timeout(u16 width, u16 height, u32 received)
{
    u32 detail = (uart_take_errors() << 24) | (received & 0xFFFFFF);
    send_response(ST_RX_TIMEOUT, width, height, detail, 0);
}

static void handle_request()
{
    u8 hdr[5];
    u32 got = uart_get_n(hdr, sizeof(hdr));
    if (got != sizeof(hdr)) {
        send_rx_timeout(0, 0, got);
        return;
    }
    u8  kernel = hdr[0];
    u16 width  = get_u16(&hdr[1]);
    u16 height = get_u16(&hdr[3]);
    u32 pixels = (u32)width * height;

    if (width != core_width || height != core_height || pixels > MAX_PIXELS) {
        send_response(ST_BAD_SIZE, width, height, 0, 0);
        return;                                  // payload is left to resync
    }

    u8 crc_bytes[4];
    got = uart_get_n(in_buf, pixels);
    if (got == pixels)
        got += uart_get_n(crc_bytes, sizeof(crc_bytes));
    if (got != pixels + sizeof(crc_bytes)) {
        send_rx_timeout(width, height, sizeof(hdr) + got);
        return;
    }
    if (crc32(in_buf, pixels) != get_u32(crc_bytes)) {
        send_response(ST_BAD_CRC, width, height, 0, 0);
        return;
    }
    if (kernel >= NUM_KERNELS) {
        send_response(ST_BAD_KERNEL, width, height, 0, 0);
        return;
    }

    u32 elapsed_us = 0;
    u8 status = process_frame(pixels, kernel, &elapsed_us);
    if (status == ST_DMA_ERROR || status == ST_DMA_TIMEOUT || status == ST_SHORT_FRAME) {
        pl_reset();                              // start the next frame clean
        dma_init();
    }
    send_response(status, width, height, elapsed_us, pixels);
}

int main()
{
    // xiltimer starts the global timer lazily on the first sleep call;
    // XTime_GetTime only reads it. Start it before any timeout is used.
    usleep(1);
    crc_init();

    XUartPs_Config* ucfg = XUartPs_LookupConfig(UART_BASEADDR);
    if (!ucfg || XUartPs_CfgInitialize(&uart, ucfg, ucfg->BaseAddress) != XST_SUCCESS)
        return XST_FAILURE;
    if (XUartPs_SetBaudRate(&uart, UART_BAUD) != XST_SUCCESS)
        return XST_FAILURE;

    pl_reset();
    if (dma_init() != XST_SUCCESS) {
        xil_printf("\r\nDMA initialisation failed\r\n");
        return XST_FAILURE;
    }

    u32 info = core_read(CORE_INFO);
    core_width  = info & 0xFFFF;
    core_height = info >> 16;
    xil_printf("\r\nimage pipeline ready: %dx%d, %d baud\r\n",
               (int)core_width, (int)core_height, UART_BAUD);
    if (core_width * core_height > MAX_PIXELS) {
        xil_printf("core frame larger than MAX_PIXELS\r\n");
        return XST_FAILURE;
    }

    while (XUartPs_IsReceiveData(UART_BASEADDR))   // drop anything stale
        (void)XUartPs_RecvByte(UART_BASEADDR);

    for (;;) {
        wait_for_magic();
        (void)uart_take_errors();                  // count errors per request
        handle_request();
    }
}
