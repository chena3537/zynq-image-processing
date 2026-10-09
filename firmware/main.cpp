// =============================================================================
// Image pipeline firmware (Arty Z7-20, bare metal)
//
// Two jobs, served in a loop over the USB-UART:
//  - Image requests: receive a greyscale frame, stream it through the
//    harness core with the AXI DMA (MM2S -> AxisFramer -> ImageProcessTop_0
//    -> AxisDeframer -> S2MM) and send the result back (scripts/hw_test.py).
//  - Video requests: report the HDMI path's status and optionally select the
//    kernel of the 720p video core ImageProcessTop_1 (scripts/video_ctl.py).
//    The video path runs without the firmware; at reset its kernel follows
//    the board switches.
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
//
// Video request:  "ZVID" | kernel u8   (0..4 select via CTRL, 0xFF = follow
//                                       the switches, 0xFE = status only,
//                                       0xFD = pulse hot-plug detect)
// Video response: "ZVST" | status u8 | locked u8 | frames u32 | core_status u32
//                 | core_ctrl u32
// locked: bit 0 HDMI input clock locked, bit 1 HDMI output locked. The video
// core's registers are only accessed while the input clock is locked (its
// clock comes from the HDMI input); otherwise frames, core_status and
// core_ctrl are 0, and a kernel change is refused with NO_VIDEO.
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
#ifdef XPAR_IMAGEPROCESSTOP_1_BASEADDR
#define VIDEO_BASEADDR   XPAR_IMAGEPROCESSTOP_1_BASEADDR
#else
#define VIDEO_BASEADDR   0x43C10000U
#endif
#ifdef XPAR_XGPIO_0_BASEADDR
#define GPIO_BASEADDR    XPAR_XGPIO_0_BASEADDR
#else
#define GPIO_BASEADDR    0x41200000U
#endif
#define GPIO_DATA        0x00         // channel 1 (inputs): lock status
#define GPIO2_DATA       0x08         // channel 2 (output): HDMI RX hot-plug detect
#define VIDEO_IN_LOCKED  0x1          // GPIO bit 0: dvi2rgb pixel clock locked
#define VIDEO_OUT_LOCKED 0x2          // GPIO bit 1: v_axi4s_vid_out locked

#define KERNEL_SWITCHES  0xFF         // video request: follow the board switches
#define KERNEL_KEEP      0xFE         // video request: status only
#define KERNEL_REPLUG    0xFD         // video request: pulse hot-plug detect
#define HPD_LOW_US       500000U      // long enough for sources to see a replug

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
    ST_NO_VIDEO    = 9,   // video core not clocked (no HDMI input)
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

enum Request { REQ_IMAGE, REQ_VIDEO };

// Block until a request magic ("ZIMG" or "ZVID") has been received.
static Request wait_for_request()
{
    u8 window[4] = {0, 0, 0, 0};
    for (;;) {
        while (!XUartPs_IsReceiveData(UART_BASEADDR))
            ;
        window[0] = window[1];
        window[1] = window[2];
        window[2] = window[3];
        window[3] = XUartPs_RecvByte(UART_BASEADDR);
        if (memcmp(window, "ZIMG", 4) == 0)
            return REQ_IMAGE;
        if (memcmp(window, "ZVID", 4) == 0)
            return REQ_VIDEO;
    }
}

// --- PL and DMA -----------------------------------------------------------------
// Pulse FCLK_RESET0_N: resets the DMA, interconnect and the whole image
// pipeline (core, framer, deframer) so a failed transfer cannot leave them
// out of step with the next frame. It also resets the video path, which
// briefly blanks the HDMI output; it is only used at start-up and after a
// DMA failure.
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
        Xil_Out32(GPIO_BASEADDR + GPIO2_DATA, 1);  // reset dropped hot-plug detect
    }
    send_response(status, width, height, elapsed_us, pixels);
}

// Hot-plug detect tells the HDMI source a display is attached; the source
// then reads the EDID (served by dvi2rgb). Raise it only once the PL is out
// of reset and the EDID emulation can answer, after holding it low long
// enough to count as an unplug, so the source re-reads the 720p EDID.
static void hdmi_hotplug()
{
    Xil_Out32(GPIO_BASEADDR + GPIO2_DATA, 0);
    usleep(HPD_LOW_US);
    Xil_Out32(GPIO_BASEADDR + GPIO2_DATA, 1);
}

static u32  video_read(u32 reg)         { return Xil_In32(VIDEO_BASEADDR + reg); }
static void video_write(u32 reg, u32 v) { Xil_Out32(VIDEO_BASEADDR + reg, v); }

static void handle_video_request()
{
    u8 kernel;
    if (!uart_get(&kernel))
        return;

    if (kernel == KERNEL_REPLUG) {
        hdmi_hotplug();
        kernel = KERNEL_KEEP;
    }

    u8  status = ST_OK;
    u32 locked = Xil_In32(GPIO_BASEADDR + GPIO_DATA) & (VIDEO_IN_LOCKED | VIDEO_OUT_LOCKED);
    u32 frames = 0, core_status = 0, core_ctrl = 0;

    // Without the HDMI input clock the video core is unclocked and an access
    // would stall the bus, so only touch it while the input is locked.
    if (locked & VIDEO_IN_LOCKED) {
        if (kernel == KERNEL_SWITCHES)
            video_write(CORE_CTRL, 0);
        else if (kernel < NUM_KERNELS)
            video_write(CORE_CTRL, (kernel << 4) | CTRL_KERNEL_REG);
        else if (kernel != KERNEL_KEEP)
            status = ST_BAD_KERNEL;
        frames      = video_read(CORE_FRAMES);
        core_status = video_read(CORE_STATUS);
        core_ctrl   = video_read(CORE_CTRL);
    } else if (kernel != KERNEL_KEEP) {
        status = ST_NO_VIDEO;
    }

    u8 rsp[18] = {'Z', 'V', 'S', 'T'};
    rsp[4] = status;
    rsp[5] = (u8)locked;
    put_u32(&rsp[6], frames);
    put_u32(&rsp[10], core_status);
    put_u32(&rsp[14], core_ctrl);
    uart_put_n(rsp, sizeof(rsp));
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

    hdmi_hotplug();                                // HDMI source reads our EDID

    while (XUartPs_IsReceiveData(UART_BASEADDR))   // drop anything stale
        (void)XUartPs_RecvByte(UART_BASEADDR);

    for (;;) {
        Request req = wait_for_request();
        (void)uart_take_errors();                  // count errors per request
        if (req == REQ_IMAGE)
            handle_request();
        else
            handle_video_request();
    }
}
