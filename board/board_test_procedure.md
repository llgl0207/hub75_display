# 静态屏与红外捕获：上板测试

## 坐标约定（沟通时一律用这套说法）

姿态：把面板平放，**HUB75 排线插座所在的长边朝下**（冲着自己），发光面朝上。以下全部按这个姿态命名：

- **左 / 右**：观察者的左、右。
- **上 / 下**：远离观察者的一侧为“上”，插座所在边为“下”。
- **列 `c = 0…127`**，从**左**到右。
- **行 `r = 0…63`**，从**上**到下。
- 行地址 `n = 0…31` 在同一次扫描中同时驱动 **`r = n`** 与 **`r = n + 32`**。
- **上半屏** = `r 0…31`，**下半屏** = `r 32…63`。
- **哪条 RGB 总线驱动哪一半，不预设**：由下面的 `PATTERN_MODE=2` 红/绿颜色现场确定。

如果面板在转子上是**竖装**（或者插座在侧面），先告诉协作方，约定改成以转子轴为参考的版本，避免各自理解不同。

## 本次产物与范围

[hub75_ir_test.bit](<output/hub75_ir_test.bit>) 已由 Vivado 2026.1 完成综合、布局布线和 bitstream 生成。构建脚本为 [build_board_test.tcl](<../build/build_board_test.tcl>)，在独立目录构建，不覆盖原工程的运行结果。

- **扫描节奏由红外周期驱动**：每次触发回到第 0 片，每圈 64 片、每片 32 个行地址，全部用移位从 `period_ticks` 算出；未收齐五间隔时按 1800 RPM 等效固定节拍扫。
- 图案由 PL 按切片序号生成（`PATTERN_MODE=1`）：**第 0 片整屏白**（角度锚点），其余 63 片是一条 4 像素宽的红条，列号随切片移动。`PATTERN_MODE=0` 可回到已验证的彩条 + “2280” 参考图。
- 红外默认上升沿；通过 IR_FALLING_EDGE 参数可改下降沿，需重新构建。
- **红外输入消抖 1 ms + 闭锁 1 ms**（`IR_DEBOUNCE_US`、`IR_HOLDOFF_US`）：一次照射只应产生一个触发。两个窗口都是综合参数，改后需重新构建。
- DDR、体积帧读取、整片 BRAM 乒乓和补显尚未实现；当前图案不来自 DDR。
- BASIC 许可证拒绝 create_debug_core，未插入 ILA，无 ltx 文件；使用 LED 与自编 RTL 串口观测。

## 已完成检查

- 红外两种极性、五间隔平均、回绕及复位：XSim PASS。
- 红外消抖与闭锁：抖动串、脉冲内跌落、窄脉冲拒绝、周期精度、闭锁窗口、复位静默对齐，XSim PASS。
- 切片调度：64 片/圈、触发锚定第 0 片、周期锁存、零周期回落、MIN/MAX 行预算夹紧，XSim PASS。
- 扫描：50 MHz 下 32 个行地址、每地址 128 个 CLK，RGB 至少提前一个 PL 周期稳定，片间返回空闲，提前到达的 slot_start 回到第 0 行：PASS。
- UART：115200 8N1、10 字节数据包解码比对：PASS。
- 布线后内部建立 WNS +6.008 ns、保持 WHS +0.130 ns，无失败内部端点。
- 资源：970 LUT、688 FF、0 BRAM、0 DSP（闭环比消抖版 856/600 多 114 LUT、88 FF）。
- DRC 无错误；保留 ZPS7-1 警告（当前没有 PS7 实例）。这是 PL 独立 JTAG 测试，不是完整 Zynq 启动设计，不生成或烧写启动介质。
- 19 个输出没有外部 output delay 模型；面板连接线、驱动器及输入建立/保持尚未完成外部时序签核。不得把内部时序通过称为全部接口验证。
- report_cdc 跳过无时钟约束的传感器端口；输入采用双级同步，不把该报告视作完整 CDC 证明。

## 调试模式说明

本机 Vivado 为 **BASIC 许可证**，`create_debug_core` 被拒绝，因此**没有 ILA/VIO，也没有 .ltx**。片上观测只能靠 4 个 LED 和 RTL 手写 UART；数值验证靠 XSim 与实现报告。上板和采集已脚本化，见下节。

## 自动化流程（推荐）

插好 USB-JTAG 后，三条命令完成下载与数据采集，无需点 GUI：

