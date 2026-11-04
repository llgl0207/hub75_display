# 基于 Zynq-7000 的旋转体积（3D）显示器

> 一块**正在旋转**的 HUB75 全彩面板，把 2D 图像扫描成悬在空中、可环绕观看的 3D 体素图像。
> 128×64、1/32 扫描的面板绕竖直轴自转；**PL 独占全部实时路径**（红外零位 → 周期估计 → 切片调度 →
> DDR 取帧 → 切片乒乓 → HUB75 波形），**PS 只负责渲染与提交帧**——像主机喂显卡一样。

*A 128×64 HUB75 panel spinning on a vertical axis turns flat frames into voxels in mid-air.
The PL owns the entire hard-real-time chain, the PS only renders and submits — the same split
as a host feeding a GPU. Verified on Zynq XC7Z020 with Vivado/Vitis 2026.1.*

---

## 作品速览

| 项目 | 内容 |
|---|---|
| 目标器件 | Zynq-7000 `XC7Z020CLG400-2`（Mizar-Z7 开发板） |
| 显示面 | HUB75 全彩面板，128×64 像素，1/32 扫描，320 mm × 160 mm |
| 成像方式 | 单面板绕**竖直轴**自转扫描；面板中心与转轴重合（非偏心），配重只用于消除残余不平衡 |
| 实时路径 | 全部在 PL，单时钟域 50 MHz；像素时钟 10 MHz（50 MHz ÷ 5） |
| 角度时基 | 每圈一次红外零位；2 级同步 + 1 ms 消抖 + 1 ms 闭锁 + 五次间隔滑动平均 |
| 角度分辨率 | 64 切片/圈，每切片 32 个行地址，每切片 3072 B |
| 帧缓冲 | DDR3 双缓冲 A/B，各 192 KB；帧基址只在换圈瞬间生效，PS 等 `frame_done` 才复用 |
| 运行方式 | JTAG 下载 / **microSD 脱机启动**（`BOOT.BIN` = FSBL + bitstream + ELF） |
| 工具链 | AMD Vivado / Vitis 2026.1（BASIC 许可证，**无 ILA**） |
| 许可证 | MIT（见 `LICENSE`） |

## 关键指标

下表数字全部可在本仓库 `data/logs/` 的 Vivado 原始报告里复核。

| 指标 | 数值 | 出处 |
|---|---|---|
| 资源占用（完整系统 `system_top`） | **2236 LUT（4.20%）、2746 FF、2 × BRAM36、0 DSP** | `data/logs/ps_stage1/utilization.rpt` |
| 时序（50 MHz） | **WNS +5.857 ns、WHS +0.044 ns，DRC 0 违例** | `data/logs/ps_stage1/timing.rpt`、`drc.rpt` |
| PL-only 板测镜像 | 959 LUT / 678 FF | `data/logs/pl_board_test/utilization.rpt` |
| 红外子系统独立综合 | WNS +9.207 ns | `data/logs/ir_standalone/timing.rpt` |
| 整场扫描上限 | 2280 次/秒（对应约 2138 RPM） | 面板与排线限制，设计输入 |
| 启动镜像 | `BOOT.BIN` 4,195,624 B | `board/output/BOOT.BIN` |
| RTL 回归 | 7 / 7 通过 | `sim/run_regression.tcl` |
| **未实测** | 实际转速、亮度、DDR 带宽、连续运行时长 | 一律标 **TBD**，不以估算值代替 |

## 系统架构

```text
                    ┌──────────────────────────── PS（双核 Cortex-A9）────────────────────────────┐
                    │ Linux hub75d 用户态终端 / 裸机 Vitis 渲染器                                │
                    │ 只做一件事：把一帧体积数据写进 DDR，然后翻转 submit 位                     │
                    └───────────────────────────────┬────────────────────────────────────────────┘
                                                    │ AXI GPIO：frame_base / submit / enable / slices
                                     ┌──────────────▼──────────────┐
                                     │  DDR3 双缓冲  帧A / 帧B      │  各 64 片 × 3072 B = 192 KB
                                     └──────────────┬──────────────┘
                                                    │ AXI3 HP0（16×64 bit × 24 突发/片）
   ┌────────────────────────────────────────────────▼───────────────────────────────────────────────┐
   │ PL：完整实时显示链路（50 MHz 单时钟域）                                                        │
   │  ① 红外零位同步、消抖、五间隔均值 → period_ticks                                                │
   │  ② 切片调度：一圈 64 切片 × 32 行，行预算随实测转速自适应                                        │
   │  ③ DDR 取帧：每切片预取 slice_index+1，写入切片 RAM 乒乓                                        │
   │  ④ HUB75 波形：128 像素时钟 × 32 行地址，移位开销 643 周期                                       │
   └────────────────────────────────────────────────┬───────────────────────────────────────────────┘
                                                    │ RGB1/RGB2、CLK、LAT、OE、ADDR[4:0]
                                          ┌─────────▼─────────┐
                                          │ 旋转体：HUB75 面板 │  775 电机竖直轴驱动，滑环 8 路供电
                                          └───────────────────┘
```

