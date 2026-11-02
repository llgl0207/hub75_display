    .section .text.start, "ax"
    .global _start
    .arm
_start:
    cpsid if
    /* Disable MMU, D-cache and I-cache: we run with physical addresses and
     * may be entered after another bare-metal app (or Linux) left caches on. */
    mrc p15, 0, r0, c1, c0, 0
    bic r0, r0, #(1 << 0)      /* MMU */
    bic r0, r0, #(1 << 2)      /* D-cache */
    bic r0, r0, #(1 << 12)     /* I-cache */
    mcr p15, 0, r0, c1, c0, 0
    isb
    /* Drop stale instructions/data from the previous program at these
     * addresses. Full invalidate-all is safe for the bench. */
    mov r0, #0
    mcr p15, 0, r0, c7, c5, 0  /* ICIALLU */
    mcr p15, 0, r0, c7, c5, 6  /* BPIALL */
    dsb
    isb

    ldr sp, =0x08000000        /* 128 MiB into DDR3 */
    ldr r0, =__bss_start
    ldr r1, =__bss_end
    mov r2, #0
1:
    cmp r0, r1
    strlo r2, [r0], #4
    blo 1b
    bl main
2:
    b 2b
