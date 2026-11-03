#ifndef HOST_SYS_IOCTL_H
#define HOST_SYS_IOCTL_H
static inline int ioctl(int fd, unsigned long req, ...){(void)fd;(void)req;return -1;}
#endif