三条不可违反的架构边界：

1. **PS 不在实时路径上**。PS 从不产生像素时钟，也不参与任何逐切片事件；主机调度抖动进不了扫描。
2. **帧切换只发生在换圈边界**。`frame_base` 只被"登记为 pending"，由 PL 在 `revolution_start` 采样；
   一圈内基址不变。
3. **一次物理照射只产生一个 `revolution_start`**。输入调理是固定的 1 ms 消抖 + 1 ms 闭锁，
   不做自适应滤波、不做离群剔除。

帧格式（PS 与 PL 之间的唯一契约，详见 `sw/PS_DEVELOPER_GUIDE.md`）：

```text
一帧 = 64 个切片 × 3072 B
一个切片 = 32 个行地址 × 128 列 × 6 bit
6 bit 字：[2:0] = RGB1（上半屏），[5:3] = RGB2（下半屏），LSB-first 打包
帧 A = 0x1000_0000    帧 B = 0x1020_0000
```

## 目录结构

```text
hub75_display/
  src/         可综合 RTL：hub75_top（PL-only）、hub75_ps_top / hub75_system / system_top（PS+DDR）、
               hub75_sched / hub75_scan / hub75_ddr_reader / hub75_slice_ram / ir_revolution_sync / ir_debug_uart
  sim/         7 个 testbench + 回归 runner（run_regression.tcl，按 PASS 行判定）
  build/       可复现的构建驱动：Tcl 建工程/建 BD、Vitis Python 出 BOOT.BIN、JTAG 下载与读回
  board/       XDC 约束、bitstream / XSA / BOOT.BIN、上板测试流程
  sw/          PS 侧源码：baremetal / common（帧与寄存器定义）/ linux（hub75d 与 5 种特效）/ renderer
  tools/       字体表生成器（tools/font）与主机侧内容预览器（tools/preview）
  data/        实测数据：Vivado 报告快照、上板记录表、体积内容预览图
  report/      设计报告与工程日志（含长版中文设计报告 design_report_cn.md）
  skill/       从本项目提炼的 4 个可复用技能包
```

被 `.gitignore` 排除的是**生成物**：`hub75_display.runs/.cache/.hw/`、`platform/`、`hub75_renderer/`、
`_ide/`、`build/reports/`、`*.dcp`、`*.exe`、工具日志。它们都能由 `board/output/*.xsa` 与
`build/` 下脚本重新生成。

## 快速开始

前置：Windows + Vivado/Vitis 2026.1（含 XC7Z020）、Mizar-Z7 板卡、HUB75 面板与转台机构。
`vivado` 不必在 `PATH` 上——`build/vivado.ps1` 会自己找（`-VivadoBin` → `VIVADO_BIN` → `PATH` → 常见安装根目录）。

```powershell
# 1) RTL 回归（7 个 testbench，无需硬件）
.\build\vivado.ps1 sim\run_regression.tcl
#    期望最后打印 REGRESSION_COMPLETE，且每个 tb 都有 PASS: <tb> 行

# 2) 构建完整硬件（PS7 + HP0 + 切片 RAM + HUB75），报告落到 build/reports/
.\build\vivado.ps1 build\build_ps_system.tcl -TclArgs 1
#    期望打印 PS_SYSTEM_BUILD_COMPLETE stage=1

# 3) 出 SD 脱机启动镜像（platform + FSBL + app + bootgen）
.\build\run_build_sd_boot.bat
#    产物：board/output/BOOT.BIN

# 4) 写卡（只写 FAT/FAT32 根目录，先备份卡上的 BOOT.bin）
.\build\copy_boot_to_sd.ps1 -Drive F:
```

插卡后把 SW4 拨到 SD 行并**断电上电**（boot mode 只在 POR 采样，按复位键不保证重新采样）。
UART1（板上 CP2102，MIO48/49）是控制台，115200 8N1。

