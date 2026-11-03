/*
 * hub75_game_breakout - keyboard Arkanoid for the rotating display.
 *
 * The 128x64 playfield is drawn with extruded bricks/paddle/ball (a little
 * visual thickness), then packed as one 6-bit slice image.  Unlike the first
 * version, the frame is not always copied to every slice:
 *
 *   stopped (no accepted IR edge for ir_stop_ms):
 *       all 64 slices carry the image, so the stationary panel is readable
 *       from any angle, like the hub75d console;
 *   rotating (IR edge seen):
 *       only `thickness` slices around `terminal_slice` carry it, forming a
 *       thick panel at the IR angle that stays playable (thickness=1 is the
 *       same one-slice rule the terminal uses).
 *
 * Controls: LEFT/RIGHT or A/D move the paddle, SPACE/ENTER/UP serves and
 * restarts, Q/ESC quits.  The keyboard is grabbed with EVIOCGRAB so the
 * daemon does not treat game keys as "return to console".
 *
 * The evdev record is the 4.14 kernel's 16-byte layout (32-bit timeval);
 * the Vitis static glibc struct input_event is 24 bytes, so the records are
 * parsed by hand (same approach as hub75d and fx_tunnel).
 */
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <linux/input.h>

#include "hub75_frame.h"
#include "hub75_font8x8.h"

#define CTRL_PHYS    0x41200000UL
#define STAT_PHYS    0x41210000UL
#define FRAME_A      0x10000000UL
#define FRAME_B      0x10200000UL
#define FRAME_SPAN   (FRAME_B - FRAME_A)
#define GT_PHYS      0xF8F00000UL
#define TICKS_PER_MS 333333ULL

#define SLICES      HUB75_SLICES
#define SLICE_BYTES HUB75_SLICE_BYTES

#define W 128
#define H 64

/* palette: bit0 blue, bit1 green, bit2 red */
#define C_RED     4u
#define C_GREEN   2u
#define C_BLUE    1u
#define C_YELLOW  6u
#define C_CYAN    3u
#define C_MAGENTA 5u
#define C_WHITE   7u

/* playfield */
#define TOP_WALL_Y   9.0f
#define BRICK_COLS   8
#define BRICK_ROWS   4
#define BRICK_W      14
#define BRICK_H      5
#define BRICK_X0     1
#define BRICK_Y0     12
#define BRICK_GAPX   2
#define BRICK_GAPY   2
#define PADDLE_W     16
#define PADDLE_H     3
#define PADDLE_Y     56
#define BALL_R       1.5f
#define BOTTOM_Y     61.0f

static const uint8_t brick_colour[BRICK_ROWS] = {
    C_RED, C_YELLOW, C_GREEN, C_CYAN
};

/* game states */
enum { ST_READY, ST_PLAY, ST_OVER, ST_WIN };

static volatile uint32_t *ctrl, *statp, *gt;
static uint8_t *frames;
static volatile sig_atomic_t stop_flag;

static uint8_t canvas[W * H];
static uint8_t slice_img[SLICE_BYTES];

static int brick_alive[BRICK_ROWS][BRICK_COLS];
static int bricks_left;
static int score, lives;
static int state;

static float paddle_x;
static float ball_x, ball_y, ball_vx, ball_vy;
static float ball_speed;

static float cfg_paddle_speed = 60.0f;
static float cfg_speed = 55.0f;

/* keyboard */
#define EV_REC_SIZE 16
static int kbd_fd = -1;
static int key_left, key_right;
static int serve_pending;
static unsigned char key_acc[EV_REC_SIZE];
static int key_acc_n;
static uint64_t last_kbd_scan;

/* IR / rotating display mode */
static int g_rotating;
static int g_terminal_slice = 0;
static int g_thickness = 3;
static int g_ir_stop_ms = 5000;

static uint64_t ticks(void)
{
    uint32_t hi, lo, hi2;
    do { hi = gt[0x204 / 4]; lo = gt[0x200 / 4]; hi2 = gt[0x204 / 4]; }
    while (hi != hi2);
    return ((uint64_t)hi << 32) | lo;
}

static void sleep_ms(unsigned ms)
{
    uint64_t t0 = ticks();
    while ((ticks() - t0) < (uint64_t)ms * TICKS_PER_MS)
        ;
}

