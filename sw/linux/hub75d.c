/*
 * hub75d - HUB75 rotating display driver daemon (Linux, HP0/DDR path).
 *
 * v1: console mode. Creates a PTY 16x4, runs an interactive shell on it,
 * parses the shell's VT100 output, renders the text with an 8x16 font into
 * the DDR frame buffer and submits it to the PL through the AXI GPIO block.
 *
 * Frame path: frame A/B at 0x10000000 / 0x10200000 (outside mem=256M), the PL
 * reads them through S_AXI_HP0 (ARCACHE non-cacheable in the bitstream).
 * Submit protocol: write frame_base, let it settle, toggle submit bit0; if
 * the pending bit does not set, toggle again. The PL commits the pending
 * frame at the next revolution.
 *
 * Run as root:  ./hub75d [shell]
 * Quit with Ctrl-C (the shell on the panel dies with it).
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/select.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <pty.h>
#include <poll.h>
#include <sched.h>
#include <sys/stat.h>
#include <signal.h>
#include <termios.h>
#include <unistd.h>

#include "hub75_font.h"

#define CTRL_PHYS   0x41200000UL
#define STAT_PHYS   0x41210000UL
#define FRAME_A     0x10000000UL
#define FRAME_B     0x10200000UL
#define GT_PHYS     0xF8F00000UL

#define SLICES      64
#define SLICE_BYTES 3072
#define FRAME_BYTES (SLICES * SLICE_BYTES)
#define FRAME_SPAN  (FRAME_B - FRAME_A)

#define COLS        16
#define ROWS        4
#define CHAR_W      8
#define CHAR_H      16
#define PANEL_W     128
#define PANEL_H     64

#define FG 7
#define BG 0

static volatile uint32_t *ctrl, *statp, *gt;
static uint8_t *frame_map;          /* covers A and B */
static uint8_t slice_img[SLICE_BYTES];

/* text grid */
static char text[ROWS][COLS + 1];
static int cur_x, cur_y;

static uint64_t ticks(void)
{
    uint32_t hi, lo, hi2;
    do { hi = gt[0x204 / 4]; lo = gt[0x200 / 4]; hi2 = gt[0x204 / 4]; }
    while (hi != hi2);
    return ((uint64_t)hi << 32) | lo;
}
#define TICKS_PER_MS 333333ULL

static void text_clear(void)
{
    for (int r = 0; r < ROWS; r++) {
        memset(text[r], ' ', COLS);
        text[r][COLS] = 0;
    }
    cur_x = cur_y = 0;
}

static void text_scroll(void)
{
    memmove(text[0], text[1], (ROWS - 1) * (COLS + 1));
    memset(text[ROWS - 1], ' ', COLS);
    text[ROWS - 1][COLS] = 0;
    if (cur_y > 0) cur_y--;
}

static void text_put(char ch)
{
    if (ch == '\n') {
        cur_x = 0;
        if (++cur_y >= ROWS) text_scroll();
    } else if (ch == '\r') {
        cur_x = 0;
    } else if (ch == '\b') {
        if (cur_x > 0) cur_x--;
    } else if (ch >= 32 && ch < 127) {
        if (cur_x >= COLS) { cur_x = 0; if (++cur_y >= ROWS) text_scroll(); }
        if (cur_y >= 0 && cur_y < ROWS)
            text[cur_y][cur_x] = ch;
        cur_x++;
    }
}

