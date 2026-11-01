# PS 开发者指南：用 PS 控制 PL 的 HUB75 显示

本文面向写 PS 应用的人，说明 **PS 如何把一幅图送到 DDR、PL 如何取数并显示**，以及
怎样在现有工程上做静态图、动画和后续的体显示内容。硬件/BD 的细节见
`report/ps_development.md`。

## 1. 分工一句话

**PS 只管画帧和提交，PL 管所有实时时序。**

```
PS (Cortex-A9, bare metal)              PL (50 MHz, FCLK_CLK0)
──────────────────────────              ─────────────────────────────
render 128x64 slice images
  -> DDR frame A/B (0x10000000/0x10200000)
  -> D-cache flush
  -> AXI GPIO ctrl: frame_base
  -> AXI GPIO ctrl: submit toggle
                                        IR revolution_start
                                          -> latch pending frame base
                                          -> 64 slots / revolution
                                          -> per slot: prefetch next slice over S_AXI_HP0
                                          -> slice RAM ping-pong
                                          -> hub75_scan -> RGB/CLK/LAT/OE/ADDR
  <- AXI GPIO status: frame_done/frame_id
```

PS 永远不产生 HUB75 像素时钟、行地址或 LAT/OE；这些全部由 PL 按红外节拍产生。
PS 改显示内容只需要改 DDR 里的像素，然后提交。

## 2. 寄存器接口（AXI GPIO）

| 地址 | 通道 | 方向 | 含义 |
|---|---|---|---|
| `0x41200000` | ctrl ch1 | PS→PL | `frame_base[31:0]`：当前帧 DDR 物理地址 |
| `0x41200000` | ctrl ch2 | PS→PL | `frame_ctrl`：bit0 submit 翻转，bit1 enable，bits[15:8] slice 数（当前 RTL 固定 64，保留） |
| `0x41210000` | status ch1 | PL→PS | `status`：bit0 frame_ack，bit1 reader_busy，bit2 buf_ready，bit3 frame_done 翻转，bits[13:8] active_slice，bits[23:16] frame_id |
| `0x41210000` | status ch2 | PL→PS | `period_ticks[31:0]`：IR 实测周期（最近 5 个间隔的均值，50 MHz tick） |

`frame_ctrl` 的 enable 为 1 时 PL 才允许 DDR reader 工作。submit 是**翻转位**，不是脉冲：
每提交一帧把 bit0 取反一次。

## 3. 帧格式

```
64 slices per frame
slice = 32 row_addr x 128 col x 6-bit word
word[2:0] = rgb1 (upper half)
word[5:3] = rgb2 (lower half)
6-bit words packed LSB-first
slice size = 3072 bytes; frame size = 64 * 3072 = 192 KiB
frame A = 0x10000000
frame B = 0x10200000   (2 MiB apart)
```

像素坐标约定：`hub75_frame_set_pixel(frame, slice, row_addr, col, upper, lower)`
把 `col` 直接存进 slice 的第 `col` 列；扫描端先移出第 127 列。

颜色是 3-bit：`1`=蓝，`2`=绿，`4`=红，`7`=白，组合可混色。

### 静止面板 vs 旋转体显示

- **静止显示**（当前调试方式，无红外/无旋转）：让 **64 个 slice 内容完全相同**。
  扫描端每个 slot 都显示同一张 128x64 图，人眼看到一张稳定的 2D 图；
  帧号变化就得到动画。
- **旋转体显示**：每个 slice 是某个角度上的 128x64 切片。例如测试图案里
  slice 0 全白（0° 锚点），其他 slice 在列 `2*slice` 画红/蓝条，转起来就是
  红/蓝螺旋 + 白色平面。

## 4. 提交一帧的完整时序

