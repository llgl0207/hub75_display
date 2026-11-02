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

**行地址映射（本板实测）**：行地址就是半屏内的物理行号：

```text
上半屏 (rgb1/upper)：row_addr = physical_y           (0 = 面板最上一行)
下半屏 (rgb2/lower)：row_addr = physical_y - 32      (0 = 接缝下一行)
```

2026-11-02 的颜色诊断（上半球绿、下半球红）确认：上半球数据应写在
`row_addr=20..31`（接缝上方），下半球写在 `row_addr=0..11`（接缝下方）；
面板显示为绿色的上半球在红色的下半球之上，数据通路和行映射正确。

**顶部单行 ghost**：每个 slot 的第 0 行（面板最上一行）会显示上一槽最后
一行（row 31）的数据，形成一条单行彩色条纹。这是扫描/面板首行 artifact，
不是帧内容或行映射错误。当前先保留；若要消除，可在 PL 扫描器里对
`row_addr=0` 保持 OE 关闭（空白掉面板最上一行），需要重建位流。

颜色是 3-bit：`1`=蓝，`2`=绿，`4`=红，`7`=白，组合可混色。

### 静止面板 vs 旋转体显示

- **静止显示**（无红外/无旋转调试）：让 **64 个 slice 内容完全相同**。
  扫描端每个 slot 都显示同一张 128x64 图，人眼看到一张稳定的 2D 图；
  帧号变化就得到动画。`HUB75_VOLUMETRIC_TEST=0` 保留这个模式。
- **旋转体显示**：每个 slice 是某个角度上的 128x64 切片。当前 `main.c`
  默认（`HUB75_VOLUMETRIC_TEST=1`）渲染**左右两个球体**：

  ```text
  面板坐标: x = 0..128 (列), y = 0..64 (行), 旋转轴在 x=64, y=32
  左球: 世界坐标 (-24, 32, 0), 半径 12, 红色 (4)
  右球: 世界坐标 (+24, 32, 0), 半径 12, 绿色 (2)
  slice s 的角度 theta = 2*pi*s/64
  ```

  对 slice 角度 theta，面板上水平半径 `r = x - 64`、高度 y 的点在球
  `(x0, y0, 0)` 内当且仅当：

  ```text
  (r - x0*cos(theta))^2 + (y - y0)^2 + (x0*sin(theta))^2 <= radius^2
  ```

  这正好是旋转平面与球体的交线。slice 0 和 slice 32（相差 180°）各出现
  一次左右球，64 片合起来在眼睛里重建两个立体球。`sin_q15[]` 表示
  `sin(2*pi*s/64)*32767`，`cos` 用 `sin_q15[(s+16)&63]`，因此不依赖 libm。

  当前帧只提交一次（静态体），PL 每圈重复读取同一个 DDR 基址；PS 不再
  改写它，所以不会撕裂。日志每秒打印一次 `status ... slice ... id 1
  period ...`，`id` 不增长是正常的。

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

### 两球旋转体（当前 `main.c`，`HUB75_VOLUMETRIC_TEST=1`）

对每个 slice 计算旋转平面与两个球的交线，不再复制同一张图。核心循环：

```c
for (slice = 0; slice < 64; slice++) {
    float st = sin_q15[slice] / 32768.0f;          /* sin(theta) */
    float ct = sin_q15[(slice + 16) & 63] / 32768.0f; /* cos(theta) */

    for (row = 0; row < 32; row++) {
        float yu = (row + 0.5f) - 32.0f;           /* 上半屏，row=0 是面板顶 */
        float yl = (row + 32.5f) - 32.0f;          /* 下半屏，row=0 是接缝下 */
        for (col = 0; col < 128; col++) {
            float rx = (col + 0.5f) - 64.0f;
            uint8_t upper = 0, lower = 0;
            for (b = 0; b < 2; b++) {
                float p = balls[b].x * ct;          /* 球心在平面上的投影 */
                float d = balls[b].x * st;          /* 球心到平面的距离 */
                float dx = rx - p;
                if (dx*dx + yu*yu + d*d <= 12.0f*12.0f) upper = balls[b].colour;
                if (dx*dx + yl*yl + d*d <= 12.0f*12.0f) lower = balls[b].colour;
            }
            if (upper || lower)
                hub75_frame_set_pixel(frame, slice, row, col, upper, lower);
        }
    }
}
```

`balls[]` 为 `{-24, 0, 红}` 和 `{+24, 0, 绿}`。渲染完成后
`submit_frame()` 只调用一次；之后 PS 每秒打印一次状态，不再重写帧。

