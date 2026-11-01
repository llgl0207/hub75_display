# PS 软件（Vitis 2026.1 裸机）

## 产物与前提

| 项 | 值 |
|---|---|
| 硬件平台 | `board/output/hub75_ps_stage1.xsa`（PS7 + AXI GPIO + HP0） |
| bitstream | `board/output/hub75_ps_stage1.bit` |
| Stage 0 基线 | `board/output/hub75_ps_stage0.xsa` / `hub75_ps_stage0.bit`（仅 PS7） |
| PS 串口 | **UART1**，MIO48(TX)/MIO49(RX)，板载 CP2102，115200 8N1（上板实测；手册写的 UART0 MIO14/15 在本板无数据） |
| PS 时钟 | 33.333 MHz；DDR3 先 400 MHz，memtest 通过后可改 533.333 |
| AXI GPIO | `axi_gpio_ctrl` @ 0x41200000，`axi_gpio_status` @ 0x41210000 |

**Vitis 2026.1 已禁用 XSCT**。`build/build_sw.py` 是 Vitis Python API 版本，但在中文 Windows 上该版本可能在 `vitis.create_client()` 处报 UTF-8 解码错误；因此**推荐用 GUI**，Python 脚本仅作参考。

## 1. 建 platform

1. 打开 Vitis 2026.1。
2. `File > New Component > Platform`。
3. Name：`hub75_platform`
   Hardware Specification：`board/output/hub75_ps_stage1.xsa`
   OS：`standalone`
   Processor：`ps7_cortexa9_0`
4. Create，然后 Build。看到 `PLATFORM_BUILD_COMPLETE`/Build succeeded。

## 2. 建应用

### 2.1 Stage 0：Hello / DDR 基线

1. `File > New Component > Application`。
2. Name：`hub75_hello`
   Platform：`hub75_platform`
   Domain：`standalone_a9_0`
   Template：`Hello World`（或 `Empty Application (C)` 后用 `sw/hello/main.c`）
3. Build，得到 ELF（通常在 `build/work/vitis_ws/hub75_hello/build/` 或 IDE 的 `Debug/` 目录）。

### 2.2 Stage 1：DDR 图像上屏

1. 新建应用 `hub75_renderer`，模板 `Empty Application (C)`。
2. 把以下文件加入应用 `src`：
   - `sw/renderer/main.c`
   - `sw/common/hub75_frame.c`
   - `sw/common/hub75_frame.h`
   - `sw/common/hub75_regs.h`
3. Build。

`hub75_regs.h` 按 BSP 是否定义 `SDT` 选择初始化参数：

- Vitis 2026.1 的 standalone BSP 带 `-DSDT`，`XGpio_Initialize` 第二个参数是
  **基地址**，用 `XPAR_AXI_GPIO_CTRL_BASEADDR` / `XPAR_AXI_GPIO_STATUS_BASEADDR`；
- 旧的非 SDT BSP 才用 `XPAR_AXI_GPIO_CTRL_DEVICE_ID` / `..._STATUS_DEVICE_ID`。

如果 BD 实例名不同，按生成的 `xparameters.h` 改 `hub75_regs.h` 的
`HUB75_GPIO_*_INIT_ARG`。

## 3. JTAG 运行

1. 板卡启动跳线拨到 **JTAG**；插好 USB-JTAG 和 USB-UART（本板 CP2102）。
2. 运行配置（Run Configuration）：
   - Target：对应应用（`hub75_hello` 或 `hub75_renderer`）
   - 勾选 **Program FPGA**，bitstream 选 `board/output/hub75_ps_stage1.bit`
   - 勾选 **Reset entire system**
   - Download ELF，Run
3. 串口终端：CP2102（UART1 MIO48/49）的 COM 口，115200 8N1。
   - 正常输出：`HUB75 PS renderer`、`DDR PASS`，随后每秒一行 `frame ...`。
   - `main.c` 的 `console_init()` 会把 MIO48/49 切到 UART1；即使 BSP 还是按 UART0 生成的旧 XSA，也能输出。
4. 面板：
   - slice 0 两半全白（角度锚点）
   - 其余 slice 上半红条、下半蓝条，列位置随 slice 移动
   - 改 `render_pattern()` 后重新 Build/Run，面板内容应变化，证明数据来自 DDR。

## 4. 常见问题

| 现象 | 检查 |
|---|---|
| 没有 COM 口 | 装 USB-UART 驱动（本板 CP2102）；设备管理器看 Silicon Labs CP210x；PS 串口是 **UART1 MIO48/49**，不是 MIO14/15，也不是 PL 的 V12 |
| 串口无输出 | 用新 `main.c` 的 `console_init()`（UART1 MIO48/49）；确认 BD 里 UART1 已启用；先用 OCM 版 hello 排除 DDR |
| DDR FAIL / 卡住 | 降低 DDR 频率到 333.333；核对 `build/create_ps_bd.tcl` 的 DDR 参数；必要时用厂商 demo 的 `ps7_init` |
| `XPAR_..._DEVICE_ID` undeclared | Vitis 2026.1 是 SDT BSP，`XGpio_Initialize` 要基地址；用当前 `hub75_regs.h` 的 `HUB75_GPIO_*_INIT_ARG`（base address） |
| `xparameters.h` 找不到 GPIO | 应用用的 platform 不是 Stage 1 XSA，或 BD 实例名改了 |
| 面板半屏反/错列 | 交换 `render_pattern()` 的 upper/lower，或在渲染端按实测偏移预移 rgb2 列 |
| 面板一直黑 | 确认 `frame_ctrl` 的 enable/submit 已写；读 status 看 busy/ack；确认 bitstream 是 Stage 1 |

## 5. 地址与握手

- 帧 A：`0x10000000`；帧 B：`0x10200000`；每帧 64 片 × 3072 B = 192 KiB。
- `frame_base`（GPIO ctrl ch1）写当前帧基址；回读一次再写 `frame_ctrl`。
- `frame_ctrl`（GPIO ctrl ch2）：bit0 submit 翻转，bit1 enable，bits[15:8] 片数（64）。
- `status`（GPIO status ch1）：bit0 frame_ack，bit1 reader_busy，bit2 buf_ready，
  bit3 frame_done 翻转，bits[13:8] active_slice，bits[23:16] frame_id。
- PL 只在 `revolution_start` 锁存新基址；PS 等到 `frame_done` 翻转后才重写旧缓冲。

## 6. 可选：Vitis Python

`build/build_sw.py` 展示 Python API 的 platform/app 创建流程：

```powershell
E:\AMD\2026.1\Vitis\bin\vitis.bat -s build\build_sw.py
```

若在中文 Windows 上出现 `'utf-8' codec can't decode byte ...`，这是 Vitis
Python client 读取本地化子进程输出的问题；改用上面的 GUI 流程。
