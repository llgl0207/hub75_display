/*
 * fx_tunnel - mouse-controlled 3D tunnel racer.
 *
 * The player ship orbits the inside of a cylindrical tunnel (radius 42,
 * player z = -20).  Walls with a missing arc (a gap) descend toward the
 * ship; the mouse rotates the ship around the tunnel so it passes through
 * each gap.  A dotted aim line and the next wall's colour (white = aligned,
 * red = blocked) make the 3D alignment readable on the swept volume.
 *
 * Mouse: REL_X rotates the ship, BTN_LEFT starts / restarts.
 * The score and lives are a 2D overlay ORed into every slice (fx_overlay),
 * so they appear as a stable HUD while the tunnel itself is true 3D.
 */
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <linux/input.h>

#include "hub75_fx_common.h"

#define TUN_R        42.0f
#define PLAYER_Z     (-20.0f)
#define NUM_GATES    5
#define GATE_SPACING 15.0f
#define GATE_THICK   1.2f
#define START_SPEED  6.0f
#define MAX_SPEED    16.0f
#define GAP_START    2.0f
#define GAP_MIN      0.85f
#define SHIP_HALF    0.10f
#define MAX_LIVES    3
#define EV_REC_SIZE  16

enum { ST_READY, ST_PLAY, ST_OVER };

static int inited;
static int kbd_fd = -1;
static float cfg_turn = 2.5f;
static int turn_left, turn_right;
static int start_pending, quit_pending;
static unsigned char key_acc[EV_REC_SIZE];
static int key_acc_n;
static uint64_t last_scan_ms;

static float theta_p;
static float gate_z[NUM_GATES];
static float gate_gap[NUM_GATES];
static int gate_hit[NUM_GATES];
static int gate_passed[NUM_GATES];
static int score;
static int lives;
static int g_state;
static float invuln_until;
static float flash_until;
static float last_ms_f;
static uint32_t rng = 0x2545f491u;

static float ang_diff(float a, float b)
{
    float d = a - b;
    while (d > 3.14159265f) d -= 6.2831853f;
    while (d < -3.14159265f) d += 6.2831853f;
    return d;
}

static float gap_half(void)
{
    float w = GAP_START - (float)score * 0.02f;
    if (w < GAP_MIN) w = GAP_MIN;
    return w * 0.5f;
}

/* ---------------- mouse ---------------- */

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
            fprintf(stderr, "tunnel: EVIOCGRAB failed");
        fprintf(stderr, "tunnel: keyboard %s", path);
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
        turn_left = (value != 0);
        break;
    case KEY_RIGHT:
    case KEY_D:
        turn_right = (value != 0);
        break;
    case KEY_SPACE:
    case KEY_ENTER:
    case KEY_KPENTER:
        if (value == 1) start_pending = 1;
        break;
    case KEY_ESC:
    case KEY_Q:
        if (value == 1) quit_pending = 1;
        break;
    default:
        break;
    }
}