/* Tiny VT100 state machine (enough for busybox ash and common tools). */
static void vt_feed(const unsigned char *buf, int n)
{
    static int state = 0;        /* 0 normal, 1 esc, 2 csi */
    static int params[8], np, cur;
    static int have_cur = 0;

    for (int i = 0; i < n; i++) {
        unsigned char c = buf[i];
        if (state == 0) {
            if (c == 0x1b) { state = 1; continue; }
            text_put((char)c);
        } else if (state == 1) {
            if (c == '[') { state = 2; np = 0; cur = 0; have_cur = 0; }
            else if (c == '(' || c == ')' || c == '#') { state = 3; }
            else state = 0;
        } else if (state == 2) {
            if (c >= '0' && c <= '9') {
                cur = cur * 10 + (c - '0');
                have_cur = 1;
            } else if (c == ';') {
                if (np < 7) params[np++] = have_cur ? cur : 0;
                cur = 0; have_cur = 0;
            } else {
                if (np < 7) params[np++] = have_cur ? cur : 0;
                if (c == 'H' || c == 'f') {
                    int r = (params[0] > 0 ? params[0] : 1) - 1;
                    int cc = (np > 1 && params[1] > 0 ? params[1] : 1) - 1;
                    if (r < 0) r = 0; if (r >= ROWS) r = ROWS - 1;
                    if (cc < 0) cc = 0; if (cc >= COLS) cc = COLS - 1;
                    cur_y = r; cur_x = cc;
                } else if (c == 'J') {
                    if (have_cur && params[0] == 2) text_clear();
                } else if (c == 'K') {
                    if (cur_y >= 0 && cur_y < ROWS) {
                        for (int x = cur_x; x < COLS; x++) text[cur_y][x] = ' ';
                    }
                } else if (c == 'A') {
                    cur_y -= (have_cur && cur ? cur : 1);
                    if (cur_y < 0) cur_y = 0;
                } else if (c == 'B') {
                    cur_y += (have_cur && cur ? cur : 1);
                    if (cur_y >= ROWS) cur_y = ROWS - 1;
                } else if (c == 'C') {
                    cur_x += (have_cur && cur ? cur : 1);
                    if (cur_x >= COLS) cur_x = COLS - 1;
                } else if (c == 'D') {
                    cur_x -= (have_cur && cur ? cur : 1);
                    if (cur_x < 0) cur_x = 0;
                }
                state = 0;
            }
        } else if (state == 3) {
            state = 0;
        }
    }
}

static int render_text(int cursor)
{
    static uint8_t up[32][PANEL_W];
    static uint8_t lo[32][PANEL_W];
    memset(up, 0, sizeof(up));
    memset(lo, 0, sizeof(lo));

    for (int r = 0; r < ROWS; r++) {
        for (int c = 0; c < COLS; c++) {
            char ch = text[r][c];
            if (ch < 32 || ch > 126) ch = ' ';
            const uint8_t *g = hub75_font8x16[(int)ch - 32];
            for (int gy = 0; gy < CHAR_H; gy++) {
                uint8_t bits = g[gy];
                if (!bits) continue;
                int y = r * CHAR_H + gy;
                for (int gx = 0; gx < CHAR_W; gx++) {
                    if (!(bits & (0x80 >> gx))) continue;
                    int x = c * CHAR_W + gx;
                    if (y < 32) up[y][x] = 1; else lo[y - 32][x] = 1;
                }
            }
        }
    }
    /* block cursor */
    if (cursor && cur_y >= 0 && cur_y < ROWS && cur_x >= 0 && cur_x < COLS) {
        int y0 = cur_y * CHAR_H + CHAR_H - 2;
        int x0 = cur_x * CHAR_W;
        for (int x = x0; x < x0 + CHAR_W && x < PANEL_W; x++) {
            if (y0 < 32) up[y0][x] = 1; else lo[y0 - 32][x] = 1;
        }
    }

    memset(slice_img, 0, SLICE_BYTES);
    for (int r = 0; r < 32; r++) {
        for (int c = 0; c < PANEL_W; c++) {
            uint32_t w = (up[r][PANEL_W - 1 - c] ? FG : BG) |
                        (((lo[r][PANEL_W - 1 - c] ? FG : BG)) << 3);
            uint32_t bit = (r * PANEL_W + c) * 6;
            uint32_t byte = bit >> 3, sh = bit & 7;
            uint32_t v = w << sh;
            slice_img[byte] |= v & 0xFF;
            if (sh > 2) slice_img[byte + 1] |= (v >> 8) & 0xFF;
        }
    }
    return 1;
}

static int anim_pid = -1;
static int g_dirty = 1;
static int cmd_fd = -1;

static void load_config(void)
{
    FILE *f = fopen("/etc/hub75.conf", "r");
    char line[160];
    if (!f) return;
    while (fgets(line, sizeof(line), f)) {
        if (line[0] == '#' || line[0] == '\n') continue;
        if (!strncmp(line, "anim=", 5)) {
            char *path = line + 5;
            int n = (int)strlen(path);
            while (n > 0 && (path[n-1] == '\n' || path[n-1] == '\r')) path[--n] = 0;
            if (n > 0) {
                pid_t ap = fork();
                if (ap == 0) { execl(path, path, (char *)NULL); _exit(127); }
                anim_pid = (ap > 0) ? ap : -1;
            }
        }
    }
    fclose(f);
}

