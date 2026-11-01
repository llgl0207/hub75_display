/*
 * Stage 0 PS bring-up: prove PS boot and UART0 on MIO14/15 (USB-UART; CP2102 on this board).
 *
 * Create a Vitis application from board/output/hub75_ps_stage0.xsa with the
 * "Hello World" or "Empty Application (C)" template and use this file as
 * main.c. For a DDR-independent check, edit lscript.ld so .text/.data/.bss/
 * stack live in ps7_ram_0/ps7_ram_1 (OCM) instead of ps7_ddr_0.
 */

#include "sleep.h"
#include "xil_cache.h"
#include "xil_printf.h"

int main(void)
{
    Xil_DCacheDisable();
    xil_printf("\r\nHUB75 PS hello (UART0 MIO14/15)\r\n");

    for (;;) {
        xil_printf(".");
        sleep(1);
    }

    return 0;
}
