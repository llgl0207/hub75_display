#ifndef HUB75_REGS_H
#define HUB75_REGS_H

#include <stdint.h>
#include "xparameters.h"

/* AXI GPIO instance names come from build/create_ps_bd.tcl.
 *
 * Vitis 2026.1 builds the standalone BSP with -DSDT, so XGpio_Initialize takes
 * a base address, not a device ID. Older non-SDT BSPs take a DeviceId.
 */
#ifdef SDT
#define HUB75_GPIO_CTRL_INIT_ARG     XPAR_AXI_GPIO_CTRL_BASEADDR
#define HUB75_GPIO_STATUS_INIT_ARG   XPAR_AXI_GPIO_STATUS_BASEADDR
#else
#define HUB75_GPIO_CTRL_INIT_ARG     XPAR_AXI_GPIO_CTRL_DEVICE_ID
#define HUB75_GPIO_STATUS_INIT_ARG   XPAR_AXI_GPIO_STATUS_DEVICE_ID
#endif

#define HUB75_GPIO_CH1               1
#define HUB75_GPIO_CH2               2

/* frame_ctrl (GPIO ctrl channel 2) */
#define HUB75_CTRL_SUBMIT            (1u << 0)  /* toggle per submitted frame */
#define HUB75_CTRL_ENABLE            (1u << 1)
#define HUB75_CTRL_SLICES(n)         (((uint32_t)(n) & 0xFFu) << 8)

/* status (GPIO status channel 1) */
#define HUB75_ST_ACK                 (1u << 0)
#define HUB75_ST_BUSY                (1u << 1)
#define HUB75_ST_BUF_READY           (1u << 2)
#define HUB75_ST_FRAME_DONE          (1u << 3)
#define HUB75_ST_SLICE(s)            (((s) >> 8) & 0x3Fu)
#define HUB75_ST_FRAME_ID(s)         (((s) >> 16) & 0xFFu)

#endif