static void on_term(int sig)
{
    (void)sig;
    stop_flag = 1;
}

/* ---------------- drawing ---------------- */

static void px(int x, int y, uint8_t c)
{
    if (x >= 0 && x < W && y >= 0 && y < H)
        canvas[y * W + x] = c;
}

static void rect(int x, int y, int w, int h, uint8_t c)
{
    for (int j = 0; j < h; j++)
        for (int i = 0; i < w; i++)
            px(x + i, y + j, c);
}

static uint8_t dim3(uint8_t c) { return (uint8_t)((c >> 1) | (c & 1u)); }
static uint8_t hi3(uint8_t c)  { return (uint8_t)(c | 1u); }

/* A 2D rectangle with a one-pixel top highlight and bottom/right side, so it
 * reads as a slightly extruded object on the swept display. */
static void rect3d(int x, int y, int w, int h, uint8_t c)
{
    rect(x, y, w, h, c);
    rect(x, y, w, 1, hi3(c));
    rect(x, y + h, w, 1, dim3(c));
    rect(x + w, y, 1, h, dim3(c));
}

/* 3x5 score digits */
static void digit3x5(int x, int y, int d, uint8_t c)
{
    static const uint8_t g[10][5] = {
        {7,5,5,5,7}, {2,6,2,2,7}, {7,1,7,4,7}, {7,1,7,1,7}, {5,5,7,1,1},
        {7,4,7,1,7}, {7,4,7,5,7}, {7,1,1,1,1}, {7,5,7,5,7}, {7,5,7,1,7}
    };
    if (d < 0 || d > 9) return;
    for (int r = 0; r < 5; r++)
        for (int b = 0; b < 3; b++)
            if (g[d][r] & (4 >> b))
                px(x + b, y + r, c);
}

static void text8(int x, int y, const char *s, uint8_t c)
{
    for (; *s; s++, x += 8) {
        int idx = (unsigned char)*s - 32;
        if (idx < 0 || idx > 94) continue;
        for (int r = 0; r < 8; r++) {
            uint8_t bits = hub75_font8x8[idx][r];
            for (int b = 0; b < 8; b++)
                if (bits & (0x80u >> b))
                    px(x + b, y + r, c);
        }
    }
}

static void text8_center(int y, const char *s, uint8_t c)
{
    int len = (int)strlen(s);
    text8((W - 8 * len) / 2, y, s, c);
}

/* ---------------- game logic ---------------- */

static void normalize_speed(void)
{
    float s2 = ball_vx * ball_vx + ball_vy * ball_vy;
    float s;
    if (s2 < 1.0f) {
        ball_vx = 0.0f;
        ball_vy = -ball_speed;
        return;
    }
    s = sqrtf(s2);
    ball_vx = ball_vx / s * ball_speed;
    ball_vy = ball_vy / s * ball_speed;
}

static void reset_game(void)
{
    score = 0;
    lives = 3;
    bricks_left = BRICK_ROWS * BRICK_COLS;
    memset(brick_alive, 1, sizeof(brick_alive));
    paddle_x = (float)(W - PADDLE_W) * 0.5f;
    ball_speed = cfg_speed;
    ball_x = paddle_x + PADDLE_W * 0.5f;
    ball_y = (float)PADDLE_Y - 2.0f;
    ball_vx = 0.0f;
    ball_vy = 0.0f;
    state = ST_READY;
}

static void launch_ball(void)
{
    uint32_t r = (uint32_t)(ticks() >> 12);
    float a = ((float)(r % 100u) / 100.0f - 0.5f) * 0.9f;
    ball_vx = ball_speed * sinf(a);
    ball_vy = -ball_speed * cosf(a);
    state = ST_PLAY;
}

