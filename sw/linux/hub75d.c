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
#include <linux/input.h>

#include "hub75_font.h"
#include "hub75_font8x8.h"

#define CTRL_PHYS   0x41200000UL
#define STAT_PHYS   0x41210000UL
#define FRAME_A     0x10000000UL
#define FRAME_B     0x10200000UL
#define GT_PHYS     0xF8F00000UL

#define SLICES      64
#define SLICE_BYTES 3072
#define FRAME_BYTES (SLICES * SLICE_BYTES)
#define FRAME_SPAN  (FRAME_B - FRAME_A)

#define MAX_COLS    16
#define MAX_ROWS    8
#define CHAR_W      8
#define PANEL_W     128
#define PANEL_H     64

/* Runtime text geometry: font=8x16 -> 16x4, font=8x8 -> 16x8. */
static int g_cols = 16;
static int g_rows = 4;
static int g_char_h = 16;
static const uint8_t *g_font = (const uint8_t *)hub75_font8x16;

#define FG 7
#define BG 0

static volatile uint32_t *ctrl, *statp, *gt;
static uint8_t *frame_map;          /* covers A and B */
static uint8_t slice_img[SLICE_BYTES];

/* text grid */
static char text[MAX_ROWS][MAX_COLS + 1];
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
    for (int r = 0; r < g_rows; r++) {
        memset(text[r], ' ', g_cols);
        text[r][g_cols] = 0;
    }
    cur_x = cur_y = 0;
}

static void text_scroll(void)
{
    memmove(text[0], text[1], (size_t)(g_rows - 1) * (MAX_COLS + 1));
    memset(text[g_rows - 1], ' ', MAX_COLS);
    text[g_rows - 1][MAX_COLS] = 0;
    if (cur_y > 0) cur_y--;
}

static void text_put(char ch)
{
    if (ch == '\n') {
        cur_x = 0;
        if (++cur_y >= g_rows) text_scroll();
    } else if (ch == '\r') {
        cur_x = 0;
    } else if (ch == '\b') {
        if (cur_x > 0) cur_x--;
    } else if (ch >= 32 && ch < 127) {
        if (cur_x >= g_cols) { cur_x = 0; if (++cur_y >= g_rows) text_scroll(); }
        if (cur_y >= 0 && cur_y < g_rows)
            text[cur_y][cur_x] = ch;
        cur_x++;
    }
}

