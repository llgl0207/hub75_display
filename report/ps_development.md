# PS + DDR 图像通路开发记录

> 状态：**RTL 仿真通过、Vivado 构建通过；Vitis 应用与上板验证尚未完成**。
> 最后更新：2026-11-01。

## 1. 本增量做了什么

在原有 PL-only HUB75 工程上增加：

- Zynq PS7：UART0、DDR3、FCLK_CLK0 50 MHz、AXI GP0、S_AXI_HP0。
- AXI GPIO 控制/状态：PS 写 `frame_base`/`frame_ctrl`，读 `status`/`period`。
- `hub75_ddr_reader`：PL 自主 AXI3 读 DDR，16-beat 突发 × 24 = 3072 B/片；
  6-bit 解包；乒乓 BRAM。
- `hub75_slice_ram`：2 × 4096×6 bit BRAM36。
- `hub75_scan` PATTERN_MODE=3：从 slice RAM 取像素，`[2:0]=rgb1`、`[5:3]=rgb2`。
- `hub75_ps_top` / `hub75_system` / `system_top`：PS+PL 顶层。
- Vitis 裸机渲染器源码（`sw/`）。

原有 `hub75_top`（PL-only 板级测试）保持不动，仍可用 `build/build_board_test.tcl` 构建。

## 2. 板卡事实与关键修正

| 项 | 值 |
|---|---|
| 板卡 | MicroPhase Mizar-Z7，XC7Z020CLG400（工程按 -2；手册写 -1，待丝印确认） |
| PS 时钟 | 33.333 MHz（E7） |
| DDR3 | 2 × SK hynix H5TQ4G63FFR-RD（4 Gb ×16，DDR3-1866），1 GB，32-bit |
| PS 串口 | **UART1**，MIO48(TX)/MIO49(RX)，板载 CP2102，115200 8N1（实测；手册/旧文档写的 UART0 MIO14/15 与本板不符） |
| MIO 电压 | bank0 3.3 V，bank1 1.8 V |
| PS LED | MIO50/51，低电平亮 |

**UART 修正（上板实测）**：本板 CP2102 实际接在 **UART1 的 MIO48(TX)/MIO49(RX)**，不是手册
所写的 UART0 MIO14/15。运行期把 MIO48/49 切到 UART1（L3_SEL=7，bank1 LVCMOS18）并强制发送，
CP2102 的 COM11 能完整收到；UART0 在 MIO14/15 上收发均无数据，PC 端发送也进不了 RX FIFO。
BD 仍同时启用 UART0（MIO14/15）和 UART1（MIO48/49）；渲染应用在 `console_init()` 里显式
配置 UART1，因此用旧 XSA 构建的 BSP 也能正常输出。板级验证时这是第一个要检查的点。

## 3. PS7 配置（`build/create_ps_bd.tcl`）

- 33.333 MHz 晶振，APU 667 MHz，FCLK_CLK0 50 MHz。
- DDR3：`MT41K256M16RE-125`（H5TQ4G63FFR-RD 的 4 Gb×16 等效型号），32-bit，
  4096 Mbit/片，`DDR3_1066F`，CL7/CWL6/tRCD7/tRP7/tRC48.91/tRAS34/tFAW25，
  外部 VREF，**DDR 时钟先 400 MHz**（800 MT/s），memtest 通过后再升 533.333（1066 MT/s）。
- UART0 MIO14..15 + UART1 MIO48..49（板载 CP2102 在 UART1）；QSPI/SD/ENET/USB 关闭。
- `M_AXI_GP0`、`S_AXI_HP0`：50 MHz，64-bit data，6-bit ID。
- `proc_sys_reset` 产生同步于 FCLK 的 AXI 复位；`FCLK_RESET0_N` 经反相接 `ext_reset_in`。
- BD 只导出 `S_AXI_HP0`、FCLK/复位、GPIO 端口、DDR/FIXED_IO；PL 顶层是手写
  `system_top`，不在 BD 里做 module reference。

