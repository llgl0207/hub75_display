# 第一阶段：红外捕获与周期估算

## 当前范围

已新增 [ir_revolution_sync.v](<ir_revolution_sync.v>)，并在 [hub75_top.v](<hub75_top.v>) 实例化。当前 HUB75 仍运行原静态测试扫描；红外尚不改变扫描位置或输出节奏。DDR AXI 读取、切片调度、打包解包、整片 BRAM 乒乓缓存和加速补显均尚未实现。

## 接线

根据 [Microphase Mizar-Z7 官方手册 GPIO 表](https://fpga-docs.microphase.cn/en/latest/DEV_BOARD/MIZAR-Z7/MIZAR-Z7_Reference_Manual.html#gpio)：GPIO1_14P = JP1 第 33 脚 = FPGA U13。该脚未与现有 HUB75 输出冲突，已加入 [板级约束](<constraints/hub75_mizar_z7.xdc>)。P/N 命名不妨碍 P 脚作为普通单端输入，不使用 IBUFDS。

用户此前称 MIZAR R7，已有工程/约束为 Mizar-Z7；必须确认实物型号/版本与上述接口表一致后再接线。约束按默认 3.3 V IO 电源设置 LVCMOS33；若板上电源配置不同，必须重新核对。

- 红外数字输出接 JP1-33，传感器地与板地共地。
- 不得直接接 5 V 推挽输出；先电平转换。开漏输出上拉到对应 IO 电源。
- 不默认开启内部上拉；外部传感器必须提供确定的闲置电平。
- 当前按用户要求默认上升沿触发：顶层 IR_FALLING_EDGE=0，独立模块 FALLING_EDGE=0；后期改为 1 即下降沿。此为综合参数，修改后需重新生成 bitstream，不是运行时寄存器。
- 0 V / 3.3 V 数字输出可以直接采样。RTL 不能将普通 LVCMOS33 输入阈值设置为精确 1.65 V；高低电平范围由芯片 IO 规范决定，无需 ADC。脉冲宽度需足够被 50 MHz 时钟采到（至少数个周期）。

## 模块接口

- 两级同步触发器带 ASYNC_REG/SHREG_EXTRACT 属性；同步后检测边沿，产生单周期 revolution_start。禁止把它当时钟或异步复位。
- 第一次触发只记录基准。每个后续触发产生 last_interval_ticks；环形窗口最多保存最近五个完整间隔。
- 收齐五个间隔（六次触发）后 period_valid=1。每次捕获后一个时钟发布 period_ticks，等于最近五个间隔和除以 5，向下取整；period_update 同时脉冲。
- 未收齐时 period_valid=0，period_ticks 保持零。此为测量接口语义，不决定显示系统启动/消隐行为；后者仍待定。
- 默认 32 位时钟计数，50 MHz 下单个间隔必须小于约 85.9 秒。计数器正常回绕由无符号模减处理，不增加漏触发或超时恢复。
- 每次触发均立即产生重启事件，即使周期估计尚未有效；消费者若需采用新平均值，要注意其晚一个时钟发布。
- 没有消抖、异常剔除或额外滤波。

顶层测量结果保留 MARK_DEBUG，但 BASIC 许可证拒绝 ILA 插入，因此当前通过板载 LED 与外接 USB-TTL 串口观测，无 ltx 文件。已生成完成布局布线的上板测试 bitstream，操作和最终报告边界见 [上板测试步骤](<上板测试步骤.md>)。50 MHz 下，1800 RPM 约对应 1,666,667 个时钟计数/圈。

## 仿真和综合

本次已在本机 `F:/AMDDesignTools/2026.1/Vivado` 运行 XSim：

- [红外测试](<tb_ir_revolution_sync.v>)：五间隔预热、滑动窗口替换、计数器回绕、宽位求和、复位、输入上电已有效时不产生伪触发，PASS。
- 顶层展开编译通过。
- [原扫描测试](<tb_hub75_scan.v>)：32 地址、每地址 128 个像素时钟，PASS。该旧测试不验证实际频率、亮度或全部面板时序。

补充检查：当前默认上升沿与显式下降沿实例同时运行，全部测量输出逐周期一致，仿真 PASS。独立红外模块已通过非工程模式综合与 opt_design，使用 657 LUT、339 寄存器、0 BRAM、0 DSP；50 MHz 下综合估算建立 WNS +9.207 ns。结果位于本地 ir_test/synthesis 目录，不纳入源码版本管理。

上述为独立模块、布局布线前估算，不等于完整顶层时序收敛。report_cdc 明确跳过无输入时钟/延迟约束的异步外部端口，因此不能声称其证明传感器 CDC 安全。板级 XDC 已补充仅从 ir_in 到第一级 ir_meta 的 false path；meta 到 sync 仍保留时序检查。完整顶层约束解析、布局布线、同步器物理布局和上板仍待验证。

可从命令行独立复现，不重置已有 GUI 工程运行：

```powershell
& 'F:/AMDDesignTools/2026.1/Vivado/bin/vivado.bat' -mode batch -source E:/0Files_Bin/EE/vivado/hub75_display/check_ir_synthesis.tcl
```

脚本见 [check_ir_synthesis.tcl](<check_ir_synthesis.tcl>)。

打开 [工程](<hub75_display.xpr>) 后，可在 Vivado Tcl Console 运行：

```tcl
source E:/0Files_Bin/EE/vivado/hub75_display/simulate_ir.tcl
```

已有 GUI 打开旧工程时，先运行 [add_sources.tcl](<add_sources.tcl>) 同步新增源文件；该脚本默认仍选择原扫描 testbench。红外脚本切换测试顶层、运行测试后恢复扫描顶层。

需要重新综合时（会使既有实现结果过期，但不删除源文件）：

```tcl
source E:/0Files_Bin/EE/vivado/hub75_display/add_sources.tcl
reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
open_run synth_1
report_utilization -file ir_utilization_synth.rpt
report_timing_summary -file ir_timing_synth.rpt
report_cdc -file ir_cdc_synth.rpt
```

先检查综合/CDC 报告，不将综合通过当作可安全上板或已完成体积显示。