static void text_line(int r, const char *s)
{
    if (r < 0 || r >= g_rows) return;
    int n = (int)strlen(s);
    if (n > g_cols) n = g_cols;
    memset(text[r], ' ', g_cols);
    memcpy(text[r], s, (size_t)n);
    text[r][g_cols] = 0;
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
            else if (c == 'c') { text_clear(); state = 0; }   /* RIS */
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
                    if (r < 0) r = 0; if (r >= g_rows) r = g_rows - 1;
                    if (cc < 0) cc = 0; if (cc >= g_cols) cc = g_cols - 1;
                    cur_y = r; cur_x = cc;
                } else if (c == 'J') {
                    /* ED: 0/no-param = cursor..end, 1 = start..cursor,
                     * 2/3 = whole screen (busybox clear sends ESC[H ESC[J). */
                    int mode = have_cur ? params[0] : 0;
                    if (mode == 0) {
                        if (cur_y >= 0 && cur_y < g_rows) {
                            for (int x = cur_x; x < g_cols; x++) text[cur_y][x] = ' ';
                            for (int r = cur_y + 1; r < g_rows; r++) {
                                memset(text[r], ' ', g_cols);
                                text[r][g_cols] = 0;
                            }
                        }
                    } else if (mode == 1) {
                        for (int r = 0; r < cur_y && r < g_rows; r++) {
                            memset(text[r], ' ', g_cols);
                            text[r][g_cols] = 0;
                        }
                        if (cur_y >= 0 && cur_y < g_rows) {
                            for (int x = 0; x <= cur_x && x < g_cols; x++)
                                text[cur_y][x] = ' ';
                        }
                    } else {
                        text_clear();
                    }
                } else if (c == 'K') {
                    /* EL: 0 = cursor..EOL, 1 = BOL..cursor, 2 = whole line. */
                    int mode = have_cur ? params[0] : 0;
                    if (cur_y >= 0 && cur_y < g_rows) {
                        int x0 = cur_x, x1 = g_cols - 1;
                        if (mode == 1) { x0 = 0; x1 = cur_x; }
                        else if (mode == 2) { x0 = 0; x1 = g_cols - 1; }
                        for (int x = x0; x <= x1 && x < g_cols; x++)
                            text[cur_y][x] = ' ';
                    }
                } else if (c == 'A') {
                    cur_y -= (have_cur && cur ? cur : 1);
                    if (cur_y < 0) cur_y = 0;
                } else if (c == 'B') {
                    cur_y += (have_cur && cur ? cur : 1);
                    if (cur_y >= g_rows) cur_y = g_rows - 1;
                } else if (c == 'C') {
                    cur_x += (have_cur && cur ? cur : 1);
                    if (cur_x >= g_cols) cur_x = g_cols - 1;
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

    for (int r = 0; r < g_rows; r++) {
        for (int c = 0; c < g_cols; c++) {
            char ch = text[r][c];
            if (ch < 32 || ch > 126) ch = ' ';
            const uint8_t *g = g_font + ((int)ch - 32) * g_char_h;
            for (int gy = 0; gy < g_char_h; gy++) {
                uint8_t bits = g[gy];
                if (!bits) continue;
                int y = r * g_char_h + gy;
                for (int gx = 0; gx < CHAR_W; gx++) {
                    if (!(bits & (0x80 >> gx))) continue;
                    int x = c * CHAR_W + gx;
                    if (y < 32) up[y][x] = 1; else lo[y - 32][x] = 1;
                }
            }
        }
    }
    /* block cursor */
    if (cursor && cur_y >= 0 && cur_y < g_rows && cur_x >= 0 && cur_x < g_cols) {
        int y0 = cur_y * g_char_h + g_char_h - 2;
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

/* ---------------- USB keyboard (Linux evdev) ----------------
 *
 * The 4.14 input ABI is a 16-byte record with a 32-bit timeval.  The Vitis
 * glibc is built with 64-bit time_t, so its struct input_event does not match
 * the wire format; parse the raw record ourselves.
 */
#define MAX_KBD     8
#define EV_REC_SIZE 16

struct ev_rec {
    uint32_t sec, usec;
    uint16_t type, code;
    int32_t value;
};

static int kbd_fds[MAX_KBD];
static int kbd_count;
static int kbd_mfd = -1;
static int shift_held, ctrl_held, caps_lock;
static char cfg_shell[160];

static const char key_plain[128] = {
    [KEY_1] = '1', [KEY_2] = '2', [KEY_3] = '3', [KEY_4] = '4',
    [KEY_5] = '5', [KEY_6] = '6', [KEY_7] = '7', [KEY_8] = '8',
    [KEY_9] = '9', [KEY_0] = '0', [KEY_MINUS] = '-', [KEY_EQUAL] = '=',
    [KEY_Q] = 'q', [KEY_W] = 'w', [KEY_E] = 'e', [KEY_R] = 'r',
    [KEY_T] = 't', [KEY_Y] = 'y', [KEY_U] = 'u', [KEY_I] = 'i',
    [KEY_O] = 'o', [KEY_P] = 'p', [KEY_LEFTBRACE] = '[', [KEY_RIGHTBRACE] = ']',
    [KEY_A] = 'a', [KEY_S] = 's', [KEY_D] = 'd', [KEY_F] = 'f',
    [KEY_G] = 'g', [KEY_H] = 'h', [KEY_J] = 'j', [KEY_K] = 'k',
    [KEY_L] = 'l', [KEY_SEMICOLON] = ';', [KEY_APOSTROPHE] = '\'',
    [KEY_GRAVE] = '`', [KEY_BACKSLASH] = '\\',
    [KEY_Z] = 'z', [KEY_X] = 'x', [KEY_C] = 'c', [KEY_V] = 'v',
    [KEY_B] = 'b', [KEY_N] = 'n', [KEY_M] = 'm', [KEY_COMMA] = ',',
    [KEY_DOT] = '.', [KEY_SLASH] = '/', [KEY_SPACE] = ' ',
    [KEY_KP0] = '0', [KEY_KP1] = '1', [KEY_KP2] = '2', [KEY_KP3] = '3',
    [KEY_KP4] = '4', [KEY_KP5] = '5', [KEY_KP6] = '6', [KEY_KP7] = '7',
    [KEY_KP8] = '8', [KEY_KP9] = '9', [KEY_KPASTERISK] = '*',
    [KEY_KPMINUS] = '-', [KEY_KPPLUS] = '+', [KEY_KPDOT] = '.',
    [KEY_KPSLASH] = '/',
};

static const char key_shifted[128] = {
    [KEY_1] = '!', [KEY_2] = '@', [KEY_3] = '#', [KEY_4] = '$',
    [KEY_5] = '%', [KEY_6] = '^', [KEY_7] = '&', [KEY_8] = '*',
    [KEY_9] = '(', [KEY_0] = ')', [KEY_MINUS] = '_', [KEY_EQUAL] = '+',
    [KEY_LEFTBRACE] = '{', [KEY_RIGHTBRACE] = '}',
    [KEY_SEMICOLON] = ':', [KEY_APOSTROPHE] = '"', [KEY_GRAVE] = '~',
    [KEY_BACKSLASH] = '|', [KEY_COMMA] = '<', [KEY_DOT] = '>',
    [KEY_SLASH] = '?', [KEY_SPACE] = ' ',
    [KEY_KPASTERISK] = '*', [KEY_KPMINUS] = '-', [KEY_KPPLUS] = '+',
    [KEY_KPDOT] = '.', [KEY_KPSLASH] = '/',
};

static void kbd_write(const char *s, int n)
{
    int off = 0;
    while (kbd_mfd >= 0 && off < n) {
        int w = (int)write(kbd_mfd, s + off, (size_t)(n - off));
        if (w <= 0) return;
        off += w;
    }
}

static int kbd_probe(int fd)
{
    unsigned long bits[8];
    memset(bits, 0, sizeof(bits));
    if (ioctl(fd, EVIOCGBIT(0, sizeof(bits)), bits) < 0) return 0;
    if (!(bits[0] & (1UL << EV_KEY))) return 0;
    memset(bits, 0, sizeof(bits));
    if (ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(bits)), bits) < 0) return 0;
    return (int)((bits[KEY_A / (8 * (int)sizeof(unsigned long))] >>
                  (KEY_A % (8 * (int)sizeof(unsigned long)))) & 1UL);
}