## 4. 帧格式与地址

```text
slice -> 32 row addresses -> 128 columns -> 6-bit word
word[2:0] = rgb1 (upper half)
word[5:3] = rgb2 (lower half)
6-bit words packed LSB-first; 128*64*3/8 = 3072 B per slice
```

- 首版 64 片/帧（匹配 `SLOT_LOG2=6`），单帧 192 KiB。
- 帧 A `0x10000000`，帧 B `0x10200000`，各预留 2 MiB。
- 列约定与 PL-only 图案一致：PS 存 `col=x`，扫描先发 `x=127`。
- 400 片容量、76 片/圈、后半圈镜像复用均为后续目标，本版未启用。

## 5. AXI GPIO 控制/状态

| 通道 | 方向 | 位定义 |
|---|---|---|
| ctrl ch1 | PS→PL | `frame_base[31:0]` |
| ctrl ch2 | PS→PL | bit0 submit 翻转，bit1 enable，bits[15:8] slice_count |
| status ch1 | PL→PS | bit0 frame_ack，bit1 reader_busy，bit2 buf_ready，bit3 frame_done 翻转，bits[13:8] active_slice，bits[23:16] frame_id |
| status ch2 | PL→PS | `period_ticks[31:0]` |

- 基址：`axi_gpio_ctrl` 0x41200000，`axi_gpio_status` 0x41210000。
- PS 写完 `frame_base` 后回读一次，再写 `frame_ctrl`，保证基址先到 PL。
- PL 只在 `revolution_start` 锁存新基址；`frame_ack`/`frame_done` 同时翻转。
- PS 等 `frame_done` 翻转后才重写旧缓冲。

## 6. DDR 读取与乒乓

- `hub75_ddr_reader`：一次一个 16-beat AXI3 读突发（128 B），24 次 = 3072 B/片。
- 16-deep 64-bit beat FIFO + 6-bit 解包，1 word/clock；50 MHz 下约 100 µs/片。
- 乒乓：scan 读 active 缓冲，reader 写 inactive；只在 `slot_start` 切换到已经装有
  当前 slice 的 buffer。
- **预取策略（2026-11-02 修复）**：每个 slot 无条件预取**下一个** slice
  （`slice_index+1`；最后一个 slot 为下一帧/当前帧的 slice 0）到非读取 buffer。
  早期版本用“当前 slice 已存在才预取下一个”，启动时两个 buffer 都空，于是每个 slot
  重复抓当前 slice 到同一个 buffer，`read_buf` 永远不切换，scan 一直读初始空 BRAM：
  面板全黑、`status[2]`（buf_ready）恒 0。`tb_hub75_ddr_reader` 已加入 handoff 和
  `buf_ready` 检查。
- 帧切换：PS submit 后锁存 `pending_base`；最后一槽预取 pending 帧的 slice 0，
  下一次 `revolution_start` 原子切换 epoch。首帧/晚提交会有一圈旧数据，属已知限制。
- **无 IR 台上调试**：`BENCH_FALLBACK=1`（默认）时，如果从未收到 IR
  `revolution_start`，用调度器 1800 RPM 回落的 `slice_index 63→0` 作为合成
  revolution 接受首帧/新帧。任一次真实 IR 触发后 `ir_seen=1`，回落关闭；
  这不是漏触发恢复。最终整机可把该 parameter 设为 0。
- AXI 读地址：`frame_base + slice*3072 + burst*128`，128 B 对齐，不跨 4 KB。
- 写通道全部 tie-off；AXI GPIO 写不参与实时路径。

## 7. 构建与验证结果（本机 2026-11-01）