static void setup_cmd_fifo(void)
{
    const char *path = "/run/hub75.cmd";
    struct stat st;
    if (stat(path, &st) == 0 && !S_ISFIFO(st.st_mode)) unlink(path);
    if (stat(path, &st) != 0) mkfifo(path, 0666);
    cmd_fd = open(path, O_RDWR | O_NONBLOCK);
}

static void handle_cmd(char *line)
{
    int n = (int)strlen(line);
    while (n > 0 && (line[n-1] == '\n' || line[n-1] == '\r' || line[n-1] == ' ' || line[n-1] == '\t')) line[--n] = 0;
    char *p = line;
    while (*p == ' ' || *p == '\t') p++;

    if (!strncmp(p, "mode anim ", 10)) {
        const char *path = p + 10;
        if (anim_pid > 0) { kill(anim_pid, SIGTERM); waitpid(anim_pid, NULL, 0); }
        pid_t ap = fork();
        if (ap == 0) { execl(path, path, (char *)NULL); _exit(127); }
        anim_pid = (ap > 0) ? ap : -1;
        fprintf(stderr, "hub75d: anim mode -> %s", path);
    } else if (!strcmp(p, "mode console")) {
        if (anim_pid > 0) { kill(anim_pid, SIGTERM); waitpid(anim_pid, NULL, 0); anim_pid = -1; }
        g_dirty = 1;
        fprintf(stderr, "hub75d: console mode");
    } else if (!strncmp(p, "text ", 5)) {
        const char *t = p + 5;
        int r = 0, c = 0;
        text_clear();
        while (*t && r < ROWS) {
            if (*t == '\n') { r++; c = 0; }
            else { if (c < COLS) text[r][c] = *t; c++; }
            t++;
        }
        g_dirty = 1;
    } else if (!strcmp(p, "clear")) {
        text_clear();
        g_dirty = 1;
    } else if (!strcmp(p, "quit")) {
        exit(0);
    }
}

static void sleep_ms(unsigned ms)
{
    uint64_t t0 = ticks();
    while ((ticks() - t0) < (uint64_t)ms * TICKS_PER_MS)
        ;
}

static int submit_frame(uint8_t *dst, uint32_t phys_base)
{
    const uint32_t *src = (const uint32_t *)slice_img;
    uint64_t t0 = ticks();
    uint32_t pend;

    for (int s = 0; s < SLICES; s++) {
        uint32_t *d = (uint32_t *)(dst + s * SLICE_BYTES);
        for (int i = 0; i < SLICE_BYTES / 4; i++)
            d[i] = src[i];
        sched_yield();
    }

    ctrl[0] = phys_base;
    __sync_synchronize();
    (void)ctrl[0];
    sleep_ms(2);
    ctrl[2] = ((ctrl[2] ^ 1u) & 1u) | 2u;
    __sync_synchronize();
    sleep_ms(1);
    pend = (statp[0] >> 5) & 1u;
    if (!pend) {
        ctrl[2] = ((ctrl[2] ^ 1u) & 1u) | 2u;
        __sync_synchronize();
    }
    return (int)((ticks() - t0) / TICKS_PER_MS);
}