static void kbd_scan(void)
{
    char path[32];
    for (int i = 0; i < 32 && kbd_count < MAX_KBD; i++) {
        snprintf(path, sizeof(path), "/dev/input/event%d", i);
        int fd = open(path, O_RDONLY | O_NONBLOCK);
        if (fd < 0) continue;
        if (!kbd_probe(fd)) { close(fd); continue; }
        kbd_fds[kbd_count++] = fd;
        fprintf(stderr, "hub75d: kbd %s", path);
    }
}

static void enter_console(void)
{
    if (anim_pid > 0) { kill(anim_pid, SIGTERM); waitpid(anim_pid, NULL, 0); }
    anim_pid = -1;
    g_dirty = 1;
}

static void kbd_key(uint16_t code, int value)
{
    char out[8];
    int n = 0;

    if (code >= 128) return;
    if (value == 0) {
        if (code == KEY_LEFTSHIFT || code == KEY_RIGHTSHIFT) shift_held = 0;
        else if (code == KEY_LEFTCTRL || code == KEY_RIGHTCTRL) ctrl_held = 0;
        return;
    }
    if (code == KEY_LEFTSHIFT || code == KEY_RIGHTSHIFT) { shift_held = 1; return; }
    if (code == KEY_LEFTCTRL || code == KEY_RIGHTCTRL) { ctrl_held = 1; return; }
    if (code == KEY_CAPSLOCK) { if (value == 1) caps_lock = !caps_lock; return; }
    if (code == KEY_LEFTALT || code == KEY_RIGHTALT ||
        code == KEY_LEFTMETA || code == KEY_RIGHTMETA) return;

    /* Typing while an animation runs brings the shell back. */
    if (anim_pid > 0) enter_console();

    switch (code) {
    case KEY_ENTER:
    case KEY_KPENTER:  out[n++] = '\r'; break;
    case KEY_BACKSPACE: out[n++] = 0x7f; break;
    case KEY_TAB:      out[n++] = '\t'; break;
    case KEY_ESC:      out[n++] = 0x1b; break;
    case KEY_UP:       n = sprintf(out, "\033[A"); break;
    case KEY_DOWN:     n = sprintf(out, "\033[B"); break;
    case KEY_RIGHT:    n = sprintf(out, "\033[C"); break;
    case KEY_LEFT:     n = sprintf(out, "\033[D"); break;
    case KEY_HOME:     n = sprintf(out, "\033[H"); break;
    case KEY_END:      n = sprintf(out, "\033[F"); break;
    case KEY_DELETE:   n = sprintf(out, "\033[3~"); break;
    case KEY_INSERT:   n = sprintf(out, "\033[2~"); break;
    case KEY_PAGEUP:   n = sprintf(out, "\033[5~"); break;
    case KEY_PAGEDOWN: n = sprintf(out, "\033[6~"); break;
    default: {
        char c = shift_held ? key_shifted[code] : key_plain[code];
        if (c >= 'a' && c <= 'z') {
            if (shift_held ^ caps_lock) c -= 32;
        } else if (!c && shift_held) {
            c = key_plain[code];      /* shift on a key with no shifted symbol */
        }
        if (!c) return;
        if (ctrl_held) {
            if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))
                c = (char)((c | 0x20) - 'a' + 1);
            else if (c == '[')  c = 0x1b;
            else if (c == '\\') c = 0x1c;
            else if (c == ']')  c = 0x1d;
            else if (c == '^')  c = 0x1e;
            else if (c == '_')  c = 0x1f;
        }
        out[n++] = c;
        break;
    }
    }
    if (n > 0) kbd_write(out, n);
}