static void poll_keyboard(void)
{
    unsigned char buf[EV_REC_SIZE * 64];

    if (kbd_fd < 0) return;
    for (;;) {
        ssize_t n = read(kbd_fd, buf, sizeof(buf));
        ssize_t off = 0;
        if (n < 0 && errno != EAGAIN && errno != EINTR) {
            close(kbd_fd);
            kbd_fd = -1;
            key_acc_n = 0;
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

/* ---------------- 3D HUD (voxels, no 2D overlay) ---------------- */

static void hud_box(int x, int iy, int gz, int w, int depth, int h,
                    uint8_t colour)
{
    for (int z = gz; z < gz + h; z++) {
        if (z < 0 || z >= 64) continue;
        for (int y = iy; y < iy + depth; y++) {
            if (y < 0 || y >= 128) continue;
            for (int x2 = x; x2 < x + w; x2++) {
                if (x2 < 0 || x2 >= 128) continue;
                fx_grid[x2][y][z] = colour;
            }
        }
    }
}

/* 7-segment digit: 16 wide, 27 tall, 4 voxels deep, facing world -y. */
static void hud_digit7(int d, int x0, int gz0, uint8_t colour)
{
    static const uint8_t seg[10] = {
        63, 6, 91, 79, 102, 109, 125, 7, 127, 111
    };
    uint8_t s;
    if (d < 0 || d > 9) return;
    s = seg[d];
    if (s & 1)  hud_box(x0 + 4, 50, gz0 + 0,  8, 4, 3, colour);
    if (s & 2)  hud_box(x0 + 13, 50, gz0 + 3, 3, 4, 10, colour);
    if (s & 4)  hud_box(x0 + 13, 50, gz0 + 15, 3, 4, 10, colour);
    if (s & 8)  hud_box(x0 + 4, 50, gz0 + 24, 8, 4, 3, colour);
    if (s & 16) hud_box(x0 + 0, 50, gz0 + 15, 3, 4, 10, colour);
    if (s & 32) hud_box(x0 + 0, 50, gz0 + 3,  3, 4, 10, colour);
    if (s & 64) hud_box(x0 + 4, 50, gz0 + 12, 8, 4, 3, colour);
}

static void draw_hud3d(float t)
{
    uint8_t dc = (g_state == ST_OVER || t < flash_until) ? FX_RED : FX_WHITE;
    int s = score > 99 ? 99 : score;

    hud_digit7(s / 10, 44, 2, dc);
    hud_digit7(s % 10, 66, 2, dc);

    for (int i = 0; i < lives; i++)
        fx_splat((float)(52 + i * 12 - 64), 0.0f, 31.5f - 44.0f,
                 FX_GREEN, 2);

    if (g_state == ST_READY) {
        uint8_t c = ((int)(t * 4.0f) & 1) ? FX_GREEN : FX_CYAN;
        for (int i = 0; i < 8; i++) {
            int w = 16 - i * 2;
            hud_box(64 - w / 2, 60, 36 - i * 2, w, 3, 2, c);
        }
    } else if (g_state == ST_OVER) {
        for (int i = 0; i < 14; i++) {
            hud_box(52 + i, 56, 32 + i, 2, 3, 2, FX_RED);
            hud_box(70 - i, 56, 32 + i, 2, 3, 2, FX_RED);
        }
    }
}

/* ---------------- game ---------------- */

static void game_reset(void)
{
    theta_p = 0.0f;
    score = 0;
    lives = MAX_LIVES;
    invuln_until = 0.0f;
    flash_until = 0.0f;
    for (int i = 0; i < NUM_GATES; i++) {
        gate_z[i] = 28.0f - (float)i * GATE_SPACING;
        /* gates still at/above the ship start aligned; only gates already
         * below the ship get a random gap (they will recycle soon) */
        gate_gap[i] = (gate_z[i] > PLAYER_Z - 3.0f)
                          ? 0.0f : 6.2831853f * fx_randf(&rng);
        gate_hit[i] = 0;
        gate_passed[i] = (gate_z[i] < PLAYER_Z - 3.0f) ? 1 : 0;
    }
    g_state = ST_READY;
    last_ms_f = 0.0f;
}

static void load_config(void)
{
    FILE *f = fopen("/run/media/mmcblk0p1/tunnel.conf", "r");
    char line[100];
    if (!f) return;
    while (fgets(line, sizeof(line), f)) {
        if (!strncmp(line, "turn=", 5))
            cfg_turn = (float)atof(line + 5);
    }
    fclose(f);
    if (cfg_turn < 0.5f) cfg_turn = 0.5f;
    if (cfg_turn > 8.0f) cfg_turn = 8.0f;
}

static void game_init(void)
{
    load_config();
    game_reset();
    kbd_fd = open_keyboard();
    if (kbd_fd < 0)
        fprintf(stderr, "tunnel: no keyboard yet");
    inited = 1;
}

static void draw_scene(float t)
{
    /* floor and ceiling rings */
    for (int j = 0; j < 128; j++) {
        float a = 6.2831853f * (float)j / 128.0f;
        float x = TUN_R * cosf(a);
        float y = TUN_R * sinf(a);
        fx_splat(x, y, -30.0f, FX_BLUE, 0);
        fx_splat(x, y, 31.0f, FX_CYAN, 0);
    }

    /* find the next gate above the ship for the alignment hint */
    {
        int nearest = -1;
        float best = 1e9f;
        for (int i = 0; i < NUM_GATES; i++) {
            float dz = gate_z[i] - PLAYER_Z;
            if (dz > -3.0f && dz < best) { best = dz; nearest = i; }
        }
        for (int i = 0; i < NUM_GATES; i++) {
            float half = gap_half();
            int blocked = 0;
            uint8_t wall_col = FX_CYAN;
            if (i == nearest) {
                float d = ang_diff(theta_p, gate_gap[i]);
                blocked = fabsf(d) > half - SHIP_HALF;
                wall_col = blocked ? FX_RED : FX_WHITE;
            }
            for (int j = 0; j < 180; j++) {
                float a = 6.2831853f * (float)j / 180.0f;
                float d = ang_diff(a, gate_gap[i]);
                float x, y;
                if (fabsf(d) <= half) continue;
                x = TUN_R * cosf(a);
                y = TUN_R * sinf(a);
                fx_splat(x, y, gate_z[i], wall_col, 0);
                fx_splat(x, y, gate_z[i] - GATE_THICK, wall_col, 0);
            }
            /* yellow gate posts at both edges of the gap */
            for (int side = -1; side <= 1; side += 2) {
                float a = gate_gap[i] + (float)side * half;
                float x = TUN_R * cosf(a);
                float y = TUN_R * sinf(a);
                for (int k = -1; k <= 1; k++)
                    fx_splat(x, y, gate_z[i] + (float)k * GATE_THICK,
                             FX_YELLOW, 0);
            }
        }

        /* dotted aim line at the ship's angle */
        {
            uint8_t col = FX_GREEN;
            if (nearest >= 0) {
                float d = ang_diff(theta_p, gate_gap[nearest]);
                if (fabsf(d) > gap_half() - SHIP_HALF) col = FX_RED;
            }
            for (float z = PLAYER_Z; z < 33.0f; z += 2.0f) {
                fx_splat(TUN_R * cosf(theta_p), TUN_R * sinf(theta_p),
                         z, col, 0);
            }
        }
    }

    /* the ship */
    {
        float x = TUN_R * cosf(theta_p);
        float y = TUN_R * sinf(theta_p);
        uint8_t c = FX_GREEN;
        if (t < invuln_until && ((int)(t * 10.0f) & 1))
            c = FX_MAGENTA;
        fx_splat(x, y, PLAYER_Z, c, 1);
        fx_splat(TUN_R * cosf(theta_p), TUN_R * sinf(theta_p),
                 PLAYER_Z + 2.5f, FX_WHITE, 0);
        for (int side = -1; side <= 1; side += 2) {
            float a = theta_p + (float)side * 0.10f;
            fx_splat(TUN_R * cosf(a), TUN_R * sinf(a),
                     PLAYER_Z - 0.5f, c, 0);
        }
        for (int k = 1; k <= 5; k++) {
            fx_splat(x, y, PLAYER_Z - 2.2f * (float)k,
                     (k < 3) ? FX_CYAN : FX_BLUE, 0);
        }
    }
}

static void game_update(float dt, float t)
{
    float half = gap_half();
    float speed = START_SPEED + (float)score * 0.3f;
    if (speed > MAX_SPEED) speed = MAX_SPEED;

    for (int i = 0; i < NUM_GATES; i++) {
        gate_z[i] -= speed * dt;

        if (gate_z[i] < -38.0f) {
            gate_z[i] += (float)NUM_GATES * GATE_SPACING;
            gate_gap[i] = 6.2831853f * fx_randf(&rng);
            gate_hit[i] = 0;
            gate_passed[i] = 0;
        }

        if (!gate_hit[i] && fabsf(gate_z[i] - PLAYER_Z) < 2.0f &&
            t > invuln_until) {
            float d = ang_diff(theta_p, gate_gap[i]);
            if (fabsf(d) > half - SHIP_HALF) {
                gate_hit[i] = 1;
                lives--;
                invuln_until = t + 1.5f;
                flash_until = t + 0.35f;
                if (lives <= 0)
                    g_state = ST_OVER;
            }
        }
        if (!gate_passed[i] && !gate_hit[i] && gate_z[i] < PLAYER_Z - 3.0f) {
            gate_passed[i] = 1;
            score++;
        }
    }
}

void fx_tunnel_build(uint64_t t_ms)
{
    float t = (float)t_ms * 0.001f;
    float dt = 0.0f;

    if (!inited) game_init();

    if (last_ms_f > 0.0f) dt = t - last_ms_f;
    last_ms_f = t;
    if (dt < 0.0f) dt = 0.0f;
    if (dt > 0.25f) dt = 0.25f;

    if (kbd_fd < 0 && t_ms - last_scan_ms > 2000u) {
        last_scan_ms = t_ms;
        kbd_fd = open_keyboard();
        if (kbd_fd >= 0)
            fprintf(stderr, "tunnel: keyboard found late");
    }
    poll_keyboard();

    if (quit_pending) {
        quit_pending = 0;
        exit(0);
    }

    {
        int dir = (turn_right ? 1 : 0) - (turn_left ? 1 : 0);
        theta_p += (float)dir * cfg_turn * dt;
        while (theta_p > 3.14159265f) theta_p -= 6.2831853f;
        while (theta_p < -3.14159265f) theta_p += 6.2831853f;
    }

    if (start_pending) {
        start_pending = 0;
        if (g_state == ST_READY) {
            g_state = ST_PLAY;
            last_ms_f = t;
        } else if (g_state == ST_OVER) {
            game_reset();
            g_state = ST_PLAY;
            last_ms_f = t;
        }
    }

    if (g_state == ST_PLAY)
        game_update(dt, t);

    draw_scene(t);
    draw_hud3d(t);
}