static void update_physics(float dt)
{
    int steps;
    float sdt;

    if (state == ST_READY) {
        ball_x = paddle_x + PADDLE_W * 0.5f;
        ball_y = (float)PADDLE_Y - 2.0f;
        return;
    }
    if (state != ST_PLAY)
        return;

    steps = (int)(ball_speed * dt / 0.5f) + 1;
    if (steps > 400) steps = 400;
    sdt = dt / (float)steps;

    for (int i = 0; i < steps && state == ST_PLAY; i++) {
        ball_x += ball_vx * sdt;
        ball_y += ball_vy * sdt;

        if (ball_x < 2.0f) {
            ball_x = 2.0f;
            ball_vx = fabsf(ball_vx);
        }
        if (ball_x > (float)W - 3.0f) {
            ball_x = (float)W - 3.0f;
            ball_vx = -fabsf(ball_vx);
        }
        if (ball_y < TOP_WALL_Y) {
            ball_y = TOP_WALL_Y;
            ball_vy = fabsf(ball_vy);
        }

        /* paddle */
        if (ball_vy > 0.0f &&
            ball_y >= (float)PADDLE_Y - BALL_R &&
            ball_y <= (float)PADDLE_Y + (float)PADDLE_H &&
            ball_x >= paddle_x - BALL_R &&
            ball_x <= paddle_x + (float)PADDLE_W + BALL_R) {
            float off;
            ball_y = (float)PADDLE_Y - BALL_R - 0.1f;
            off = (ball_x - (paddle_x + (float)PADDLE_W * 0.5f)) /
                  ((float)PADDLE_W * 0.5f);
            if (off < -1.0f) off = -1.0f;
            if (off > 1.0f) off = 1.0f;
            ball_vx += off * 30.0f;
            ball_vy = -fabsf(ball_vy);
            normalize_speed();
        }

        /* bricks */
        for (int r = 0; r < BRICK_ROWS && state == ST_PLAY; r++) {
            for (int c = 0; c < BRICK_COLS; c++) {
                float x0, y0, x1, y1, left, right, top, bot, m;
                int axis;
                if (!brick_alive[r][c]) continue;
                x0 = (float)(BRICK_X0 + c * (BRICK_W + BRICK_GAPX));
                y0 = (float)(BRICK_Y0 + r * (BRICK_H + BRICK_GAPY));
                x1 = x0 + (float)BRICK_W;
                y1 = y0 + (float)BRICK_H;
                if (ball_x + BALL_R <= x0 || ball_x - BALL_R >= x1 ||
                    ball_y + BALL_R <= y0 || ball_y - BALL_R >= y1)
                    continue;

                left  = ball_x + BALL_R - x0;
                right = x1 - (ball_x - BALL_R);
                top   = ball_y + BALL_R - y0;
                bot   = y1 - (ball_y - BALL_R);
                m = left;
                axis = 0;
                if (right < m) { m = right; axis = 0; }
                if (top < m)   { m = top;   axis = 1; }
                if (bot < m)   { m = bot;   axis = 1; }

                if (axis == 0) {
                    ball_vx = -ball_vx;
                    ball_x = (left < right) ? x0 - BALL_R : x1 + BALL_R;
                } else {
                    ball_vy = -ball_vy;
                    ball_y = (top < bot) ? y0 - BALL_R : y1 + BALL_R;
                }
                brick_alive[r][c] = 0;
                bricks_left--;
                score += 10;
                if (ball_speed < 80.0f) ball_speed += 0.6f;
                normalize_speed();
                if (bricks_left == 0)
                    state = ST_WIN;
                break; /* one brick per substep */
            }
        }

        if (state == ST_PLAY && ball_y > BOTTOM_Y) {
            lives--;
            ball_vx = ball_vy = 0.0f;
            ball_speed = cfg_speed;
            if (lives <= 0)
                state = ST_OVER;
            else
                state = ST_READY;
            break;
        }
    }
}

/* ---------------- keyboard ---------------- */

static int open_keyboard(void)
{
    char path[40];
    unsigned long bits[8];

    for (int i = 0; i < 32; i++) {
        int fd;
        snprintf(path, sizeof(path), "/dev/input/event%d", i);
        fd = open(path, O_RDONLY | O_NONBLOCK);
        if (fd < 0) continue;

        memset(bits, 0, sizeof(bits));
        if (ioctl(fd, EVIOCGBIT(0, sizeof(bits)), bits) < 0 ||
            !(bits[0] & (1UL << EV_KEY))) {
            close(fd);
            continue;
        }
        memset(bits, 0, sizeof(bits));
        if (ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(bits)), bits) < 0 ||
            !(bits[KEY_A / (8 * (int)sizeof(unsigned long))] &
              (1UL << (KEY_A % (8 * (int)sizeof(unsigned long)))))) {
            close(fd);
            continue;
        }
        if (ioctl(fd, EVIOCGRAB, 1) < 0)
            fprintf(stderr, "breakout: EVIOCGRAB failed");
        fprintf(stderr, "breakout: keyboard %s", path);
        return fd;
    }
    return -1;
}