```powershell
# 1. 只读确认板卡在线（不改动任何状态）
.\build\vivado.ps1 build\probe_hw.tcl

# 2. 下载 bitstream 到 PL（易失配置，不烧 Flash）
.\build\vivado.ps1 build\program_board.tcl

# 3. 读串口，自动解析成 ticks / RPM 并写入 CSV
.\build\capture_uart.ps1 -Port COM7 -Seconds 8 -Label static_ir_test
```

`build/vivado.ps1` 会自己找 Vivado（`-VivadoBin` → `$env:VIVADO_BIN` → `PATH` → `AMDDesignTools`/`Xilinx` 安装目录），**PowerShell 里 `vivado` 不在 PATH 也能直接跑**。若想用裸命令，先执行一次 `$env:Path += ';F:\AMDDesignTools\2026.1\Vivado\bin'`，或改用 `-tclargs` 传参形式：

```powershell
.\build\vivado.ps1 build\program_board.tcl -TclArgs "board/output/previous_build/hub75_ir_test.bit"
```

脚本说明：

| 脚本 | 作用 | 失败时先查 |
|---|---|---|
| `build/probe_hw.tcl` | 列出 JTAG target 与器件，只读 | USB-JTAG 线、板子供电、`hw_server` 是否被 GUI 独占 |
| `build/program_board.tcl` | 自动定位 7z020 并 program，回读 `CONFIG_STATUS` 的 DONE/EOS | 是否已关闭 GUI 的 Hardware Manager 会话 |
| `build/capture_uart.ps1` | 找 `55 AA` 帧头，解析 LE32 两字段，换算周期与 RPM | 接线、共地、波特率、是否已触发 ≥6 次 |
| `build/check_scripts.tcl` | 无硬件时自检脚本语法 | 仅语法，不代表硬件可用 |

`capture_uart.ps1` 会自动创建 `data/uart_measurements.csv`（每帧一行，含 `mean_ticks`、`period_ms`、`rpm`）和 `data/uart_raw.log`（原始十六进制）。**请勿手工填写这些数值**，它们必须来自真实采集。

## 接线与下载（GUI 手工方式）

确认实物为与 Mizar-Z7 手册相同的接口版本、XC7Z020CLG400 **-2** 器件（构建目标如此；若实际速度等级不同需重构建）。测试先保持机械静止。

1. HUB75 沿用 [现有约束](<constraints/hub75_mizar_z7.xdc>) 对应接线，屏幕独立供电并共地。
2. 红外数字输出接 **JP1 第 33 脚 GPIO1_14P/U13**，0/3.3 V 数字电平，传感器地接板地。不可接 5 V 推挽。
3. USB JTAG 接电脑。在 Vivado 选择 **Open Hardware Manager → Open Target → Auto Connect**。
4. 对 xc7z020 右键 **Program Device**，Bitstream file 选择本目录 output/hub75_ir_test.bit；若残留探针文件路径则清空。点击 Program。此步骤只写 FPGA 易失配置，不烧 Flash。
5. 若已有 PS 程序运行，确保它不会重配置 PL 或修改与本次 PL 测试相关的时钟/IO；本设计使用板载 H16 50 MHz。

## 只用 Vivado GUI 的 Tcl 控制台

不想开命令行窗口时，在 Vivado 的 Tcl Console 里直接 `source` 仓库脚本即可，脚本自己算路径：

```tcl
source E:/0Files_Bin/EE/vivado/hub75_display/board/tcl/gui_program.tcl
```

它会复用已经打开的 hardware target（没有才去 connect），下载 `board/output/hub75_ir_test.bit`，并打印 `BEFORE/AFTER done`、`eos`、`USERCODE` 与 `PROGRAM_COMPLETE`。

想分步执行就把这几个命令逐条粘进去：

```tcl
open_hw_manager
connect_hw_server -url localhost:3121 ;# 已连过可跳过
open_hw_target                          ;# 已打开会报错，可跳过
set dev [lindex [get_hw_devices xc7z020*] 0]
current_hw_device $dev
refresh_hw_device -quiet $dev

set_property PROGRAM.FILE {E:/0Files_Bin/EE/vivado/hub75_display/board/output/hub75_ir_test.bit} $dev
set_property PROBES.FILE {} $dev
set_property FULL_PROBES.FILE {} $dev
program_hw_devices $dev
refresh_hw_device -quiet $dev

puts "DONE=[get_property REGISTER.CONFIG_STATUS.BIT14_DONE_PIN $dev]"
puts "USERCODE=[get_property REGISTER.USERCODE $dev]"
```

**重建不要在这个 GUI 会话里做**：`build_board_test.tcl` 会用 `create_project -force` 新建工程，和当前打开的工程冲突。重建请在单独的命令行窗口跑 `.\build\vivado.ps1 build\build_board_test.tcl`，或者用 Tcl Console 只做下载。

