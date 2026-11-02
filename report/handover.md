# 交接文档 / Context Handover

> 用途：在上下文压缩或交接前，用一份文档承载项目状态、已验证事实、未解决问题和下一步顺序。
> 最后更新：2026-10-31（板卡已连接、首次实测通过、随后出现配置故障）

---

## 1. 项目身份

| 项 | 值 |
|---|---|
| 赛事 | 全国大学生嵌入式芯片与系统设计竞赛 2026，FPGA 创新设计赛道，自主选题赛道初级组 |
| 题目 / 应用场景 | **TBD（团队决定暂不补）** |
| 板卡 | 用户称 MIZAR R7；工程实际按 Mizar-Z7 手册与 `xc7z020clg400-2` 构建，**确切丝印版本仍未确认** |
| 工具 | Vivado 2026.1（`F:\AMDDesignTools\2026.1\Vivado`），BASIC 许可证 |
| 实现方式 | Verilog RTL（PL）+ Vitis 裸机源码（`sw/`）；PS+DDR 已上板验证（UART1/DDR/帧握手/静止动画），支持 SD 脱机启动 |
| 许可证 | MIT（`LICENSE`，版权人待团队确认） |
| 目标 | 旋转体积显示：128×64 HUB75 作为旋转扫描平面，红外每圈对齐 |

**根本架构边界（不可违反）**：PL 拥有完整显示体系（红外捕获、周期估算、切片调度、DDR 读取、BRAM 乒乓、HUB75 全部时序、帧切换）。PS/Linux 只渲染 DDR 中的下一帧并提交。Linux 不在实时扫描路径上。

---

## 2. 当前状态一句话

**红外消抖与"一次照射一个触发"已在真板实测通过（T004）；红外周期驱动的切片调度（闭环）已实现并通过仿真与构建，等待上板做锁角验证。**

**PS+DDR 增量（PS7 + AXI GPIO + S_AXI_HP0 + DDR reader + slice RAM）已上板验证：UART1 控制台、DDR PASS、约 20 fps 静止动画、`buf_ready=1`，并支持 SD 脱机启动（BOOT.BIN = FSBL + bitstream + ELF）。两球旋转体已上板显示（64 slice、左红右绿），用户目视效果正常；上半球/下半球数据和普通半屏行映射经“上绿下红”颜色诊断确认。默认 app 已升级为 **3D 心形**（红色主体、洋红顶叶、薄白边；两球体保留为 `HUB75_HEART_TEST=0` 回退）。PL 对 `row_addr=0` 保持 OE 关闭，但用户在板上反馈顶部 row31 ghost 仍未消除，疑似面板首行硬件/导光行为，暂不阻塞。新 bitstream/app 已构建（WNS +6.538、WHS +0.056、DRC 0）并 JTAG 加载，COM11 显示 `render 3D heart ...`、`id 1`；`BOOT.BIN` 4,195,624 B。心形上板视觉 TBD。**

**Linux 阶段（新）：目标、路线、接口、风险见 `report/linux_port_plan.md`。**
2026-11-04 更新：厂商 PetaLinux 2018.3 + 我们的 FSBL/HP0 bitstream（reader ARCACHE=4bx0010）已跑通；
用户态 `hub75d`（PTY 16x4 + 8x16 字库 + VT100 解析）把 shell 文字实时显示在旋转屏上，
用户确认可见 `~#` 与刷新。此前所有“卡死/重启”的最终根因是**供电跌落触发 POR**（换电池后全部正常），
不是看门狗/总线；Vitis 静态 glibc 的 time64 系统调用在 4.14 上返回 ENOSYS（改用全局定时器 + poll）。
完整结论与下一步见 `report/linux_port_plan.md` §14。本机 Windows 10 无 WSL/PetaLinux；原 SD 卡有厂商 Linux 备份（`build/work/sd_backup/BOOT.bin.original` + 卡上 image.ub/rootfs）。Linux 基础路线待选：PetaLinux 2026.1 + WSL2（开源/资料完整，推荐）、原厂镜像 + 用户态 hub75d（最快）、PYNQ/Ubuntu（板级兼容待试）、Buildroot/mainline（全开源、工作量最大）。**

---

## 3. 已确认的实测事实（来自真实板卡，非仿真）