```c
#define HUB75_CTRL_SUBMIT      (1u << 0)
#define HUB75_CTRL_ENABLE      (1u << 1)
#define HUB75_CTRL_SLICES(n)   (((uint32_t)(n) & 0xFFu) << 8)
#define HUB75_ST_FRAME_DONE    (1u << 3)

static uint32_t last_done;
static uint32_t toggle;

void submit_frame(uint8_t *frame)
{
    Xil_DCacheFlushRange((UINTPTR)frame, HUB75_FRAME_BYTES);

    XGpio_DiscreteWrite(&gpio_ctrl, 1, (uint32_t)(UINTPTR)frame);
    (void)XGpio_DiscreteRead(&gpio_ctrl, 1);   /* 确保基址先到 PL */

    toggle ^= 1u;
    XGpio_DiscreteWrite(&gpio_ctrl, 2,
        HUB75_CTRL_ENABLE | HUB75_CTRL_SLICES(64) | toggle);
}

void wait_frame_done(void)
{
    uint32_t s = XGpio_DiscreteRead(&gpio_status, 1);

    while (((s & HUB75_ST_FRAME_DONE) ? 1u : 0u) == last_done)
        s = XGpio_DiscreteRead(&gpio_status, 1);
    last_done = (s & HUB75_ST_FRAME_DONE) ? 1u : 0u;
}
```

完整的双缓冲循环：

```c
uint8_t *frames[2] = { (uint8_t *)0x10000000u, (uint8_t *)0x10200000u };

for (frame_no = 0;; frame_no++) {
    uint8_t *frame = frames[frame_no & 1u];

    wait_frame_done();          /* 上一帧已被 PL 锁存，旧 buffer 可复用 */
    render_frame(frame, frame_no);
    submit_frame(frame);
    usleep(50000);              /* 20 fps；静止动画建议 20~30 fps */
}
```

### PL 侧发生了什么

1. 检测 submit 翻转 → 把 `frame_base` 存成 `pending_base`，不立即换帧；
2. 等到 `revolution_start`（真实 IR 过零；无 IR 时用 1800 RPM 回落的
   `slice_index 63→0`）→ `active_base<=pending_base`、epoch 翻转、
   `frame_done`/`frame_ack` 同时翻转、`frame_id++`；
3. 每个 slot 无条件预取**下一个** slice 到非显示 buffer，下一个 slot 边界切换；
4. scan 从显示 buffer 读 6-bit word，按 1/32 扫描输出。

所以 PS 在 `frame_done` 翻转前绝对不能重写正在显示的那块 buffer，否则会撕裂。

## 5. 渲染示例

### 静止动画（当前 `main.c` 的做法）

所有 slice 相同：先画 slice 0，再复制到其余 63 片。

```c
static void render_frame(uint8_t *frame, uint32_t frame_no)
{
    int s, row, col;

    memset(frame, 0, HUB75_SLICE_BYTES);   /* 只清 slice 0 */

    for (row = 0; row < HUB75_ROW_ADDRS; row++) {
        for (col = 0; col < HUB75_COLS; col++) {
            uint8_t upper = 0, lower = 0;

            /* 2 px 白边框 */
            if (row < 2 || row >= HUB75_ROW_ADDRS - 2 ||
                col < 2 || col >= HUB75_COLS - 2) {
                upper = lower = 7;
            } else {
                int dx = col - ball_x, dy = row - ball_y;
                if (dx*dx + dy*dy <= ball_r*ball_r)
                    upper = lower = color;      /* 动画小球 */
            }
            hub75_frame_set_pixel(frame, 0, row, col, upper, lower);
        }
    }

    for (s = 1; s < HUB75_SLICES; s++)
        memcpy(frame + s * HUB75_SLICE_BYTES,
               frame, HUB75_SLICE_BYTES);
}
```

### 体显示切片

不要复制；对每个 slice 画该角度对应的横截面，例如：

```c
for (slice = 0; slice < 64; slice++)
    for (row = 0; row < 32; row++)
        for (col = 0; col < 128; col++)
            hub75_frame_set_pixel(frame, slice, row, col, upper, lower);
```

`upper` 送到面板上半屏（rgb1），`lower` 送到下半屏（rgb2）。

## 6. 红外与无红外调试

- 有红外、电机转：`ir_revolution_sync` 每个过零产生 `revolution_start`；
  测满 5 个间隔后 `period_valid=1`，调度器用实测周期（64 slot/圈）；
  `status` ch2 读到约 `period_ticks`（1800 RPM ≈ 1,666,667）。
- 没接红外/不转：`period_valid=0`，调度器用 1800 RPM 回落；
  DDR reader 的 `BENCH_FALLBACK=1` 会把 `slice_index 63→0` 当作合成 revolution
  来锁存新帧。静止动画就是靠这个模式跑。第一次真实 IR 触发后回落永久关闭。