static void handle_key(const unsigned char *p)
{
    uint16_t type, code;
    int32_t value;

    memcpy(&type, p + 8, 2);
    memcpy(&code, p + 10, 2);
    memcpy(&value, p + 12, 4);
    if (type != EV_KEY) return;

    switch (code) {
    case KEY_LEFT:
    case KEY_A:
        key_left = (value != 0);
        break;
    case KEY_RIGHT:
    case KEY_D:
        key_right = (value != 0);
        break;
    case KEY_SPACE:
    case KEY_ENTER:
    case KEY_KPENTER:
    case KEY_UP:
        if (value == 1) serve_pending = 1;
        break;
    case KEY_ESC:
    case KEY_Q:
        if (value == 1) stop_flag = 1;
        break;
    }
}

static void poll_input(void)
{
    unsigned char buf[EV_REC_SIZE * 64];

    if (kbd_fd < 0) {
        uint64_t now = ticks();
        if ((now - last_kbd_scan) < 1000ULL * TICKS_PER_MS) return;
        last_kbd_scan = now;
        kbd_fd = open_keyboard();
        if (kbd_fd < 0) return;
    }
    for (;;) {
        ssize_t n = read(kbd_fd, buf, sizeof(buf));
        ssize_t off = 0;
        if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
            close(kbd_fd);
            kbd_fd = -1;
            return;
        }
        if (n <= 0) break;
        while (off < n) {
            ssize_t take = EV_REC_SIZE - key_acc_n;
            if (take > n - off) take = n - off;
            memcpy(key_acc + key_acc_n, buf + off, (size_t)take);
            key_acc_n += (int)take;
            off += take;
            if (key_acc_n == EV_REC_SIZE) {
                handle_key(key_acc);
                key_acc_n = 0;
            }
        }
    }
}

/* ---------------- frame submit ---------------- */

static void pack_slice(void)
{
    memset(slice_img, 0, sizeof(slice_img));
    for (int r = 0; r < 32; r++) {
        for (int c = 0; c < W; c++) {
            /* The panel shifts column 127 out first, so the logical image
             * must be mirrored into the packed slice (same correction as
             * hub75d's console renderer). */
            int x = W - 1 - c;
            uint8_t up = canvas[r * W + x] & 7u;
            uint8_t lo = canvas[(r + 32) * W + x] & 7u;
            uint8_t word = (uint8_t)(up | (lo << 3));
            uint32_t bit = (uint32_t)(r * W + c) * 6u;
            uint32_t byte = bit >> 3;
            uint32_t off = bit & 7u;
            uint16_t sh = (uint16_t)word << off;
            slice_img[byte] |= (uint8_t)(sh & 0xFFu);
            if (off > 2u)
                slice_img[byte + 1] |= (uint8_t)(sh >> 8);
        }
    }
}

static int next_buf;

static void submit_frame(void)
{
    uint8_t *dst;
    uint32_t id0;
    uint64_t t0;

    /* Do not overwrite a buffer while the previous submit is still pending. */
    t0 = ticks();
    while (!stop_flag && ((statp[0] >> 5) & 1u) &&
           (ticks() - t0) < 400ULL * TICKS_PER_MS) {
        poll_input();
        sched_yield();
    }

    dst = frames + (next_buf ? FRAME_SPAN : 0);
    if (g_rotating) {
        /* A thick panel at the IR angle instead of a 360-degree smear.
         * thickness=1 is exactly the terminal's one-slice rule. */
        int half = g_thickness / 2;
        memset(dst, 0, HUB75_FRAME_BYTES);
        for (int i = 0; i < g_thickness; i++) {
            int s = g_terminal_slice + i - half;
            s %= SLICES;
            if (s < 0) s += SLICES;
            memcpy(dst + s * SLICE_BYTES, slice_img, SLICE_BYTES);
        }
    } else {
        for (int s = 0; s < SLICES; s++)
            memcpy(dst + s * SLICE_BYTES, slice_img, SLICE_BYTES);
    }

    ctrl[0] = next_buf ? FRAME_B : FRAME_A;
    __sync_synchronize();
    (void)ctrl[0];
    sleep_ms(2);
    ctrl[2] = ((ctrl[2] ^ 1u) & 1u) | 2u;
    __sync_synchronize();
    sleep_ms(1);
    if (!((statp[0] >> 5) & 1u)) {
        ctrl[2] = ((ctrl[2] ^ 1u) & 1u) | 2u;
        __sync_synchronize();
    }
    next_buf ^= 1;

    id0 = (statp[0] >> 16) & 0xffu;
    t0 = ticks();
    while (!stop_flag && (ticks() - t0) < 150ULL * TICKS_PER_MS) {
        poll_input();
        if (((statp[0] >> 16) & 0xffu) != id0)
            break;
        sched_yield();
    }
}