| 时间 | 事实 |
|---|---|
| 2026-10-31 | JTAG 链路可枚举：`localhost:3121/xilinx_tcf/Digilent/210241754739`，含 `arm_dap_0` + `xc7z020_1`（IDCODE `00100011011100100111000010010011`） |
| 2026-10-31 | 下载旧 bitstream 后 `DONE=1`、`EOS=1`、`GWE=1` |
| 2026-10-31 | **用户目视确认：HUB75 彩条清晰、"2280" 数字可辨认** → 32 个行地址、128×32 像素时钟、CLK/LAT/OE、双组 RGB 接线与时序全部正常（T001） |
| 2026-10-31 | 带 USERID 的消抖版 bitstream **能正常配置并运行**，因此 T002 的 `DONE=0` 与 USERID 属性无关，失败为偶发/环境因素 |
| 2026-10-31 | **消抖实测通过（T004）**：复位后连续 6 次单独遮挡，D8 前 5 次保持灭、第 6 次点亮；D6 全程跟随遮挡动作 |

这些是本项目仅有的硬件证据，其余全部是仿真/工具结果。

---

## 4. 当前未解决问题（交接重点）

### 4.1 已关闭：PL 未配置 / `DONE=0`

2026-10-31 曾出现 3 次下载中第 3 次失败（`ERROR: [Labtools 27-3165] End of startup status: LOW`，读回 `USERCODE=ffffffff DONE=0`）。后续同一份含 `USERID=0x48554237` 的 bitstream 下载成功并正常工作，**该故障已排除，原因是偶发/环境，不是 USERID 属性**。A/B 对照不再需要；T002 行已标注 SUPERSEDED。

### 4.2 其他待办

- **上板新发现：两条 RGB 总线对应的半屏在列方向错位**。用户报告"红线在上下半屏对不齐"，但无法判断谁在前谁在后。已加 `PATTERN_MODE=2` 诊断图案（rgb1 红、rgb2 绿、两边同列同图），并把坐标约定写进 `board_test_procedure.md`；需要用户回报颜色-半屏对应、偏移方向和像素数、是否镜像。`RGB2_COLUMN_OFFSET` 参数已就位，测得 N 后改一个参数重建即可，不必改逻辑。
- **锁角测试**：用户已报告"同步和周期校准正常、锚点不随转速漂移"（口述），但未按判据记录转速/漂移量，定量部分仍 TBD
- 串口不可用：系统里只有蓝牙 `COM5/COM6`，板载 CH340 与外部 USB-TTL 都未枚举 → 周期数值仍为 TBD，闭环只能目视判读
- 红外极性、JP1-33/U13 的实际对应关系未用示波器确认
- HUB75 外部时序（线缆、驱动器、建立/保持）未测量；19 个输出无 output delay 约束
- 消抖造成约 1 ms 固定相位偏移（1800 RPM 约 10.8°），等面板上转子后一次性标定

---

## 5. 功能进度

| 模块 | 状态 |
|---|---|
| 静态 HUB75 扫描（1/32，128×64） | ✅ 实机确认显示正常 |
| 21 档扫频 | 🗑 已按用户要求移除，改为单一 `FIELD_HZ=2280` |
| RGB/CLK 同沿建立时间缺陷 | ✅ 已修（新增 `S_PIXEL_SETUP` 状态） |
| 速率索引位宽 bug（4→5 bit） | ✅ 已修 |
| 红外双级同步 + 边沿选择 + 五间隔滑动平均 | ✅ 仿真通过，已接入扫描调度 |
| 红外输入消抖 1 ms + 闭锁 1 ms | ✅ 仿真通过 + **实机通过（T004）** |
| LED / UART 诊断 | ✅ 仿真通过；D6/D8 实测符合预期 |
| **红外 → 扫描节奏闭环** | ✅ 已实现（`hub75_sched` + 切片驱动扫描），仿真与构建通过；**用户在机上报告锚点不漂（口述）** |
| 半屏列对齐（rgb1/rgb2） | ⚠️ 发现错位，原因未定；已有 `PATTERN_MODE=2` 诊断图案与 `RGB2_COLUMN_OFFSET` 修正参数，等实测数据 |
| DDR AXI 读取 / 整片 BRAM 乒乓 | ✅ RTL 仿真（`tb_hub75_ddr_reader`）+ 构建通过；上板 TBD |
| PS 渲染与帧提交、Vitis | ✅ 上板验证：UART1 COM11、DDR PASS、帧握手、20 fps 静止动画；两球体已上板；默认 3D 心形与顶部 row0 OE blank 新构建，上板 TBD |
| PS7 / UART1 / DDR 基线 / SD 启动 | ✅ 上板验证；SD 脱机启动（BOOT.BIN）已跑通 |
| 加速补显（零度缺片） | ❌ 未开始，用户要求后续考虑 |