| 项 | 命令 | 结果 |
|---|---|---|
| Stage 0 PS-only | `.\build\vivado.ps1 build\build_ps_system.tcl` | `PS_SYSTEM_BUILD_COMPLETE stage=0` |
| Stage 1 PS+DDR | `.\build\vivado.ps1 build\build_ps_system.tcl -TclArgs 1` | `PS_SYSTEM_BUILD_COMPLETE stage=1` |
| RTL 回归 | `.\build\vivado.ps1 sim\run_regression.tcl` | 7/7 PASS，`REGRESSION_COMPLETE` |
| Stage 1 时序 | `build/reports/ps_stage1/timing.rpt` | WNS +6.401 ns，WHS +0.035 ns |
| Stage 1 DRC | `build/reports/ps_stage1/drc.rpt` | 0 errors（`ZPS7-1` 消失） |
| Stage 1 资源 | `build/reports/ps_stage1/utilization.rpt` | 2240 LUT，2723 FF，2 × BRAM36 |
| XSA | `board/output/hub75_ps_stage1.xsa` | 含 PS7、AXI GPIO、HP0；**不含 bitstream** |
| Stage 1 上板 | `build/jtag_run_app.tcl` + COM11 | `HUB75 PS renderer` / `DDR PASS`；状态 `buf_ready=1`，`frame_id`/`frame_done` 翻转；面板照片 TBD |
| 静止动画 | 无 IR、无旋转，64 slice 同图（白边框 + 十字线 + 反弹小球） | COM11 5 s 内 98 行（约 20 fps），`period 0`（无 IR 属正常），DDR 读回确认边框与 slice 复制；面板目视 TBD |

- XSA 用 `write_hw_platform -fixed` 导出（不含 bitstream），因为本脚本用显式
  opt/place/route 流程；Vitis Run Configuration 里单独选 `.bit`。
- WHS 最差路径在 AXI GPIO IP 内部输入同步器，+0.035 ns，时序 MET；如需更大余量，
  后续可换自定义寄存器块或降低 FCLK。
- BD 校验会留一条 critical warning：`HP0_DDR_LOWOCM` 没有赋给外部
  `S_AXI_HP0` 地址空间。外部 PL master 不在 BD 内，Address Editor 无法表示；
  实现/DRC 均无错误，reader 直接按 DDR 地址访问。
- 回归脚本改为用绝对路径直接调用 `xvlog/xelab/xsim.bat`，不再依赖
  `launch_simulation`：本机 Vivado 2026.1 的 `compile.bat` 在子进程 PATH 中找不到
  `xvlog` 时会报 `Spawn failed`。

## 8. 尚未完成（TBD）

- **Vitis platform/app 的 GUI 构建**：源码与步骤见 `sw/README.md`；本机 Vitis
  Python client 在中文 Windows 上 `create_client()` 报 UTF-8 解码错误，未脚本化。
- **上板**：UART1 控制台输出、DDR memtest、面板 DDR 图案、帧切换、半屏颜色映射。
- DDR 实际频率从 400 升到 533.333 后的 memtest。
- 400 片容量、76 片/圈、后半圈镜像、加速补显。
- 面板实际列偏移、rgb1/rgb2 半屏对应（用渲染器的红/蓝测试图判读）。
- 帧率/带宽实测、UART 日志、照片文件名。

## 9. Vitis 运行步骤摘要

1. platform 从 `board/output/hub75_ps_stage1.xsa` 创建，CPU `ps7_cortexa9_0`，OS standalone。
2. app 用 `Empty Application (C)`，加入 `sw/renderer/main.c` + `sw/common/*`。
3. Run Configuration：Program FPGA 选 `hub75_ps_stage1.bit`，Reset entire system。
4. CP2102（UART1 MIO48/49）COM 口 115200；预期 `HUB75 PS renderer` + `DDR PASS` + `frame ...`。
5. 面板：slice 0 全白锚点；其余片上半红条/下半蓝条随 slice 移动。

更详细的 GUI 步骤和故障表见 `sw/README.md`。