/* ---------------- scene ---------------- */

static void draw_scene(void)
{
    memset(canvas, 0, sizeof(canvas));

    /* HUD with a small drop shadow */
    if (score > 999) score = 999;
    digit3x5(3, 3, score / 100, dim3(C_WHITE));
    digit3x5(7, 3, (score / 10) % 10, dim3(C_WHITE));
    digit3x5(11, 3, score % 10, dim3(C_WHITE));
    digit3x5(2, 2, score / 100, C_WHITE);
    digit3x5(6, 2, (score / 10) % 10, C_WHITE);
    digit3x5(10, 2, score % 10, C_WHITE);
    for (int i = 0; i < lives; i++) {
        rect(W - 6 - i * 8, 3, 5, 2, dim3(C_GREEN));
        rect(W - 7 - i * 8, 2, 5, 2, C_GREEN);
    }

    /* Playfield walls with visible sides give the panel some depth. */
    rect3d(0, 7, W, 1, C_BLUE);
    rect(0, 9, 1, H - 9, dim3(C_BLUE));
    rect(W - 1, 9, 1, H - 9, dim3(C_BLUE));
    rect(1, H - 1, W - 2, 1, dim3(C_BLUE));

    /* bricks: extruded blocks */
    for (int r = 0; r < BRICK_ROWS; r++)
        for (int c = 0; c < BRICK_COLS; c++)
            if (brick_alive[r][c])
                rect3d(BRICK_X0 + c * (BRICK_W + BRICK_GAPX),
                       BRICK_Y0 + r * (BRICK_H + BRICK_GAPY),
                       BRICK_W, BRICK_H, brick_colour[r]);

    /* paddle: a thick bar; ball: shadow + lit block */
    rect3d((int)paddle_x, PADDLE_Y, PADDLE_W, PADDLE_H, C_WHITE);
    {
        int bx = (int)(ball_x - BALL_R);
        int by = (int)(ball_y - BALL_R);
        rect(bx + 1, by + 1, 3, 3, dim3(C_WHITE));
        rect(bx, by, 3, 3, C_WHITE);
    }

    if (state == ST_READY) {
        text8_center(45, "SPACE TO SERVE", dim3(C_WHITE));
        text8_center(44, "SPACE TO SERVE", C_WHITE);
    } else if (state == ST_OVER || state == ST_WIN) {
        rect(2, 20, W - 4, 28, 0);   /* readable panel over the bricks */
        if (state == ST_OVER) {
            text8_center(25, "GAME OVER", dim3(C_RED));
            text8_center(24, "GAME OVER", C_RED);
            text8_center(37, "PRESS SPACE", dim3(C_WHITE));
            text8_center(36, "PRESS SPACE", C_WHITE);
        } else {
            text8_center(25, "YOU WIN!", dim3(C_GREEN));
            text8_center(24, "YOU WIN!", C_GREEN);
            text8_center(37, "PRESS SPACE", dim3(C_WHITE));
            text8_center(36, "PRESS SPACE", C_WHITE);
        }
    }
}

/* ---------------- config ---------------- */