---

## 6. 下一步推荐顺序

1. **3D 心形已实现，等待上板**：`HUB75_HEART_TEST=1` 默认 3D 心形（红色主体、洋红顶叶、薄白边），两球体为 `HUB75_HEART_TEST=0` 回退；静态帧只提交一次。PL 已对 `row_addr=0` 保持 OE 关闭，消除顶部 row31 ghost（接缝行会空掉一行）。新 bitstream/app/BOOT.BIN 构建后上板确认心形和顶部条纹；继续记录 `period`、20~30 rev/s 下的 3D 效果和面板照片/视频。
2. **记录 PS 实测**：DDR memtest、实际 DDR 频率、UART 日志、status（ack/busy/slice/frame_id）、面板照片；确认 `frame_done` 后 A/B 复用无撕裂。通过后再把 DDR 400→533.333 复测。
3. **半屏列错位/锁角**：PS 红/蓝测试图可直接判读 rgb1/rgb2 半屏对应与列偏移；测得后改渲染端的 upper/lower 或列预移。锁角定量仍按 `board_test_procedure.md` 的判据记录。
4. 400 片容量、76 片/圈、后半圈镜像复用、加速补显留到基线稳定之后。
5. **Linux 评估**：若改用 Linux，先解决帧缓冲预留（0x10000000/0x10200000 起 4 MiB）、HP0 非一致性的 cache flush/uncached 映射、AXI GPIO mmap/UIO；显示实时性仍由 PL 保证。

---

## 7. 不可违反的约定

- 五次触发间隔平均；每次触发立即重置到第 0 片；**不加**离群剔除、漏触发恢复、自适应滤波、加速补显（除用户明确要求）
- 红外输入只做固定 1 ms 消抖 + 1 ms 闭锁（用户明确要求的唯一例外），不得改成自适应或统计滤波
- 不用异步红外边沿直接产生 HUB75 时钟；必须同步后在稳定时钟域处理
- 帧切换只在红外重启边界原子生效；一圈内不改基址
- 未实测数据一律标 **TBD**，不得用估算值冒充实测
- 文件名只用小写字母/数字/下划线/连字符；中文只在正文

---

## 8. 关键文件与脚本