static void kbd_feed(int idx)
{
    static unsigned char acc[MAX_KBD][EV_REC_SIZE];
    static int acc_n[MAX_KBD];
    unsigned char buf[256];
    int fd = kbd_fds[idx];
    int r = (int)read(fd, buf, sizeof(buf));

    if (r <= 0) {
        if (r == 0 || (r < 0 && errno != EAGAIN && errno != EINTR)) {
            close(fd);
            for (int k = idx; k + 1 < kbd_count; k++) {
                kbd_fds[k] = kbd_fds[k + 1];
                memcpy(acc[k], acc[k + 1], EV_REC_SIZE);
                acc_n[k] = acc_n[k + 1];
            }
            kbd_count--;
            fprintf(stderr, "hub75d: kbd removed");
        }
        return;
    }

    int used = 0;
    while (used < r) {
        int need = EV_REC_SIZE - acc_n[idx];
        int take = (r - used < need) ? (r - used) : need;
        memcpy(acc[idx] + acc_n[idx], buf + used, (size_t)take);
        acc_n[idx] += take;
        used += take;
        if (acc_n[idx] == EV_REC_SIZE) {
            struct ev_rec *ev = (struct ev_rec *)acc[idx];
            if (ev->type == EV_KEY) kbd_key(ev->code, ev->value);
            acc_n[idx] = 0;
        }
    }
}

static volatile sig_atomic_t reload_req;
static void on_hup(int sig) { (void)sig; reload_req = 1; }