### 静止动画（`HUB75_VOLUMETRIC_TEST=0`）

所有 slice 相同：先画 slice 0，再复制到其余 63 片。

```c
static void render_frame(uint8_t *frame, uint32_t frame_no)
{
    int s, row, col;

    memcpy(frame, background_slice, HUB75_SLICE_BYTES); /* 清 slice 0 */
    /* ... 在 slice 0 上画白边框、十字线和小球 ... */

    for (s = 1; s < HUB75_SLICES; s++)
        memcpy(frame + s * HUB75_SLICE_BYTES,
               frame, HUB75_SLICE_BYTES);
}
```

> 注意：静止模式是早期 2D 示例，`background_pixel` 直接把 `row_addr` 当上下
> 半屏的 y，和实际面板的行映射一致（上半 0..31、下半 0..31）。顶部单行
> ghost 只影响面板最上一行，静止图案里可能也可见，但不影响主内容。

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
  `status` ch2 读到约 `period_ticks`。按 50 MHz tick：
  `1800 RPM = 30 rev/s ≈ 1,666,667`，`20~30 rev/s ≈ 1.67M~2.5M`；
  如果电机是 `20~30 RPM`，周期约为 `100M~150M`，此时一圈要 2~3 s，
  64 片无法靠视觉暂留融合成实体，只会看到逐片扫描。
- 没接红外/不转：`period_valid=0`，调度器用 1800 RPM 回落；
  DDR reader 的 `BENCH_FALLBACK=1` 会把 `slice_index 63→0` 当作合成 revolution
  来锁存新帧。静止动画（`HUB75_VOLUMETRIC_TEST=0`）靠这个模式跑。
  第一次真实 IR 触发后回落永久关闭。
- 体显示模式（`HUB75_VOLUMETRIC_TEST=1`）在不转时，面板会把 64 个 slice
  快速轮流显示，看起来是模糊/闪烁，这是正常的；转起来并锁定 `period` 后才
  能看到两个球。
- `period` 一直为 0 说明还没测满 5 个 IR 周期（或 IR 没接/脉宽不足 1 ms）。
  高速旋转时如果 IR 遮光片太窄（例如 1800 RPM 下小于约 10.8°），
  脉宽会短于 1 ms 消抖窗口，触发会被丢弃；此时需要加宽遮光片或减小
  `IR_DEBOUNCE_US`（PL 重建）。

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

### 脱机 SD 启动（裸机，已上板验证）

不需要 JTAG 和 Vitis IDE，板子上电即运行。链路：

```
BOOT.BIN = FSBL + hub75_ps_stage1.bit + hub75_renderer.elf
  -> BootROM 从 SD0 (MIO40..45) 读 FSBL
  -> FSBL 配置 PS7/DDR、加载 bitstream、加载 ELF 到 0x00100000
  -> 应用启动，UART1 (COM11) 输出，PL 显示
```

构建 BOOT.BIN（会新建 `build/work/vitis_sd`，不会动现有 platform）：

```powershell
.\build\run_build_sd_boot.bat
```

它用 Vitis Python API 从 `board/output/hub75_ps_stage1.xsa` 建 platform/FSBL，
编译 `hub75_renderer`，再调用 `bootgen` 生成 `board/output/BOOT.BIN`。
批处理里的 `chcp 65001 + PYTHONUTF8` 是中文 Windows 上 Vitis API 的必要绕行。

写卡：

```powershell
# 先找可移动盘符
Get-Volume | Where-Object DriveType -eq 'Removable'
# 只写 BOOT.BIN 到 FAT 分区根目录（拒绝非可移动盘/非 FAT）
.\build\copy_boot_to_sd.ps1 -Drive F:
```

启动：

1. microSD 插到板子（MBR + FAT/FAT32，BOOT.BIN 在根目录）；
2. **SW4 按手册 BOOTMODE 图的 SD 行**（两个拨码在下/远离 ON）；
3. **断电再上电**（boot mode 在 POR 采样，按复位键不保证重新采样）。

已验证结果（2026-11-02，无 IR/无旋转）：上电后面板直接显示动画，COM11 5 秒
收到 98 行 `frame ...`（约 20 fps），`status` 的 `buf_ready=1`，`period=0`
（无 IR 属正常）。

两球体版本（`HUB75_VOLUMETRIC_TEST=1`）已重建 `BOOT.BIN`（4,195,816 B）。
用 `build/jtag_run_app.tcl <elf>` 下载后 COM11 每秒打印
`status ... slice ... id 1 period 0`，`buf_ready=1`、`frame_done=1`，
说明静态体帧已经锁存；旋转后的两个球体成形结果 TBD。

