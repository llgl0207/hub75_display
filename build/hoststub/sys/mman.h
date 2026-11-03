#ifndef HOST_MMAN_H
#define HOST_MMAN_H
#include <stddef.h>
#define PROT_READ 1
#define PROT_WRITE 2
#define MAP_SHARED 1
#define MAP_FAILED ((void *)-1)
static inline void *mmap(void *a, size_t b, int c, int d, int e, long f){(void)a;(void)b;(void)c;(void)d;(void)e;(void)f;return MAP_FAILED;}
#endif