static void load_config(void)
{
    /* FAT copy first so it survives reboots (rootfs is an initramfs). */
    static const char *paths[] = {
        "/run/media/mmcblk0p1/hub75.conf",
        "/etc/hub75.conf",
    };
    FILE *f = NULL;
    char line[160];

    for (int i = 0; i < 2 && !f; i++) f = fopen(paths[i], "r");
    if (!f) return;
    while (fgets(line, sizeof(line), f)) {
        char *val = NULL;
        int key = 0;
        if (line[0] == '#' || line[0] == '\n') continue;
        if (!strncmp(line, "anim=", 5))       { key = 1; val = line + 5; }
        else if (!strncmp(line, "shell=", 6)) { key = 2; val = line + 6; }
        else if (!strncmp(line, "font=", 5))  { key = 3; val = line + 5; }
        if (!val) continue;
        int n = (int)strlen(val);
        while (n > 0 && (val[n-1] == '\n' || val[n-1] == '\r' ||
                         val[n-1] == ' ' || val[n-1] == '\t')) val[--n] = 0;
        if (n <= 0) continue;
        if (key == 1) {
            if (anim_pid > 0) { kill(anim_pid, SIGTERM); waitpid(anim_pid, NULL, 0); anim_pid = -1; }
            pid_t ap = fork();
            if (ap == 0) { execl(val, val, (char *)NULL); _exit(127); }
            anim_pid = (ap > 0) ? ap : -1;
            fprintf(stderr, "hub75d: config anim -> %s", val);
        } else if (key == 2) {
            snprintf(cfg_shell, sizeof(cfg_shell), "%s", val);
        } else if (key == 3) {
            if (!strcmp(val, "8x8")) {
                g_font = (const uint8_t *)hub75_font8x8;
                g_char_h = 8;
            } else {
                g_font = (const uint8_t *)hub75_font8x16;
                g_char_h = 16;
            }
            g_rows = PANEL_H / g_char_h;
            g_cols = PANEL_W / CHAR_W;
            fprintf(stderr, "hub75d: font %s -> %dx%d", val, g_cols, g_rows);
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
        enter_console();
        fprintf(stderr, "hub75d: console mode");
    } else if (!strncmp(p, "text ", 5)) {
        const char *t = p + 5;
        int r = 0, c = 0;
        text_clear();
        while (*t && r < g_rows) {
            if (*t == '\n') { r++; c = 0; }
            else { if (c < g_cols) text[r][c] = *t; c++; }
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

static int write_file(const char *path, const char *val)
{
    int fd = open(path, O_WRONLY);
    if (fd < 0) return -1;
    int n = (int)write(fd, val, strlen(val));
    close(fd);
    return n;
}

/*
 * Cold-boot workaround: the first ULPI access can race the USB3320 clock
 * after power-on.  The controller then latches ULPI_RUN and the phy driver
 * probe times out (-110), so no USB device ever enumerates.  If the host
 * bus is missing, reset the controller and rebind the glue driver once.
 */
static void usb_recover(void)
{
    if (access("/sys/bus/usb/devices/usb1", F_OK) == 0) return;

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd >= 0) {
        void *base = mmap(NULL, 4096, PROT_READ | PROT_WRITE,
                          MAP_SHARED, fd, 0xE0002000UL);
        if (base != MAP_FAILED) {
            volatile uint32_t *usbcmd = (volatile uint32_t *)((char *)base + 0x140);
            *usbcmd = (*usbcmd & ~2u) | 2u;     /* USBCMD.RST */
            uint64_t t0 = ticks();
            while ((*usbcmd & 2u) && (ticks() - t0) < 50ULL * TICKS_PER_MS)
                ;
            fprintf(stderr, "hub75d: usb recover, USBCMD=%08x", *usbcmd);
            munmap(base, 4096);
        }
        close(fd);
    }

    write_file("/sys/bus/platform/drivers/chipidea-usb2/unbind", "e0002000.usb");
    sleep_ms(20);
    write_file("/sys/bus/platform/drivers/chipidea-usb2/bind", "e0002000.usb");
    sleep_ms(400);
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

    load_config();
    signal(SIGHUP, on_hup);
    const char *shell = argc > 1 ? argv[1] : (cfg_shell[0] ? cfg_shell : "/bin/sh");

    int mfd, sfd;
    struct winsize ws = { .ws_row = g_rows, .ws_col = g_cols, .ws_xpixel = 0, .ws_ypixel = 0 };
    if (openpty(&mfd, &sfd, NULL, NULL, &ws) < 0) { perror("openpty"); return 1; }
    kbd_mfd = mfd;

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
    text_line(0, "HUB75D READY");
    text_line(1, "PTY CONSOLE");
    if (g_rows > 2) text_line(2, "ABCDEFGHIJKLMNOP");
    if (g_rows > 3) text_line(3, "abcdefghijklmnop");

    setup_cmd_fifo();
    usb_recover();
    kbd_scan();
    unsigned fb = 0;
    uint64_t last_submit = 0;
    g_dirty = 1;
    unsigned char buf[256];

    for (;;) {
        struct pollfd pf[3 + MAX_KBD];
        int kn = kbd_count;
        if (reload_req) {
            int old_h = g_char_h;
            reload_req = 0;
            load_config();
            if (g_char_h != old_h) {
                struct winsize ws2 = { .ws_row = g_rows, .ws_col = g_cols,
                                       .ws_xpixel = 0, .ws_ypixel = 0 };
                ioctl(mfd, TIOCSWINSZ, &ws2);
                text_clear();
                g_dirty = 1;
                fprintf(stderr, "hub75d: font reload -> %dx%d", g_cols, g_rows);
            }
        }
        pf[0].fd = mfd;    pf[0].events = POLLIN;  pf[0].revents = 0;
        pf[1].fd = 0;      pf[1].events = POLLIN;  pf[1].revents = 0;
        pf[2].fd = cmd_fd; pf[2].events = POLLIN;  pf[2].revents = 0;
        for (int k = 0; k < kn; k++) {
            pf[3 + k].fd = kbd_fds[k];
            pf[3 + k].events = POLLIN;
            pf[3 + k].revents = 0;
        }
        int r = poll(pf, (nfds_t)(3 + kn), 20);
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
        for (int k = kn - 1; k >= 0; k--) {
            if (r > 0 && k < kbd_count && (pf[3 + k].revents & POLLIN))
                kbd_feed(k);
        }
        {
            static uint64_t last_kbd_scan;
            uint64_t nowk = ticks();
            if (kbd_count == 0 && (nowk - last_kbd_scan) > 2000ULL * TICKS_PER_MS) {
                last_kbd_scan = nowk;
                kbd_scan();
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
