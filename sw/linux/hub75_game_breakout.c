/*
 * hub75_game_breakout - mouse-controlled Arkanoid for the rotating display.
 *
 * The 128x64 game image is replicated on all 64 panel slices (the same 2D
 * trick hub75d uses for its console), so it stays upright and readable from
 * any viewing angle.  The USB mouse drives the paddle through REL_X; the
 * left button serves the ball / restarts.  Any keyboard key makes hub75d
 * kill the game and return to the shell console, as with other animations.
 *
 * The evdev record is the 4.14 kernel's 16-byte layout (32-bit timeval);
 * the Vitis static glibc struct input_event is 24 bytes, so the records are
 * parsed by hand (same approach as hub75d's keyboard code).
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

static float cfg_sens = 0.12f;
static float cfg_speed = 55.0f;

/* mouse */
static int mouse_fd = -1;
static float mouse_accum;
static int click_pending;
static unsigned char mouse_acc[16];
static int mouse_acc_n;

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

/* ---------------- mouse ---------------- */

static int open_mouse(void)
{
    char path[40];
    unsigned long bits[8];
    unsigned long kbits[32];

    for (int i = 0; i < 32; i++) {
        int fd;
        snprintf(path, sizeof(path), "/dev/input/event%d", i);
        fd = open(path, O_RDONLY | O_NONBLOCK);
        if (fd < 0) continue;

        memset(bits, 0, sizeof(bits));
        if (ioctl(fd, EVIOCGBIT(0, sizeof(bits)), bits) < 0 ||
            !(bits[0] & (1UL << EV_REL))) {
            close(fd);
            continue;
        }
        memset(bits, 0, sizeof(bits));
        if (ioctl(fd, EVIOCGBIT(EV_REL, sizeof(bits)), bits) < 0 ||
            !(bits[REL_X / (8 * (int)sizeof(unsigned long))] &
              (1UL << (REL_X % (8 * (int)sizeof(unsigned long)))))) {
            close(fd);
            continue;
        }
        memset(kbits, 0, sizeof(kbits));
        if (ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(kbits)), kbits) < 0 ||
            !(kbits[BTN_LEFT / (8 * (int)sizeof(unsigned long))] &
              (1UL << (BTN_LEFT % (8 * (int)sizeof(unsigned long)))))) {
            close(fd);
            continue;
        }
        fprintf(stderr, "breakout: mouse %s", path);
        return fd;
    }
    return -1;
}

static void handle_record(const unsigned char *p)
{
    uint16_t type, code;
    int32_t value;

    memcpy(&type, p + 8, 2);
    memcpy(&code, p + 10, 2);
    memcpy(&value, p + 12, 4);
    if (type == EV_REL && code == REL_X)
        mouse_accum += (float)value * cfg_sens;
    else if (type == EV_KEY && code == BTN_LEFT && value == 1)
        click_pending = 1;
}

static void poll_mouse(void)
{
    unsigned char buf[16 * 64];

    if (mouse_fd < 0) return;
    for (;;) {
        ssize_t n = read(mouse_fd, buf, sizeof(buf));
        ssize_t off = 0;
        if (n <= 0) break;
        while (off < n) {
            ssize_t take = 16 - mouse_acc_n;
            if (take > n - off) take = n - off;
            memcpy(mouse_acc + mouse_acc_n, buf + off, (size_t)take);
            mouse_acc_n += (int)take;
            off += take;
            if (mouse_acc_n == 16) {
                handle_record(mouse_acc);
                mouse_acc_n = 0;
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
            uint8_t up = canvas[r * W + c] & 7u;
            uint8_t lo = canvas[(r + 32) * W + c] & 7u;
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
        poll_mouse();
        sched_yield();
    }

    dst = frames + (next_buf ? FRAME_SPAN : 0);
    for (int s = 0; s < SLICES; s++)
        memcpy(dst + s * SLICE_BYTES, slice_img, SLICE_BYTES);

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
        poll_mouse();
        if (((statp[0] >> 16) & 0xffu) != id0)
            break;
        sched_yield();
    }
}

/* ---------------- scene ---------------- */

static void draw_scene(void)
{
    memset(canvas, 0, sizeof(canvas));

    /* HUD */
    if (score > 999) score = 999;
    digit3x5(2, 2, score / 100, C_WHITE);
    digit3x5(6, 2, (score / 10) % 10, C_WHITE);
    digit3x5(10, 2, score % 10, C_WHITE);
    for (int i = 0; i < lives; i++)
        rect(W - 6 - i * 8, 2, 5, 2, C_GREEN);
    rect(0, 7, W, 1, C_BLUE);

    /* bricks */
    for (int r = 0; r < BRICK_ROWS; r++)
        for (int c = 0; c < BRICK_COLS; c++)
            if (brick_alive[r][c])
                rect(BRICK_X0 + c * (BRICK_W + BRICK_GAPX),
                     BRICK_Y0 + r * (BRICK_H + BRICK_GAPY),
                     BRICK_W, BRICK_H, brick_colour[r]);

    /* paddle + ball */
    rect((int)paddle_x, PADDLE_Y, PADDLE_W, PADDLE_H, C_WHITE);
    rect((int)(ball_x - BALL_R), (int)(ball_y - BALL_R), 3, 3, C_WHITE);

    if (state == ST_READY)
        text8_center(44, "CLICK TO SERVE", C_WHITE);
    else if (state == ST_OVER || state == ST_WIN) {
        rect(2, 20, W - 4, 28, 0);   /* readable panel over the bricks */
        if (state == ST_OVER) {
            text8_center(24, "GAME OVER", C_RED);
            text8_center(36, "CLICK TO PLAY", C_WHITE);
        } else {
            text8_center(24, "YOU WIN!", C_GREEN);
            text8_center(36, "CLICK TO PLAY", C_WHITE);
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
        if (!strncmp(line, "sens=", 5))
            cfg_sens = (float)atof(line + 5);
        else if (!strncmp(line, "speed=", 6))
            cfg_speed = (float)atof(line + 6);
    }
    fclose(f);
    if (cfg_sens < 0.01f) cfg_sens = 0.01f;
    if (cfg_sens > 1.0f) cfg_sens = 1.0f;
    if (cfg_speed < 20.0f) cfg_speed = 20.0f;
    if (cfg_speed > 90.0f) cfg_speed = 90.0f;
    fprintf(stderr, "breakout: sens=%.2f speed=%.0f", (double)cfg_sens,
            (double)cfg_speed);
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
    mouse_fd = open_mouse();
    if (mouse_fd < 0)
        fprintf(stderr, "breakout: no mouse found (paddle fixed)");

    reset_game();
    last = ticks();

    while (!stop_flag) {
        uint64_t now = ticks();
        float dt = (float)(now - last) / ((float)TICKS_PER_MS * 1000.0f);
        if (dt > 0.15f) dt = 0.15f;
        last = now;

        poll_mouse();
        paddle_x += mouse_accum;
        mouse_accum = 0.0f;
        if (paddle_x < 1.0f) paddle_x = 1.0f;
        if (paddle_x > (float)(W - PADDLE_W - 1)) paddle_x = (float)(W - PADDLE_W - 1);

        if (click_pending) {
            click_pending = 0;
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

    if (mouse_fd >= 0) close(mouse_fd);
    return 0;
}
