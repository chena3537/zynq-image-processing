#include <stdio.h>
#include "xaxidma.h"
#include "xparameters.h"
#include "xil_printf.h"
#include "xuartps.h"
#include "xil_cache.h"

#define DDR_BASE_ADDR   0x01000000
#define DDR_DST_ADDR    0x02000000
#define IMAGE_SIZE      (512*512)
#define UART_BAUD       115200

XAxiDma  axidma;
XUartPs  uart;

int  init_dma();
int  init_uart();
void receive_image(u8* buffer, u32 size);
void send_image(u8* buffer, u32 size);

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
        return XST_FAILURE;
    }

    // Wait for S2MM complete
    while(XAxiDma_Busy(&axidma, XAXIDMA_DEVICE_TO_DMA));

    // Wait for MM2S complete
    while(XAxiDma_Busy(&axidma, XAXIDMA_DMA_TO_DEVICE));

    // Send output image
    send_image(output_buffer, IMAGE_SIZE);

    return XST_SUCCESS;
}

int init_dma()
{
    XAxiDma_Config *config;
    int status;

    config = XAxiDma_LookupConfig(XPAR_XAXIDMA_0_BASEADDR);
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

    config = XUartPs_LookupConfig(XPAR_XUARTPS_0_BASEADDR);
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