> 如果卡里原来有 Linux 的 BOOT.bin，先备份再覆盖。本次已把原文件备份到
> `build/work/sd_backup/BOOT.bin.original`；恢复时把它拷回卡根目录同名即可。
> 当前 FSBL 的 stdout 仍是 UART0（不可见），所以只看到应用启动后的 UART1 输出；
> 需要 FSBL 启动日志时，把 FSBL BSP 的 stdout 改到 `ps7_uart_1` 再重建。

## 8. 观测与排障

| 现象 | 先看什么 |
|---|---|
| 串口无输出 | 本板 CP2102 在 UART1 MIO48/49；应用 `console_init()` 会配置；确认 COM11 |
| 面板全黑 | `status` bit2（buf_ready）是否为 1；为 0 说明 reader 没填满两个 buffer |
| `buf_ready=0` 且 frames 不涨 | DDR reader 预取/handoff；回归 `tb_hub75_ddr_reader` |
| 画面撕裂/旧帧 | PS 在 `frame_done` 翻转前重写了显示中的 buffer |
| 画面静止不更新 | `frame_no` 没参与渲染，或 UART 观察到的 frame 没涨 |
| `period` 恒 0 | 没接 IR/没测满 5 个周期；静止调试是正常的 |
| 体显示模式不转时画面模糊/闪烁 | 正常；64 个 slice 在快速轮流显示，转起来才会合成体 |
| 转起来只看到一片或球很扁 | `period` 是否已非 0；转速太低（20~30 RPM 无法视觉暂留）；或 `slice` 与角度符号反 |
| 两个球颜色左右互换 | 面板列镜像或旋转方向相反；交换 `balls[]` 的 x 符号/颜色 |
| 第一圈 slice 0 缺失/黑一竖条 | 已知启动限制：reader 在上一圈最后一槽才预取 slice 0，第二圈起完整 |
| 最上一行有单行彩色条纹 | 每个 slot 第 0 行 ghost 上一槽 row 31；扫描/面板首行 artifact，可忽略；要消除需 PL 对 row_addr=0 保持 OE 关闭并重建位流 |
| 上半/下半颜色互换 | 交换 `hub75_frame_set_pixel` 的 upper/lower |
| 列方向反/偏移 | 面板接线；渲染端预移 col，或改 `RGB2_COLUMN_OFFSET` |

可读回 DDR 验证渲染内容（CPU 会短暂 halt）：

```powershell
E:\AMD\2026.1\Vitis\bin\xsdb.bat -eval `
 'connect -url TCP:localhost:3122; targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}; catch {stop}; puts [mrd 0x10000000]; con'
```

## 9. 当前限制

- 64 slices/帧，固定 1/32 扫描；400 片、76 slot/圈、后半圈镜像是后续工作。
- 64 片对应 5.625°/片；两个球靠约 10 片/次的交线重建，边缘会有分片感。
- `frame_ctrl[15:8]` 的 slice 数当前 RTL 忽略（固定 64）。
- 当前体显示应用只提交一次静态帧（日志约 1 Hz）；静止模式仍是 20 fps
  （`usleep(50000)`）。要动态体内容时再按 `frame_done` 每圈重绘/提交。
- 本板 PS 控制台是 UART1 MIO48/49；UART0 MIO14/15 无数据。
- `proc_sys_reset` 的 `aux_reset_in` 必须高有效（BD 已修），否则 AXI 永久复位、
  第一次访问 0x41200000 就会挂死。

## 10. 文件索引

| 文件 | 作用 |
|---|---|
| `hub75_renderer/main.c` | 应用：GPIO 初始化、两球体渲染（`HUB75_VOLUMETRIC_TEST=1`）/静止动画（=0）、提交、状态/IR 周期日志 |
| `hub75_renderer/hub75_frame.c/.h` | 帧格式与像素写入 |
| `hub75_renderer/hub75_regs.h` | AXI GPIO 基址与控制/状态位定义 |
| `src/hub75_ddr_reader.v` | S_AXI_HP0 读、6-bit 解包、乒乓预取 |
| `src/hub75_slice_ram.v` | 双 4096x6 BRAM |
| `src/hub75_ps_top.v` | IR + 调度 + 扫描 |
| `src/hub75_system.v` | PL 顶层连接与 status/period 打包 |
| `build/jtag_run_app.tcl` | 命令行加载 bitstream/ps7_init/ELF |
