#include <stdio.h>
#include <string.h>
#include "xaxidma.h"
#include "xparameters.h"
#include "xil_printf.h"
#include "xuartps.h"
#include "xil_cache.h"

#define DDR_BASE_ADDR   0x01000000
#define DDR_DST_ADDR    0x02000000
#define IMAGE_SIZE      (512*512)
#define UART_BAUD       115200
#define DMA_WAIT_TIMEOUT 100000000U

#if defined(XPAR_XAXIDMA_0_BASEADDR)
#define DMA_BASEADDR XPAR_XAXIDMA_0_BASEADDR
#elif defined(XPAR_AXIDMA_0_BASEADDR)
#define DMA_BASEADDR XPAR_AXIDMA_0_BASEADDR
#elif defined(XPAR_AXI_DMA_0_BASEADDR)
#define DMA_BASEADDR XPAR_AXI_DMA_0_BASEADDR
#else
#error "No AXI DMA BASEADDR macro found in xparameters.h"
#endif

// System-device-tree BSPs (Vitis 2023.2+, built with -DSDT) look drivers up
// by base address; older BSPs look them up by device ID.
#ifdef SDT
#define DMA_LOOKUP_KEY  DMA_BASEADDR
#define UART_LOOKUP_KEY XPAR_XUARTPS_0_BASEADDR
#else
#if defined(XPAR_XAXIDMA_0_DEVICE_ID)
#define DMA_LOOKUP_KEY XPAR_XAXIDMA_0_DEVICE_ID
#elif defined(XPAR_AXIDMA_0_DEVICE_ID)
#define DMA_LOOKUP_KEY XPAR_AXIDMA_0_DEVICE_ID
#else
#error "No AXI DMA DEVICE_ID macro found in xparameters.h"
#endif
#if defined(XPAR_XUARTPS_0_DEVICE_ID)
#define UART_LOOKUP_KEY XPAR_XUARTPS_0_DEVICE_ID
#else
#define UART_LOOKUP_KEY XPAR_PS7_UART_0_DEVICE_ID
#endif
#endif

XAxiDma  axidma;
XUartPs  uart;

int  init_dma();
int  init_uart();
void receive_image(u8* buffer, u32 size);
void send_image(u8* buffer, u32 size);
int  dma_loopback_test();
void print_dma_status(const char* tag);
int  wait_dma_done(int direction, u32 timeout, const char* channel_name);

int main()
{
    u8* input_buffer  = (u8*)DDR_BASE_ADDR;
    u8* output_buffer = (u8*)DDR_DST_ADDR;
    int status;

    xil_printf("Image Processing Pipeline Starting...\r\n");

    status = init_dma();
    if(status != XST_SUCCESS){
        xil_printf("DMA initialization failed\r\n");
        return XST_FAILURE;
    }
    xil_printf("DMA initialized\r\n");

    status = init_uart();
    if(status != XST_SUCCESS){
        xil_printf("UART initialization failed\r\n");
        return XST_FAILURE;
    }
    xil_printf("UART initialized\r\n");

    // Run DMA test before normal flow
    xil_printf("Running DMA test...\r\n");
    status = dma_loopback_test();
    if(status != XST_SUCCESS){
        xil_printf("DMA test failed, aborting image flow\r\n");
        return XST_FAILURE;
    }
    xil_printf("DMA test complete\r\n");

    // Handshake
    xil_printf("Waiting for start signal...\r\n");
    while(!XUartPs_IsReceiveData(uart.Config.BaseAddress));
    u8 start = XUartPs_RecvByte(uart.Config.BaseAddress);
    if(start != 0xFF){
        xil_printf("Bad start byte\r\n");
        return XST_FAILURE;
    }
    XUartPs_SendByte(uart.Config.BaseAddress, 0xFF);

    // Receive image
    receive_image(input_buffer, IMAGE_SIZE);

    // Ensure MM2S sees new input data; destination must be invalidated before and after S2MM.
    Xil_DCacheFlushRange((UINTPTR)input_buffer, IMAGE_SIZE);
    Xil_DCacheInvalidateRange((UINTPTR)output_buffer, IMAGE_SIZE);

    // Start S2MM first
    status = XAxiDma_SimpleTransfer(&axidma,
                (UINTPTR)output_buffer,
                IMAGE_SIZE,
                XAXIDMA_DEVICE_TO_DMA);
    if(status != XST_SUCCESS){
        xil_printf("S2MM failed\r\n");
        return XST_FAILURE;
    }

    // Start MM2S
    status = XAxiDma_SimpleTransfer(&axidma,
                (UINTPTR)input_buffer,
                IMAGE_SIZE,
                XAXIDMA_DMA_TO_DEVICE);
    if(status != XST_SUCCESS){
        xil_printf("MM2S failed\r\n");
        print_dma_status("MM2S start failure");
        return XST_FAILURE;
    }

    status = wait_dma_done(XAXIDMA_DEVICE_TO_DMA, DMA_WAIT_TIMEOUT, "S2MM");
    if(status != XST_SUCCESS)
        return XST_FAILURE;

    status = wait_dma_done(XAXIDMA_DMA_TO_DEVICE, DMA_WAIT_TIMEOUT, "MM2S");
    if(status != XST_SUCCESS)
        return XST_FAILURE;

    Xil_DCacheInvalidateRange((UINTPTR)output_buffer, IMAGE_SIZE);

    // Send output image
    send_image(output_buffer, IMAGE_SIZE);

    return XST_SUCCESS;
}