- `period` 一直为 0 说明还没测满 5 个 IR 周期（或 IR 没接/脉宽不足 1 ms）。

## 7. 构建与运行

### 只改 PS 内容时

PL 位流不用重建，只重编应用：

```powershell
E:\AMD\2026.1\Vitis\bin\empyro.bat build_app `
  -s C:\Users\210\Documents\intcode\123\hub75_display\hub75_renderer\src `
  -b C:\Users\210\Documents\intcode\123\hub75_display\hub75_renderer\build
```

### 下载并运行（命令行）

```powershell
# 确保 hw_server 在 3122；Vitis 自带或手动起：
E:\AMD\2026.1\Vivado\bin\hw_server.bat -s TCP::3122 -d

# 下 bitstream + ps7_init + ELF + run
E:\AMD\2026.1\Vitis\bin\xsdb.bat build\jtag_run_app.tcl

# 读控制台（UART1 -> CP2102 COM11）
.\build\capture_com11.ps1 -Port COM11 -Seconds 10
```

Vitis GUI 方式：Run Configuration 选 `hub75_ps_stage1.bit`，Program FPGA，
Reset entire system，下载 ELF；串口开 **COM11 115200**（注意本板 CP2102 在
UART1 MIO48/49，不是 UART0）。

### 改了 PL 才需要

```powershell
.\build\vivado.ps1 build\build_ps_system.tcl -TclArgs 1
```

## 8. 观测与排障

| 现象 | 先看什么 |
|---|---|
| 串口无输出 | 本板 CP2102 在 UART1 MIO48/49；应用 `console_init()` 会配置；确认 COM11 |
| 面板全黑 | `status` bit2（buf_ready）是否为 1；为 0 说明 reader 没填满两个 buffer |
| `buf_ready=0` 且 frames 不涨 | DDR reader 预取/handoff；回归 `tb_hub75_ddr_reader` |
| 画面撕裂/旧帧 | PS 在 `frame_done` 翻转前重写了显示中的 buffer |
| 画面静止不更新 | `frame_no` 没参与渲染，或 UART 观察到的 frame 没涨 |
| `period` 恒 0 | 没接 IR/没测满 5 个周期；静止调试是正常的 |
| 上半/下半颜色互换 | 交换 `hub75_frame_set_pixel` 的 upper/lower |
| 列方向反/偏移 | 面板接线；渲染端预移 col，或改 `RGB2_COLUMN_OFFSET` |

可读回 DDR 验证渲染内容（CPU 会短暂 halt）：

```powershell
E:\AMD\2026.1\Vitis\bin\xsdb.bat -eval `
 'connect -url TCP:localhost:3122; targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}; catch {stop}; puts [mrd 0x10000000]; con'
```

## 9. 当前限制

- 64 slices/帧，固定 1/32 扫描；400 片、76 slot/圈、后半圈镜像是后续工作。
- `frame_ctrl[15:8]` 的 slice 数当前 RTL 忽略（固定 64）。
- 示例应用 20 fps（`usleep(50000)`）；实际上限受渲染/刷 cache/提交等待限制。
- 本板 PS 控制台是 UART1 MIO48/49；UART0 MIO14/15 无数据。
- `proc_sys_reset` 的 `aux_reset_in` 必须高有效（BD 已修），否则 AXI 永久复位、
  第一次访问 0x41200000 就会挂死。

## 10. 文件索引

| 文件 | 作用 |
|---|---|
| `hub75_renderer/main.c` | 应用：GPIO 初始化、渲染、提交、状态/IR 周期日志 |
| `hub75_renderer/hub75_frame.c/.h` | 帧格式与像素写入 |
| `hub75_renderer/hub75_regs.h` | AXI GPIO 基址与控制/状态位定义 |
| `src/hub75_ddr_reader.v` | S_AXI_HP0 读、6-bit 解包、乒乓预取 |
| `src/hub75_slice_ram.v` | 双 4096x6 BRAM |
| `src/hub75_ps_top.v` | IR + 调度 + 扫描 |
| `src/hub75_system.v` | PL 顶层连接与 status/period 打包 |
| `build/jtag_run_app.tcl` | 命令行加载 bitstream/ps7_init/ELF |
