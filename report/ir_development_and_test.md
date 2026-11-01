# 第一阶段：红外捕获与周期估算

## 当前范围

已新增 [ir_revolution_sync.v](<../src/ir_revolution_sync.v>)、[hub75_sched.v](<../src/hub75_sched.v>)，并在 [hub75_top.v](<../src/hub75_top.v>) 串联实例化。**红外周期现在真正驱动扫描节奏**：每次触发把调度器拉回第 0 片，每圈固定 64 片、每片 32 个行地址。DDR AXI 读取、打包解包、整片 BRAM 乒乓缓存和加速补显仍未实现，图案由 PL 内部按切片序号生成。

## 接线

根据 [Microphase Mizar-Z7 官方手册 GPIO 表](https://fpga-docs.microphase.cn/en/latest/DEV_BOARD/MIZAR-Z7/MIZAR-Z7_Reference_Manual.html#gpio)：GPIO1_14P = JP1 第 33 脚 = FPGA U13。该脚未与现有 HUB75 输出冲突，已加入 [板级约束](<../board/constraints/hub75_mizar_z7.xdc>)。P/N 命名不妨碍 P 脚作为普通单端输入，不使用 IBUFDS。

用户此前称 MIZAR R7，已有工程/约束为 Mizar-Z7；必须确认实物型号/版本与上述接口表一致后再接线。约束按默认 3.3 V IO 电源设置 LVCMOS33；若板上电源配置不同，必须重新核对。

- 红外数字输出接 JP1-33，传感器地与板地共地。
- 不得直接接 5 V 推挽输出；先电平转换。开漏输出上拉到对应 IO 电源。
- 不默认开启内部上拉；外部传感器必须提供确定的闲置电平。
- 当前按用户要求默认上升沿触发：顶层 IR_FALLING_EDGE=0，独立模块 FALLING_EDGE=0；后期改为 1 即下降沿。此为综合参数，修改后需重新生成 bitstream，不是运行时寄存器。
- 0 V / 3.3 V 数字输出可以直接采样。RTL 不能将普通 LVCMOS33 输入阈值设置为精确 1.65 V；高低电平范围由芯片 IO 规范决定，无需 ADC。脉冲宽度必须大于下面的 1 ms 消抖窗口，否则整段照射会被判为无效。

## 模块接口

- 两级同步触发器带 ASYNC_REG/SHREG_EXTRACT 属性；同步后经消抖与闭锁窗口，再判定边沿，产生单周期 revolution_start。禁止把它当时钟或异步复位。
- 第一次触发只记录基准。每个后续触发产生 last_interval_ticks；环形窗口最多保存最近五个完整间隔。
- 收齐五个间隔（六次触发）后 period_valid=1。每次捕获后一个时钟发布 period_ticks，等于最近五个间隔和除以 5，向下取整；period_update 同时脉冲。
- 未收齐时 period_valid=0，period_ticks 保持零。此为测量接口语义，不决定显示系统启动/消隐行为；后者仍待定。
- 默认 32 位时钟计数，50 MHz 下单个间隔必须小于约 85.9 秒。计数器正常回绕由无符号模减处理，不增加漏触发或超时恢复。
- 每次触发均立即产生重启事件，即使周期估计尚未有效；消费者若需采用新平均值，要注意其晚一个时钟发布。
- 没有离群剔除、漏触发恢复或自适应滤波；只有下面固定参数的 1 ms 消抖。

## 输入消抖（1 ms）

### 问题来源

实机观察：**传感器被照射一次会产生多个上升沿**。若直接进计数器，一个物理圈会被记成多圈，五次均值会被压成一个错误的小周期。因此在同步之后、边沿判定之前必须加固定窗口的输入调理。

### 两级固定窗口

链路：`2 级同步触发器 → 消抖 → 闭锁 → 边沿选择`。

| 参数 | 默认值 | 50 MHz 下的时间 | 作用 |
|---|---|---|---|
| `DEBOUNCE_CYCLES` | 50000 | 1 ms | 同步后的电平必须连续保持新值这么久，变化才被接受；更窄的毛刺与抖动整段丢弃 |
| `HOLDOFF_CYCLES` | 50000 | 1 ms | 一次变化被接受后，闭锁窗口内完全忽略输入，窗口结束静默跟随当前电平（不再产生边沿） |

两者**串联**而不是二选一：

- 抖动只出现在脉冲边沿（常见情况）→ 消抖窗口单独就够，输出一个干净边沿。
- 抖动持续超过 1 ms、分散在整段照射里 → 闭锁窗口保证额外边沿被吞掉。
- 例外：如果电平在任何 1 ms 区间内都稳不住，消抖窗口会把整段照射判为无效（不触发）。此时把 `DEBOUNCE_CYCLES` 降到约 100 µs（`IR_DEBOUNCE_US=100`）并把 `IR_HOLDOFF_US` 保持 1000，即“短毛刺滤除 + 1 ms 闭锁”。

### 关键性质

- **周期测量不受消抖延迟影响**：时间戳取的是**边沿被接受时的候选边沿时刻**（电平第一次不一致的那个时钟），不是接受动作发生的时刻，所以 `last_interval_ticks` / `period_ticks` 与滤波窗口长短无关。仿真已用 7 次等间隔照射验证均值仍为精确真值。
- **接受脉冲本身滞后约 1 ms**：`revolution_start` 在消抖窗口结束后才发出，对 1800 RPM 是约 **10.8°** 的固定角度偏移。它是常量，不造成抖动；将来做闭环时用一个相位补偿常数标定掉，不在本级加逻辑。
- **脉冲宽度下限**：1800 RPM 下 1 ms 对应 10.8° 弧长。若反射靶/光斑的角宽小于约 11°，照射脉冲本身就窄于消抖窗口，会被判无效。上板时若 LED 不闪、UART 无数据，先按这条排查，再决定加宽靶标或缩短消抖窗口。
- **上电复位不产生假触发**：复位释放后先静默对齐到真实空闲电平（`seeded`），即使复位期间输入已处于有效电平，也不会造出一个 `revolution_start`。
- **可观测性**：模块同时输出 `ir_raw_level`（同步后、滤波前的原始电平）和 `ir_level`（滤波后被接受的电平）。板上 D6 接的是**原始电平**，这样“传感器没接好”与“消抖把脉冲吞掉”能区分开；`ir_level` 保留在 RTL 内部。
- 两个窗口都是**综合参数**，改后必须重新生成 bitstream，不是运行时寄存器。

### 上板验证判据（无需示波器）

`period_valid`（D8）只在收满五个完整间隔（六次有效触发）后点亮，所以“遮挡多少次才点亮 D8”就是被接受的触发计数：复位后第 1–5 次遮挡 D8 必须保持灭，第 6 次才亮。任一现象偏离即按 [上板测试步骤](<../board/board_test_procedure.md>) 的判读表调整窗口参数。

**实测已通过（T004）**：第 1–5 次遮挡 D8 保持灭、第 6 次点亮，D6 全程跟随手部动作。同一次下载也证明带 USERID 的 bitstream 能正常配置，T002 记的 `DONE=0` 与 USERID 属性无关。

## 闭环：周期驱动切片调度

### 模块与职责

```
period_ticks / period_valid / revolution_start
        |
        v
   hub75_sched  ──> slice_index[5:0]、row_ticks[15:0]、slot_start
        |
        v
   hub75_scan（一次只画一片：128 像素时钟 × 32 个行地址）
```

- **所有除法都是移位**：`slot_cycles = period >> SLOT_LOG2`，`row_ticks = slot_cycles >> ROW_LOG2`。无除法器。
- **周期在触发时刻锁存**，一圈之内不再变化，因此扫描时序不会在转动中途被改写。
- **每次触发立刻拉回第 0 片**并给出一个 slot 边界；扫描器若正在移行，会在下一个行边界刹车，最坏延迟一行（1800 RPM 下约 0.18°）。
- **`period_valid=0` 时回落到 1800 RPM 等效周期**（1,666,667 拍），静止也能正常出图；这不是漏触发恢复逻辑，只是测量未就绪时的固定节拍。
- **超速是唯一降级**：`row_ticks` 被 `MIN_ROW_TICKS=700` 夹住时，每片最后几行会被提前打断；1800 RPM 下每行 813 拍，尚有余量。

### 运行点

| 量 | 1800 RPM 时 | 说明 |
|---|---|---|
| 每圈周期 | 1,666,667 拍 | 五次间隔均值 |
| 每片（全屏扫描） | 26,041 拍 | `1,666,667 >> 6` |
| 每行地址 | 813 拍 | `26,041 >> 5` |
| 全屏扫描率 | 1920 片/秒 | 低于 2280 上限 |
| 像素时钟 | 10 MHz | `PIXEL_HALF_DIV=2` |
| OE 占空比 | 约 2.6% | 643 拍移位开销固定，转速越高占空比越低 |

### 延迟补偿

消抖使 `revolution_start` 比物理边沿晚约 1 ms，1800 RPM 下约 **10.8° 固定相位偏移**。它是常量，不影响锁定（只影响角度零点），等面板装到转子上后一次性标定，本阶段不加补偿逻辑。

顶层测量结果保留 MARK_DEBUG，但 BASIC 许可证拒绝 ILA 插入，因此当前通过板载 LED 与外接 USB-TTL 串口观测，无 ltx 文件。已生成完成布局布线的上板测试 bitstream，操作和最终报告边界见 [上板测试步骤](<../board/board_test_procedure.md>)。50 MHz 下，1800 RPM 约对应 1,666,667 个时钟计数/圈。

## 仿真和综合

历史 XSim 与独立综合在本机 Vivado 2026.1 执行：

- [红外测量测试](<../sim/tb_ir_revolution_sync.v>)：五间隔预热、滑动窗口替换、计数器回绕、求和、复位和两种边沿，PASS。
- [消抖测试](<../sim/tb_ir_debounce.v>)：边沿抖动串、脉冲中短跌落、窄脉冲拒绝、七次等间隔照射的周期精度、闭锁窗口吞并、复位静默对齐，PASS。
- [调度器测试](<../sim/tb_hub75_sched.v>)：64 片/圈、触发锚定第 0 片、周期锁存、零周期回落、`MIN/MAX_ROW_TICKS` 夹紧，PASS。
- [扫描测试](<../sim/tb_hub75_scan.v>)：32 地址、每地址 128 CLK、RGB 建立时间、片间空闲，以及提前到达的 slot_start 会回到第 0 行，PASS。
- [UART 测试](<../sim/tb_ir_debug_uart.v>)：115200 8N1 数据包解码，PASS。
- 独立 IR 预布线综合：657 LUT、339 FF、0 BRAM、0 DSP，estimated setup WNS +9.207 ns。迁移后已用 `build/check_ir_synthesis.tcl` 重跑，报告在 `build/reports/ir_standalone/`。
- 闭环板测构建（调度器 + 切片驱动扫描）：970 LUT、688 FF、0 BRAM、0 DSP；布线后 WNS +6.008 ns、WHS +0.130 ns，DRC 零错误但有 ZPS7-1 警告。历史版本：纯静态 809 LUT / 531 FF / WNS +6.359 ns，加消抖后 856 LUT / 600 FF / WNS +6.210 ns。报告在 `build/reports/`，旧构建归档于 `board/output/previous_build`（不纳入版本库）。

这些综合与实现数字来自本机工具，不是硬件测量。硬件观测只有 `data/board_test_log.csv` 中的目视记录（T001 静态画面、T003 多次边沿缺陷、T004 消抖通过），**锁角测试仍未做**。输出端无外部延迟模型；report_cdc 也跳过异步外部 IR 端口，这些报告不等于外部接口时序签核。

从工程根目录命令行运行完整回归：

```powershell
vivado -mode batch -source sim/run_regression.tcl
```

预期五个 testbench 均打印 PASS，并最终输出 `REGRESSION_COMPLETE`。脚本会读取每个 testbench 的 `simulate.log`：没有 PASS 行或出现 `Fatal:`/`Error:` 就以非零码失败退出——`run all` 静默返回不算通过（曾因此漏掉一次调度器断言失败）。仿真工程和日志写入 `sim/output/regression/`。

重新生成独立 IR 模块综合报告：

```powershell
vivado -mode batch -source build/check_ir_synthesis.tcl
```

输出在 `build/reports/ir_standalone/`。

重新生成上板 bitstream 与完整报告：

```powershell
vivado -mode batch -source build/build_board_test.tcl
```

成功标记 `BOARD_TEST_BUILD_COMPLETE`；输出在 `board/output/` 和 `build/reports/`。工具失败时保留完整 batch log/journal，禁止只记录“成功”。

GUI 流程：打开 [Vivado 工程](<../hub75_display.xpr>)，Tcl Console 运行：

```tcl
source E:/0Files_Bin/EE/vivado/hub75_display/build/add_sources.tcl
source E:/0Files_Bin/EE/vivado/hub75_display/sim/simulate_ir.tcl
```

`simulate_ir.tcl` 会恢复原 simulation top/runtime。可复现上板步骤见 [board procedure](<../board/board_test_procedure.md>)。