## 不接串口也可做的测试

板载 LED 均为低电平点亮：

| LED | 含义 | 预期 |
|---|---|---|
| PL_LED1 / D6 | **同步后的原始红外电平**（滤波前） | 传感器有效时亮、无效时灭。它证明接线/极性/供电是否正常 |
| PL_LED2 / D7 | 每次**被接受**的触发亮约 100 ms | 一次遮挡只闪一次；连续遮挡时看起来常亮 |
| PL_LED3 / D8 | 五间隔估计有效（六次有效触发后） | 第 6 次遮挡后才亮，前 5 次必须保持灭 |
| PL_LED4 / D9 | 时钟心跳 | 约每秒闪一轮 |

按 PL_KEY1 复位后，D8 熄灭，再触发六次恢复。即使 D8 熄灭，静态屏仍扫描。

D6 特意接**滤波前**的原始电平而不是消抖后的电平：否则“传感器没接好”和“消抖把脉冲吞掉了”在 LED 上表现一样，无法区分。滤波后的电平仍在 RTL 内部（`ir_level`，带 MARK_DEBUG），需要时可把 `hub75_top.v` 里 `debug_led_n` 的 `ir_raw_level` 换成 `ir_level` 重新构建。

## 如何验证消抖（不需要示波器）

原理：`period_valid`（D8）只在收满**五个完整间隔（六次有效触发）**后才亮。因此“遮挡多少次才点亮 D8”就是“被接受了多少个触发”的计数器。这是纯计数判据，不依赖肉眼分辨 100 ms 脉冲。

1. 按 PL_KEY1 复位，确认 **D8 灭**、D9 心跳正常。
2. 手动遮挡传感器一次（约 0.3 秒），移开，等 1 秒。确认 **D6 跟随手的动作亮灭**。
3. 重复第 2 步，**每次只遮挡一次、间隔约 1 秒**，并数次数。
4. 观察 D8：**第 1–5 次必须一直是灭的，第 6 次才亮**。

| 现象 | 判读 | 处理 |
|---|---|---|
| D6 完全不动 | 输入没到 PL：接线、极性、供电、JP1-33/U13 对应关系有问题 | 先查线，再考虑改 `IR_FALLING_EDGE` |
| D6 随动作亮灭，但 D8 数到 10 次以上仍不亮 | 照射脉冲窄于 1 ms 消抖窗口，被整段判无效 | 把 `IR_DEBOUNCE_US` 降到 100，重建 |
| D8 在 6 次之前就亮 | 抖动跨度超过 1 ms 闭锁窗口，仍在重复计数 | 把 `IR_HOLDOFF_US` 调到 2000 或 3000，重建 |
| D8 正好第 6 次亮 | 消抖有效 | 记入 `data/board_test_log.csv`，可进入闭环开发 |

有示波器或逻辑分析仪时优先做仪器验证：探头接 JP1-33/U13，手动遮挡一次，确认原始波形上确实有多个边沿（复现问题），再确认 `revolution_start` 只有一次。仪器数据比 LED 计数更可靠，也才能给出真实的抖动宽度用来选参数。

## 组间对齐诊断（`PATTERN_MODE=2`）

这一版构建故意**不显示闭环图案**，而是显示一张诊断图：rgb1 那半屏画**红色**、rgb2 那半屏画**绿色**，两边画的列**完全相同**。因此在屏幕上看到的任何错位、镜像或台阶，都只能来自面板/接线本身，不可能由图案造成。

图案内容（红绿两组完全一致）：

- **梳齿**：每 16 列一条贯穿整屏的 1 像素竖线（0、16、32…112），相当于一把 16 像素的尺子。
- **细线**：第 8 列一条 1 像素竖线。
- **粗条**：第 120–124 列五条相邻竖线（宽 5 像素）。

细线与粗条分居左右两侧，**用来判断是不是镜像**；梳齿用来**读偏移量**。