static void load_config(void)
{
    static const char *paths[] = {
        "/run/media/mmcblk0p1/breakout.conf",
        "/etc/breakout.conf",
    };
    FILE *f = NULL;
    char line[120];

    for (int i = 0; i < 2 && !f; i++)
        f = fopen(paths[i], "r");
    if (!f) return;
    while (fgets(line, sizeof(line), f)) {
        if (!strncmp(line, "paddle_speed=", 13))
            cfg_paddle_speed = (float)atof(line + 13);
        else if (!strncmp(line, "speed=", 6))
            cfg_speed = (float)atof(line + 6);
        else if (!strncmp(line, "terminal_slice=", 15))
            g_terminal_slice = atoi(line + 15);
        else if (!strncmp(line, "thickness=", 10))
            g_thickness = atoi(line + 10);
        else if (!strncmp(line, "ir_stop_ms=", 11))
            g_ir_stop_ms = atoi(line + 11);
    }
    fclose(f);
    if (cfg_paddle_speed < 10.0f) cfg_paddle_speed = 10.0f;
    if (cfg_paddle_speed > 200.0f) cfg_paddle_speed = 200.0f;
    if (cfg_speed < 20.0f) cfg_speed = 20.0f;
    if (cfg_speed > 90.0f) cfg_speed = 90.0f;
    if (g_terminal_slice < 0) g_terminal_slice = 0;
    if (g_terminal_slice >= SLICES) g_terminal_slice = SLICES - 1;
    if (g_thickness < 1) g_thickness = 1;
    if (g_thickness > 9) g_thickness = 9;
    if (g_ir_stop_ms < 500) g_ir_stop_ms = 500;
    if (g_ir_stop_ms > 60000) g_ir_stop_ms = 60000;
    fprintf(stderr,
            "breakout: paddle=%.0f speed=%.0f slice=%d thick=%d ir_stop=%d",
            (double)cfg_paddle_speed, (double)cfg_speed, g_terminal_slice,
            g_thickness, g_ir_stop_ms);
}

/* ---------------- main ---------------- */

int main(void)
{
    int fd;
    uint64_t last;

    signal(SIGTERM, on_term);
    signal(SIGINT, on_term);

    fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); return 1; }
    ctrl = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, CTRL_PHYS);
    statp = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, STAT_PHYS);
    gt = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, GT_PHYS);
    frames = mmap(NULL, FRAME_SPAN + HUB75_FRAME_BYTES, PROT_READ | PROT_WRITE,
                  MAP_SHARED, fd, FRAME_A);
    if (ctrl == MAP_FAILED || statp == MAP_FAILED || gt == MAP_FAILED ||
        frames == MAP_FAILED) {
        perror("mmap");
        return 1;
    }
    ctrl[1] = 0;
    ctrl[3] = 0;
    __sync_synchronize();

    load_config();
    last_kbd_scan = ticks();
    kbd_fd = open_keyboard();
    if (kbd_fd < 0)
        fprintf(stderr, "breakout: no keyboard yet (paddle fixed)");

    reset_game();
    last = ticks();

    while (!stop_flag) {
        uint64_t now = ticks();
        float dt = (float)(now - last) / ((float)TICKS_PER_MS * 1000.0f);
        if (dt > 0.15f) dt = 0.15f;
        last = now;

        poll_input();

        /* IR activity selects the display mode: all slices when stopped,
         * a thick panel around terminal_slice when rotating. */
        {
            static uint64_t last_ir_seen;
            static int ir_seen;
            uint32_t st = statp[0];
            if (st & (1u << 4)) { last_ir_seen = now; ir_seen = 1; }
            int rotating = ir_seen &&
                ((now - last_ir_seen) < (uint64_t)g_ir_stop_ms * TICKS_PER_MS);
            if (rotating != g_rotating) {
                g_rotating = rotating;
                fprintf(stderr, "breakout: ir %s",
                        rotating ? "rotating" : "stopped");
            }
        }

        {
            int dir = key_right - key_left;
            if (dir)
                paddle_x += (float)dir * cfg_paddle_speed * dt;
        }
        if (paddle_x < 1.0f) paddle_x = 1.0f;
        if (paddle_x > (float)(W - PADDLE_W - 1)) paddle_x = (float)(W - PADDLE_W - 1);

        if (serve_pending) {
            serve_pending = 0;
            if (state == ST_READY)
                launch_ball();
            else if (state == ST_OVER || state == ST_WIN)
                reset_game();
        }

        update_physics(dt);
        draw_scene();
        pack_slice();
        submit_frame();
    }

    if (kbd_fd >= 0) close(kbd_fd);
    return 0;
}