只做 PL 侧板测镜像（不带 PS/DDR）时：

```powershell
.\build\vivado.ps1 build\build_board_test.tcl     # -> board/output/hub75_ir_test.bit
.\build\vivado.ps1 build\probe_hw.tcl             # 只读枚举 JTAG 链
.\build\vivado.ps1 build\program_board.tcl        # 下载，按 DONE/EOS 判定
.\build\vivado.ps1 build\verify_bitstream.tcl     # 读回 USERCODE 0x48554237 自证来源
.\build\capture_uart.ps1 -Port COM11 -Seconds 8   # 解析 UART 帧 -> data/uart_measurements.csv
```

本机没有 ILA（BASIC 许可证拒绝 `create_debug_core`），因此观测手段是**配置状态寄存器 + USERCODE
读回 + 板载 LED + RTL 自带 UART + 面板可见现象**，这套证据链的用法见
[`skill/zynq_bringup_evidence_kit/`](skill/zynq_bringup_evidence_kit/SKILL.md)。

## 文档索引

| 文档 | 内容 |
|---|---|
| [`report/design_report_cn.md`](report/design_report_cn.md) | **长版中文设计报告**：原理、推导、资源时序、实测记录、AI 协作过程 |
| [`report/design_report.md`](report/design_report.md) | 设计状态台账与关键决策记录 |
| [`report/ps_development.md`](report/ps_development.md) | PS7 配置、帧格式、AXI GPIO 契约、构建与仿真结果 |
| [`report/linux_port_plan.md`](report/linux_port_plan.md) | Linux 路线、用户态 `hub75d`、已知问题与结论 |
| [`report/hub75_panel_reference_cn.md`](report/hub75_panel_reference_cn.md) | HUB75 面板时序与接线参考 |
| [`report/ir_development_and_test.md`](report/ir_development_and_test.md) | 红外子系统开发与测试记录 |
| [`report/ai_collaboration.md`](report/ai_collaboration.md) | 大模型协作记录（摘要）：提示词、工具失败与纠正 |
| [`report/ai_sessions/README.md`](report/ai_sessions/README.md) | **大模型协作原始记录**：15 个会话 / 468 条提示词（脱敏版），含合并索引与提示词汇编 |
| [`report/handover.md`](report/handover.md) | 交接文档：项目状态、已确认事实、13 条已验证的工具结论 |
| [`sw/PS_DEVELOPER_GUIDE.md`](sw/PS_DEVELOPER_GUIDE.md) | PS 侧开发指南（渲染、提交、寄存器映射） |
| [`board/board_test_procedure.md`](board/board_test_procedure.md) | 上板测试流程与期望现象 |
| [`skill/`](skill/README.md) | 4 个可复用技能包 |

## 技能包

本项目把踩过的坑提炼成 4 个技能包（结构统一：适用范围 / 步骤 / 失败模式表 / 验证证据 / 边界）：

| 技能包 | 一句话 |
|---|---|
| [`vivado_batch_build`](skill/vivado_batch_build/SKILL.md) | 无 GUI 的批处理构建与回归；`Spawn failed` 时改绝对路径调 `xvlog/xelab/xsim` |
| [`zynq_ps7_axi3_hp0`](skill/zynq_ps7_axi3_hp0/SKILL.md) | HP0 是 AXI3、`aux_reset_in` 默认低有效、HP 口非一致——三个坑三种症状 |
| [`vitis_2026_headless_sd_boot`](skill/vitis_2026_headless_sd_boot/SKILL.md) | 无 XSCT 的 Vitis 脚本化；中文 Windows 的 UTF-8 崩溃；BOOT.BIN 合成与启动模式 |
| [`zynq_bringup_evidence_kit`](skill/zynq_bringup_evidence_kit/SKILL.md) | 没有 ILA 时，用 DONE/EOS + USERCODE 读回 + LED/UART 证明"跑的是这一版" |

## 已知限制

- **无 ILA**：BASIC 许可证下 `create_debug_core` 不可用，内部波形无法抓取。
- **板级时序未测**：19 个 HUB75 输出没有 `set_output_delay`，线缆与驱动器时序未用示波器测量。
- **顶部 row31 残影**：疑似面板首行导光行为；PL 已对 `row_addr=0` 保持 OE 关闭，接缝行会空一行。
- **未实现**：半周镜像复用（400 片存储）、零度缺片补偿、无线投屏；均在路线图内，不在当前镜像里。

## 许可证

MIT，见 [`LICENSE`](LICENSE)。