| 路径 | 作用 |
|---|---|
| `src/hub75_top.v` | 顶层：复位同步、红外实例、调度器实例、LED/UART 诊断、切片驱动扫描实例 |
| `src/hub75_sched.v` | 周期 → 64 片/圈 + 每行预算；触发回第 0 片；`period_valid=0` 回落 1800 RPM；除法全用移位；`CHECK_PARAMS` 仅供单元测试关闭参数检查 |
| `src/hub75_scan.v` | 单片刻波形引擎：`row_ticks` + `slot_start` + `slice_index` 驱动，含 `PATTERN_MODE` 图案与字体 |
| `src/ir_revolution_sync.v` | 红外同步 + 1 ms 消抖 + 1 ms 闭锁 + 五间隔平均（`FALLING_EDGE`、`DEBOUNCE_CYCLES`、`HOLDOFF_CYCLES`）；输出 `ir_raw_level`（滤波前）与 `ir_level`（滤波后） |
| `src/ir_debug_uart.v` | 115200 8N1，10 字节包：`55 AA` + 间隔 LE32 + 均值 LE32 |
| `sim/tb_ir_debounce.v` | 消抖专项：抖动串、脉冲内跌落、窄脉冲拒绝、周期精度、闭锁、复位静默对齐 |
| `sim/tb_hub75_sched.v` | 调度器：64 片/圈、触发锚定、周期锁存、零周期回落、MIN/MAX 夹紧 |
| `src/hub75_ps_top.v` | PS 版顶层：`hub75_scan`/`hub75_sched`/IR/UART + `pix_data`/`pix_addr` + 调度观测输出；`PATTERN_MODE=3` |
| `src/hub75_ddr_reader.v` | PL AXI3 读 master：16-beat × 24 突发/片，6-bit 解包，乒乓 buffer tag/epoch，帧基址在 `revolution_start` 锁存 |
| `src/hub75_slice_ram.v` | 2 × 4096×6 bit BRAM36 乒乓；一写一读，读缓冲由 reader 的 `rd_buf` 选择 |
| `src/hub75_system.v` | 组合 `hub75_ps_top` + reader + slice RAM；打包 status/period；AXI 读端口 |
| `src/system_top.v` | 顶层：`design_1_wrapper` + `hub75_system`；DDR/FIXED_IO 直通；写通道 tie-off |
| `sim/tb_hub75_scan_mem.v` | PATTERN_MODE=3 像素顺序、6-bit 分组、行递增检查 |
| `sim/tb_hub75_ddr_reader.v` | 行为 AXI3 slave + 6-bit 打包数据；检查两片 4096 字写入 |
| `sim/run_regression.tcl` | 一条命令跑 7 个 testbench；用绝对路径直接调 `xvlog/xelab/xsim.bat`，读 transcript 判定 |
| `build/build_board_test.tcl` | PL-only 独立构建 + 报告 + bitstream（**含 USERID 0x48554237**） |
| `build/create_ps_bd.tcl` | PS7 BD：UART0+UART1、DDR/FCLK、AXI GPIO/HP0、SD0 MIO40..45、proc_sys_reset；Stage 0 只 PS7 |
| `build/build_sd_boot.py` / `run_build_sd_boot.bat` | Vitis Python：platform + FSBL + app + bootgen → `BOOT.BIN`（中文 Windows 需批处理里的 UTF-8 设置） |
| `build/copy_boot_to_sd.ps1` | 只向 FAT32 可移动盘根目录写 `BOOT.BIN` |
| `build/build_ps_system.tcl` | Stage 0/1 PS 系统构建 + 报告 + bit/XSA（`-TclArgs 1` 为 Stage 1） |
| `board/constraints/hub75_ps.xdc` | PS 版 PL 引脚；无 H16 时钟，FCLK 由 PS7 提供 |
| `sw/README.md` | Vitis 2026.1 GUI 建 platform/app、JTAG Run Configuration、故障表 |
| `sw/PS_DEVELOPER_GUIDE.md` | PS 控制接口、帧格式、submit/frame_done 协议、静止/旋转渲染、SD 脱机启动 |
| `report/ps_development.md` | PS7 配置、帧格式、AXI GPIO 契约、构建/仿真结果、TBD |
| `build/program_board.tcl` | JTAG 下载，用 DONE/EOS 判据（非 IS_PROGRAMMED） |
| `build/verify_bitstream.tcl` | 读 `REGISTER.USERCODE` 自证构建来源 |
| `build/probe_hw.tcl` | 只读枚举 JTAG 链 |
| `build/capture_uart.ps1` | 解析串口帧 → `data/uart_measurements.csv` + `uart_raw.log` |
| `build/check_scripts.tcl` | 无硬件时的脚本语法自检 |
| `build/vivado.ps1` | 自动定位 Vivado 并跑任意 Tcl（`vivado` 不在 PATH 时用这个） |
| `AGENTS.md`（上一级目录） | 架构总纲与工程约束 |

**注意**：旧文档引用的 `E:\0Files_Bin\EE\vivado\AGENTS.md` 在本机**不存在**（`E:\0Files_Bin` 整个目录都没有）；本仓库的约束以 `report/` 内文档为准。`build/vivado.ps1` 已改为能匹配本机的 `E:\AMD\2026.1\Vivado\bin`。

---

## 9. 已验证的工具结论（换板/换题也能复用）

