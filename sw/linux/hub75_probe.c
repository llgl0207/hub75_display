/*
 * hub75_probe - verify the PL AXI path under Linux.
 *
 * Maps the two AXI GPIO blocks through /dev/mem, prints the register
 * values, writes a known frame_base and reads it back. Run as root.
 *
 * Build:
 *   E:\AMD\2026.1\gnu\aarch32\nt\gcc-arm-linux-gnueabi\bin\arm-linux-gnueabihf-gcc.exe \
 *       -static -O2 -o hub75_probe hub75_probe.c
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define CTRL_PHYS 0x41200000UL
#define STAT_PHYS 0x41210000UL
#define FRAME_A   0x10000000UL

static volatile uint32_t *map_phys(int fd, unsigned long phys, const char *what)
{
    void *p = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)phys);
    if (p == MAP_FAILED) {
        fprintf(stderr, "mmap %s @0x%lx: %s\n", what, phys, strerror(errno));
        return NULL;
    }
    return (volatile uint32_t *)p;
}

int main(void)
{
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
        fprintf(stderr, "open /dev/mem: %s\n", strerror(errno));
        return 1;
    }

    volatile uint32_t *ctrl = map_phys(fd, CTRL_PHYS, "ctrl");
    volatile uint32_t *stat = map_phys(fd, STAT_PHYS, "status");
    if (!ctrl || !stat) return 1;

    printf("ctrl[0..3] = %08x %08x %08x %08x\n",
           ctrl[0], ctrl[1], ctrl[2], ctrl[3]);
    printf("stat[0..3] = %08x %08x %08x %08x\n",
           stat[0], stat[1], stat[2], stat[3]);

    ctrl[0] = (uint32_t)FRAME_A;
    __sync_synchronize();
    (void)ctrl[0];

    printf("frame_base written 0x%08lx, readback ctrl[0]=%08x\n",
           FRAME_A, ctrl[0]);
    printf("status now: stat[0]=%08x period=%08x\n", stat[0], stat[2]);
    printf("probe done\n");

    munmap((void *)ctrl, 4096);
    munmap((void *)stat, 4096);
    close(fd);
    return 0;
}
