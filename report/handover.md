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
| 实现方式 | 纯 Verilog RTL（PL）；PS/Vitis 尚未开始 |
| 许可证 | MIT（`LICENSE`，版权人待团队确认） |
| 目标 | 旋转体积显示：128×64 HUB75 作为旋转扫描平面，红外每圈对齐 |

**根本架构边界（不可违反）**：PL 拥有完整显示体系（红外捕获、周期估算、切片调度、DDR 读取、BRAM 乒乓、HUB75 全部时序、帧切换）。PS/Linux 只渲染 DDR 中的下一帧并提交。Linux 不在实时扫描路径上。

---

## 2. 当前状态一句话

**红外消抖与"一次照射一个触发"已在真板实测通过（T004）；红外周期驱动的切片调度（闭环）已实现并通过仿真与构建，等待上板做锁角验证。**

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
| DDR AXI 读取 / 整片 BRAM 乒乓 | ❌ 未开始 |
| PS 渲染与帧提交、Vitis | ❌ 未开始 |
| 加速补显（零度缺片） | ❌ 未开始，用户要求后续考虑 |

---

## 6. 下一步推荐顺序

1. **先解决半屏列错位**：下载当前诊断构建（`PATTERN_MODE=2`，15:14 生成，959 LUT / WNS +6.722 ns），按 `board_test_procedure.md` 的判读表回报：颜色↔半屏对应、偏移方向与像素数、是否镜像、接缝处是否有行台阶。测得 N 后只改 `RGB2_COLUMN_OFFSET` 重建。
2. **恢复闭环图案**：把 `build_board_test.tcl` 的 `PATTERN_MODE` 改回 `1` 重建，重跑锁角判据并**按定量记录**（转速、锚点方位、漂移片数）填 `data/board_test_log.csv` 的 T005。
3. 若锁角定量成立，下一步接 DDR + 整片 BRAM 乒乓；若漂移超判据，先按判读表定位（周期估计/消抖/截断/亮度）。
4. 之后做 PS 渲染与帧提交，最后考虑加速补显。

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
| `sim/run_regression.tcl` | 一条命令跑 5 个 testbench；读 `simulate.log` 判定，`$fatal` 不再被忽略 |
| `build/build_board_test.tcl` | 独立构建 + 报告 + bitstream（**含 USERID 0x48554237**） |
| `build/program_board.tcl` | JTAG 下载，用 DONE/EOS 判据（非 IS_PROGRAMMED） |
| `build/verify_bitstream.tcl` | 读 `REGISTER.USERCODE` 自证构建来源 |
| `build/probe_hw.tcl` | 只读枚举 JTAG 链 |
| `build/capture_uart.ps1` | 解析串口帧 → `data/uart_measurements.csv` + `uart_raw.log` |
| `build/check_scripts.tcl` | 无硬件时的脚本语法自检 |
| `build/vivado.ps1` | 自动定位 Vivado 并跑任意 Tcl（`vivado` 不在 PATH 时用这个） |
| `AGENTS.md`（上一级目录） | 架构总纲与工程约束 |

**注意**：`AGENTS.md` 位于仓库**上一级** `E:\0Files_Bin\EE\vivado\AGENTS.md`，所以 `report/` 内引用它要用 `../../AGENTS.md`。

---

## 9. 已验证的工具结论（换板/换题也能复用）

1. **Vivado 2026.1 没有 `PROGRAM.IS_PROGRAMMED` 属性**，对 `arm_dap_0` 或 `xc7z020_1` 读取都会抛 `Labtoolstcl 44-56`。正确判据是 `REGISTER.CONFIG_STATUS.BIT14_DONE_PIN` / `BIT04_EOS`。需要用 `catch` 保护属性读取，否则会中断整条设备枚举循环。
2. Zynq-7000 的 JTAG 链同时暴露 `arm_dap_0`（PS 调试）和 `xc7z020_1`（PL），遍历时必须按 PART 过滤。
3. **BASIC 许可证不支持 `create_debug_core`**（ILA/VIO 均不可用），只能用 LED、UART、USERCODE 读回和离线报告。
4. `BITSTREAM.CONFIG.USERID` 可为 bitstream 写入唯一标识，配合 `REGISTER.USERCODE` 读回，在无 ILA 条件下客观证明"板上跑的是哪次构建"——本项目已用 `0x48554237`。
5. `Move-Item` 到尚不存在的父目录会报 `DirectoryNotFoundException`；批量移动脚本必须先 `New-Item -ItemType Directory`。

以上均为本次真实踩坑，可作为 `skill/` 候选条目，但按团队决定，技能包仍在项目完成后统一提炼。