1. **Vivado 2026.1 没有 `PROGRAM.IS_PROGRAMMED` 属性**，对 `arm_dap_0` 或 `xc7z020_1` 读取都会抛 `Labtoolstcl 44-56`。正确判据是 `REGISTER.CONFIG_STATUS.BIT14_DONE_PIN` / `BIT04_EOS`。需要用 `catch` 保护属性读取，否则会中断整条设备枚举循环。
2. Zynq-7000 的 JTAG 链同时暴露 `arm_dap_0`（PS 调试）和 `xc7z020_1`（PL），遍历时必须按 PART 过滤。
3. **BASIC 许可证不支持 `create_debug_core`**（ILA/VIO 均不可用），只能用 LED、UART、USERCODE 读回和离线报告。
4. `BITSTREAM.CONFIG.USERID` 可为 bitstream 写入唯一标识，配合 `REGISTER.USERCODE` 读回，在无 ILA 条件下客观证明"板上跑的是哪次构建"——本项目已用 `0x48554237`。
5. `Move-Item` 到尚不存在的父目录会报 `DirectoryNotFoundException`；批量移动脚本必须先 `New-Item -ItemType Directory`。
6. **Vitis 2026.1 禁用了 XSCT**：`xsct -eval ...` 直接报 `XSCT is disabled in Vitis 2026.1 release`；脚本化要用 Vitis Python Console/API，或直接用 GUI。
7. **Vitis Python API 在中文 Windows 上会在 `vitis.create_client()` 报 UTF-8 解码错误**（`'utf-8' codec can't decode byte 0xd5`）：client 按 UTF-8 读本机子进程输出。解决办法是在批处理里先 `chcp 65001` 并设 `PYTHONUTF8=1`、`PYTHONIOENCODING=utf-8`；`build/run_build_sd_boot.bat` 已验证可完整建 platform/FSBL/app 并生成 BOOT.BIN。
8. **Vivado 2026.1 的 `launch_simulation` 可能报 `Common 17-180 Spawn failed`**：生成的 `compile.bat` 调 `xvlog` 时子进程 PATH 找不到 Vivado bin。`build/vivado.ps1` 加 PATH 仍不够；`sim/run_regression.tcl` 改为用绝对路径直接 `xvlog/xelab/xsim.bat`，绕开 `launch_simulation`。
9. Zynq PS7 的 `S_AXI_HP0` 是 **AXI3**；BD 里 `create_bd_intf_port` 的 `aximm_rtl` 默认 AXI4，直接连会报协议不兼容。必须设 `CONFIG.PROTOCOL {AXI3}`、`FREQ_HZ 50000000`、64-bit data、6-bit ID，且 `ARLEN` 最大 16 beats。
10. `proc_sys_reset` 的 `ext_reset_in` 是**高有效**，且 `C_EXT_RESET_HIGH` 在 BD 里只读；把 `FCLK_RESET0_N` 经 `util_vector_logic` 反相后再接，AXI 复位才正确。**注意 `aux_reset_in` 默认是低有效（`C_AUX_RESET_HIGH=0`）**：接常量 0 会让 `peripheral_aresetn` 永远为低，A9 首次访问 AXI GPIO 就挂死（本次已修：置 `C_AUX_RESET_HIGH=1`，再与 `mb_debug_sys_rst` 一起接 0）。
11. **板载 CP2102 实际接 UART1 的 MIO48(TX)/MIO49(RX)**，不是手册/旧文档写的 UART0 MIO14/15（实测 UART0 收发均无数据，UART1 强制发送 CP2102 完整收到）。需要 MIO48/49 的 L3_SEL=7、`UART_CLK_CTRL` 的 CLKACT1、`APER_CLK_CTRL[21]` 和 UART1 @0xE0001000；`hub75_renderer/main.c` 的 `console_init()` 已全部处理。BD 现在同时启用 UART0 和 UART1。
12. `write_hw_platform -include_bit` 需要 `impl_1` run 已跑到 write_bitstream；本工程的显式 opt/place/route 流程下会报 “Unable to get BIT file”。当前导出 XSA 不带 bitstream，Vitis Run Configuration 里单独选 `.bit`；若要走 run 流程，用 `launch_runs impl_1 -to_step write_bitstream` 再导出。
13. **SD 脱机启动**：SD0 固定在 MIO40..45（Zynq BootROM 的 SD 映射；SD1 会与 UART1 MIO48/49 冲突），CD/WP/POW 可不接。`build/run_build_sd_boot.bat` 生成 `BOOT.BIN`（FSBL + bitstream + ELF）；卡需 MBR + FAT/FAT32，`BOOT.BIN` 在根目录；SW4 拨到 SD 行并**断电上电**（boot mode 在 POR 采样，按复位键不保证）。换卡前备份原 `BOOT.bin`；测试卡的原 Linux 镜像在 `build/work/sd_backup/BOOT.bin.original`。

以上均为本次真实踩坑，可作为 `skill/` 候选条目，但按团队决定，技能包仍在项目完成后统一提炼。