int main(int argc, char **argv)
{
    const char *shell = argc > 1 ? argv[1] : "/bin/sh";
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); return 1; }

    ctrl = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, CTRL_PHYS);
    statp = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, STAT_PHYS);
    gt = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, GT_PHYS);
    frame_map = mmap(NULL, FRAME_SPAN + FRAME_BYTES, PROT_READ | PROT_WRITE, MAP_SHARED, fd, FRAME_A);
    if (ctrl == MAP_FAILED || statp == MAP_FAILED || gt == MAP_FAILED || frame_map == MAP_FAILED) {
        perror("mmap");
        return 1;
    }
    ctrl[1] = 0;
    ctrl[3] = 0;
    __sync_synchronize();

    int mfd, sfd;
    struct winsize ws = { .ws_row = ROWS, .ws_col = COLS, .ws_xpixel = 0, .ws_ypixel = 0 };
    if (openpty(&mfd, &sfd, NULL, NULL, &ws) < 0) { perror("openpty"); return 1; }

    {
        struct pollfd pf = { .fd = mfd, .events = POLLIN };
        char tbuf[64];
        ssize_t wn = write(sfd, "PTY-SELFTEST", 12);
        int rr = poll(&pf, 1, 500);
        int n = (rr > 0 && (pf.revents & POLLIN)) ? (int)read(mfd, tbuf, sizeof(tbuf)) : -1;
        fprintf(stderr, "hub75d: pty selftest w=%d poll=%d n=%d mfd=%d", (int)wn, rr, n, mfd);
    }

    pid_t pid = fork();
    if (pid == 0) {
        close(mfd);
        setsid();
        ioctl(sfd, TIOCSCTTY, 0);
        dup2(sfd, 0); dup2(sfd, 1); dup2(sfd, 2);
        if (sfd > 2) close(sfd);
        write(1, "HUB75D-CHILD", 12);
        execl(shell, shell, "-i", (char *)NULL);
        _exit(127);
    }
    close(sfd);

    text_clear();
    memcpy(text[0], "HUB75D READY   ", COLS);
    memcpy(text[1], "PTY 16x4       ", COLS);
    memcpy(text[2], "ABCDEFGHIJKLMNO", COLS);
    memcpy(text[3], "abcdefghijklmno", COLS);

    load_config();
    setup_cmd_fifo();
    unsigned fb = 0;
    uint64_t last_submit = 0;
    g_dirty = 1;
    unsigned char buf[256];

    for (;;) {
        struct pollfd pf[3] = { { .fd = mfd, .events = POLLIN }, { .fd = 0, .events = POLLIN }, { .fd = cmd_fd, .events = POLLIN } };
        int r = poll(pf, 3, 20);
        if (r > 0 && (pf[0].revents & POLLIN)) {
            ssize_t n = read(mfd, buf, sizeof(buf));
            if (n > 0) {
                static int pe = 0;
                if (pe < 8) { fprintf(stderr, "hub75d: pty [%d]", (int)n); pe++; }
                vt_feed(buf, (int)n);
                g_dirty = 1;
            }
        }
        if (r > 0 && (pf[1].revents & POLLIN)) {
            ssize_t n = read(0, buf, sizeof(buf));
            if (n > 0) {
                ssize_t off = 0;
                while (off < n) {
                    ssize_t w = write(mfd, buf + off, (size_t)(n - off));
                    if (w <= 0) break;
                    off += w;
                }
            }
        }
        if (r > 0 && cmd_fd >= 0 && (pf[2].revents & POLLIN)) {
            ssize_t n = read(cmd_fd, buf, sizeof(buf) - 1);
            if (n > 0) {
                buf[n] = 0;
                char *line = (char *)buf;
                char *nl;
                while ((nl = strchr(line, '\n')) != NULL) {
                    *nl = 0;
                    handle_cmd(line);
                    line = nl + 1;
                }
                if (*line) handle_cmd(line);
            }
        }
        if (anim_pid > 0) {
            int wst = 0;
            if (waitpid(anim_pid, &wst, WNOHANG) == anim_pid) {
                anim_pid = -1;
                g_dirty = 1;
                last_submit = 0;
                fprintf(stderr, "hub75d: anim exited");
            }
        }
        {
            uint64_t now = ticks();
            if (anim_pid < 0 && g_dirty && (now - last_submit) > 80ULL * TICKS_PER_MS) {
                render_text(1);
                uint8_t *dst = frame_map + (fb ? FRAME_SPAN : 0);
                uint32_t phys = fb ? FRAME_B : FRAME_A;
                int ms = submit_frame(dst, phys);
                {
                    static int sl = 0;
                    if (sl < 6) {
                        uint32_t st = statp[0];
                        fprintf(stderr, "hub75d: submit %08x %dms st=%08x id=%u", phys, ms, st, (st >> 16) & 0xff);
                        sl++;
                    }
                }
                fb ^= 1;
                last_submit = now;
                g_dirty = 0;
            }
        }
        {
            static int reaped = 0;
            if (!reaped) {
                int wst = 0;
                if (waitpid(pid, &wst, WNOHANG) == pid) {
                    fprintf(stderr, "hub75d: child exit %d", wst);
                    reaped = 1;
                }
            }
        }
    }
    return 0;
}