| 观察结果 | 结论 | 下一步 |
|---|---|---|
| 上红下绿（或上绿下红） | 两条总线各驱动一半，符合 1/32 结构 | 记录颜色与半屏的对应关系 |
| 只有一半亮 | 另一半没数据、没供电，或地址映射不同 | 查排线与面板供电 |
| 左右各一色 | 面板是左右分半，或面板竖装 | 先修正坐标约定 |
| 接缝处梳齿完全对齐 | 两组无列偏移 | 错位另有原因，回到闭环图案复现 |
| 绿色梳齿整体比红色偏左 N 像素 | rgb2 半屏列偏移 −N | 用 `RGB2_COLUMN_OFFSET=+N` 修正 |
| 绿色梳齿整体比红色偏右 N 像素 | rgb2 半屏列偏移 +N | 用 `RGB2_COLUMN_OFFSET=−N` 修正 |
| 绿色细线跑到右侧、粗条跑到左侧 | rgb2 半屏列序**镜像** | 偏移参数修不了，需要单独的镜像开关 |
| 接缝处图案上下错开一整行或几行 | 行地址映射不同，不是列偏移 | 单独确认 A…E 地址与行的对应 |

读数以梳齿的 16 像素间距为基准，报“约多少像素、朝左还是朝右”。

改偏移后重新构建（只改一个参数，不动逻辑）：

```powershell
# 编辑 build/build_board_test.tcl 里的 RGB2_COLUMN_OFFSET=...，然后
.\build\vivado.ps1 build\build_board_test.tcl
.\build\vivado.ps1 build\program_board.tcl
```

修好后再把 `PATTERN_MODE` 改回 `1` 构建闭环图案，继续锁角测试。

## 闭环锁角测试（本版核心）

### 静态、不转

上电后屏幕应出现**持续滚动的图案**：一条 4 像素宽红条每约 33 ms 扫过全屏一次，并且每圈有一次整屏白闪。这是 1800 RPM 等效的固定节拍（1920 片/秒），不需要红外触发也应有画面。

### 单次遮挡

手在传感器前遮一下再移开：白闪应出现在遮挡的瞬间。这证明“触发 → 第 0 片立即重启”在实机成立。

### 电机旋转（关键判据）

把面板装到转子上，转速从 60 RPM 慢慢提到 300 RPM：

- 红条与白闪应始终停在**同一个机械方位**，不随转速变化而转走。
- 判据：转速变化后，白闪锚点方位漂移 **≤ 1 片（5.6°）**。
- 第 6 次触发之前用固定 30 圈/秒等效节拍，之后切换到实测周期；两种状态下锚点都应稳住。

| 现象 | 判读 | 处理 |
|---|---|---|
| 锚点缓慢单向旋转 | 周期估计偏差（五次均值滞后）或触发热失步 | 记录转速与圈数，回传後再决定是否调整平均窗口 |
| 锚点抖动但平均位置稳定 | 输入抖动或消抖窗口不足 | 回到消抖判据表处理 |
| 画面全白或完全不动 | 没有 `slot_start`（周期为 0 或调度器未运行） | 检查 D9 心跳、重新下载并读 USERID |
| 高速时图像边缘发暗 | `row_ticks` 触到 `MIN_ROW_TICKS` 下限而截断 | 降低转速或减小 `SLOT_LOG2` |
| 整体偏暗（尤其高速） | OE 占空比约 2.6%，因为 643 拍移位开销固定 | 先测，再决定改 `PIXEL_HALF_DIV` 或 `SLOT_LOG2=5` |

**没有电机时的退路**：用手以大致恒定的节奏连续遮挡约 2 Hz，超过 6 次后锚点应停在遮挡动作对应的固定方位；节奏改变后锚点方位不应跟着转。这只是定性判读，定量部分如实记 TBD。

## 可选：读取精确计数

需要一个 **3.3 V USB-TTL** 接收器：其 RX 接 **JP1 第 35 脚 GPIO1_15P/V12**，GND 共地；不接其 TX，不把其电源接到 FPGA 信号脚。这里不是板载 PS USB-UART。接好后优先用上面的 `capture_uart.ps1`，不要手工抄十六进制。

串口设置 115200、8 数据位、无校验、1 停止位。每次 period_update 发送 10 字节二进制包（非可读文字），从第六次红外触发后开始：

```text
55 AA  [最近间隔 uint32 小端] [五间隔平均 uint32 小端]
```

计数单位为 20 ns：周期秒数 = ticks / 50,000,000；RPM = 3,000,000,000 / mean_ticks。1800 RPM 的平均计数应约为 1,666,667。发包约 0.868 ms，发送忙时的新快照忽略，仅影响调试输出，不改变周期计算。当前包内**不含**扫描时序量，闭环只能靠目视锁角判读；需要定量时必须加示波器或扩展 UART 字段。

请返回：屏幕图案是否正常（滚动、白闪、红条方位）、四个 LED 的表现、六次触发后 D8 是否亮、锁角测试的转速与漂移；有串口时再提供原始十六进制数据。显示花屏/亮度异常时先保持静止，测量 CLK/LAT/OE 与供电，再决定下一步时序调整。