int init_dma()
{
    XAxiDma_Config *config;
    int status;

    config = XAxiDma_LookupConfig(DMA_LOOKUP_KEY);
    if(!config){
        xil_printf("DMA config lookup failed\r\n");
        return XST_FAILURE;
    }
    status = XAxiDma_CfgInitialize(&axidma, config);
    if(status != XST_SUCCESS){
        xil_printf("DMA config initialize failed\r\n");
        return XST_FAILURE;
    }

    // Verify simple mode
    if(XAxiDma_HasSg(&axidma)){
        xil_printf("DMA is in SG mode, expected simple mode\r\n");
        return XST_FAILURE;
    }
    xil_printf("DMA is in simple mode\r\n");

    XAxiDma_IntrDisable(&axidma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrDisable(&axidma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);
    return XST_SUCCESS;
}

int init_uart()
{
    XUartPs_Config *config;
    int status;

    config = XUartPs_LookupConfig(UART_LOOKUP_KEY);
    if(!config){
        xil_printf("UART config lookup failed\r\n");
        return XST_FAILURE;
    }
    status = XUartPs_CfgInitialize(&uart, config, config->BaseAddress);
    if(status != XST_SUCCESS){
        xil_printf("UART config initialize failed\r\n");
        return XST_FAILURE;
    }
    XUartPs_SetBaudRate(&uart, UART_BAUD);
    return XST_SUCCESS;
}

int dma_loopback_test()
{
    u32 i;
    u32 test_size = 256;
    int status;
    int mismatches;

    u8* input_buffer  = (u8*)DDR_BASE_ADDR;
    u8* output_buffer = (u8*)DDR_DST_ADDR;

    // Manual DMA reset
    xil_printf("Resetting DMA...\r\n");
    XAxiDma_Reset(&axidma);
    u32 reset_timeout = 10000;
    while(!XAxiDma_ResetIsDone(&axidma) && reset_timeout > 0)
        reset_timeout--;
    if(reset_timeout == 0){
        xil_printf("DMA reset timeout\r\n");
        return XST_FAILURE;
    }
    xil_printf("DMA reset done\r\n");

    // Re-disable interrupts after reset
    XAxiDma_IntrDisable(&axidma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrDisable(&axidma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);

    print_dma_status("After reset");

    for(i = 0; i < test_size; i++){
        input_buffer[i] = (u8)i;
    }
    memset(output_buffer, 0, test_size);

    Xil_DCacheFlushRange((UINTPTR)input_buffer, test_size);
    Xil_DCacheFlushRange((UINTPTR)output_buffer, test_size);
    Xil_DCacheInvalidateRange((UINTPTR)output_buffer, test_size);

    status = XAxiDma_SimpleTransfer(&axidma,
                (UINTPTR)output_buffer,
                test_size,
                XAXIDMA_DEVICE_TO_DMA);
    if(status != XST_SUCCESS){
        xil_printf("S2MM failed to start\r\n");
        print_dma_status("S2MM start failure");
        return XST_FAILURE;
    }
    xil_printf("S2MM started\r\n");

    print_dma_status("After S2MM start");

    status = XAxiDma_SimpleTransfer(&axidma,
                (UINTPTR)input_buffer,
                test_size,
                XAXIDMA_DMA_TO_DEVICE);
    if(status != XST_SUCCESS){
        xil_printf("MM2S failed to start\r\n");
        print_dma_status("MM2S start failure");
        return XST_FAILURE;
    }
    xil_printf("MM2S started\r\n");

    status = wait_dma_done(XAXIDMA_DEVICE_TO_DMA, DMA_WAIT_TIMEOUT, "S2MM");
    if(status != XST_SUCCESS)
        return XST_FAILURE;

    status = wait_dma_done(XAXIDMA_DMA_TO_DEVICE, DMA_WAIT_TIMEOUT, "MM2S");
    if(status != XST_SUCCESS)
        return XST_FAILURE;

    Xil_DCacheInvalidateRange((UINTPTR)output_buffer, test_size);

    mismatches = 0;
    for(i = 0; i < test_size; i++){
        if(output_buffer[i] != (u8)i){
            if(mismatches < 8){
                xil_printf("Mismatch[%lu]: got %u expected %u\r\n",
                    (unsigned long)i,
                    (unsigned int)output_buffer[i],
                    (unsigned int)((u8)i));
            }
            mismatches++;
        }
    }

    if(mismatches > 0){
        xil_printf("DMA loopback mismatch count: %d\r\n", mismatches);
        print_dma_status("Loopback mismatch");
        return XST_FAILURE;
    }

    xil_printf("DMA loopback PASS\r\n");

    for(i = 0; i < 10; i++){
        xil_printf("output[%d] = %d\r\n", i, output_buffer[i]);
    }

    return XST_SUCCESS;
}

void print_dma_status(const char* tag)
{
    u32 mm2s_sr = XAxiDma_ReadReg(DMA_BASEADDR, XAXIDMA_SR_OFFSET);
    u32 s2mm_sr = XAxiDma_ReadReg(DMA_BASEADDR, XAXIDMA_RX_OFFSET + XAXIDMA_SR_OFFSET);

    xil_printf("[%s] MM2S_SR=0x%08x S2MM_SR=0x%08x\r\n", tag, mm2s_sr, s2mm_sr);
}

int wait_dma_done(int direction, u32 timeout, const char* channel_name)
{
    while(XAxiDma_Busy(&axidma, direction) && timeout > 0)
        timeout--;

    if(timeout == 0){
        xil_printf("%s timeout\r\n", channel_name);
        print_dma_status(channel_name);
        return XST_FAILURE;
    }

    xil_printf("%s complete\r\n", channel_name);
    return XST_SUCCESS;
}

void receive_image(u8* buffer, u32 size)
{
    u32 i;
    for(i = 0; i < size; i++){
        while(!XUartPs_IsReceiveData(uart.Config.BaseAddress));
        buffer[i] = XUartPs_RecvByte(uart.Config.BaseAddress);
        if((i + 1) % 1024 == 0){
            XUartPs_SendByte(uart.Config.BaseAddress, 0xAA);
        }
    }
}

void send_image(u8* buffer, u32 size)
{
    u32 i;
    for(i = 0; i < size; i++){
        XUartPs_SendByte(uart.Config.BaseAddress, buffer[i]);
    }
}