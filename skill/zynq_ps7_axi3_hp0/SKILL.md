# zynq_ps7_axi3_hp0 — Zynq-7000 PS7 + S_AXI_HP0 的三个必踩坑

**一句话**：PS7 的 `S_AXI_HP0` 是 **AXI3**（单次突发 ≤16 beats），`proc_sys_reset` 的
`aux_reset_in` **默认低有效**（接常量 0 会让 A9 首次访问 AXI GPIO 就挂死），HP 口是**非一致**的
（PS 写完要按无 cache 路径处理）。这三条任一踩中，现象都是"AXI 读不到数据/PS 卡死"，但根因完全不同。

## 何时用 / 何时不用

- 适用：Zynq-7000 上让 PL 做 AXI 主设备直读 DDR（帧缓冲、大块样本搬运），PS 只做控制与提交。
- 适用：从别处（教程/AXI4 模板）抄来的 BD 直连 HP 口报协议错误。
- 不适用：ZynqMP / Versal 的 HP/HPC 端口规格不同，本技能不覆盖。

## 坑 1：HP0 是 AXI3，不是 AXI4

BD 里 `create_bd_intf_port` 生成的 `aximm_rtl` 默认按 AXI4，直接连 `S_AXI_HP0` 会报协议不兼容。

```tcl
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI_HP0
set_property -dict [list \
    CONFIG.PROTOCOL     {AXI3} \
    CONFIG.FREQ_HZ      {50000000} \
    CONFIG.DATA_WIDTH   {64} \
    CONFIG.ID_WIDTH     {6} \
    CONFIG.ADDR_WIDTH   {32} \
    CONFIG.HAS_BURST    {1} \
    CONFIG.SUPPORTS_NARROW_BURST {0} \
] [get_bd_intf_ports S_AXI_HP0]
```

RTL 侧对应的硬约束：

- `ARLEN` 最大 **16 beats**（AXI4 才允许 256）。本项目每片 3072 B = 24 次 `16×64 bit` 突发。
- `ARID` 只有 6 bit，读通道必须把 outstanding 数量控制在 ID 空间内。
- 不要发 `FIXED`/`WRAP` 之外 AXI3 不支持的类型；地址必须按 beat 对齐。

## 坑 2：`aux_reset_in` 默认低有效

`proc_sys_reset` 的 `ext_reset_in` 是高有效，而 `C_EXT_RESET_HIGH` 在 BD 里常是只读；
更隐蔽的是 `aux_reset_in` **默认 `C_AUX_RESET_HIGH=0`**。于是：

```tcl
# 错误：接常量 0 -> peripheral_aresetn 永远为低
connect_bd_net [get_bd_ports dummy] [get_bd_pins rst/aux_reset_in]
```

后果不是"复位不释放"那么直观，而是**A9 第一次访问 AXI GPIO 就挂死**（读寄存器永远不返回），
看起来像 PS 死机或 DDR 问题，浪费大量时间。

正确做法：

```tcl
set_property -dict [list CONFIG.C_AUX_RESET_HIGH {1}] [get_bd_cells rst]
# 反相后的 FCLK_RESET0_N 接 ext_reset_in；aux_reset_in 与 mb_debug_sys_rst 一起接 0
```

判断标准：`peripheral_aresetn` 在上电后必须**常高**；用 `report_bd` 或直接读
`get_property CONFIG.C_AUX_RESET_HIGH` 复核，不要凭印象。

## 坑 3：HP 口访问是非一致的

`S_AXI_HP0` 走 PS 的 L2 旁路但**不参与 cache 一致性**。PS 侧写完帧缓冲后，PL 可能读到旧数据
（本项目现象：Linux 下上屏是上一帧）。

两种可靠做法，二选一：

1. **读口标非 cache（本项目采用）**：AXI 读事务 `ARCACHE = 4'b0010`（Device non-cacheable），
   彻底不依赖 cache 维护。
2. PS 侧显式维护：写完后 `Xil_DCacheFlushRange()`（裸机）或 `dma_sync_single_for_device()`
   （Linux），并在搬运前后成对出现。

另加两条工程约定：

- 帧基址**只在换圈边界锁存**，一圈内不变；PS 改基址只是"置 pending"，由 PL 在 `revolution_start` 采样。
- A/B 双缓冲：PS 必须等到 `frame_done` 翻转后才复用旧缓冲，否则会撕裂。

## 坑 4（导出侧）：`write_hw_platform -include_bit` 会失败

显式 `opt/place/route` 流程下没有 `impl_1` 的 `write_bitstream` 产物，导出带 bitstream 的 XSA 会报
"Unable to get BIT file"。

```tcl
# 要么不带 bitstream 导出，在 Vitis Run Configuration 里单独选 .bit
write_hw_platform -fixed -force -file board/output/system.xsa
# 要么先让 impl_1 跑到 write_bitstream，再带 bitstream 导出
launch_runs impl_1 -to_step write_bitstream
```

## 验证证据

- `src/hub75_ddr_reader.v`：AXI3 读 master，16-beat × 24 突发/片，`ARCACHE=4'b0010`。
- `build/create_ps_bd.tcl`：`CONFIG.PROTOCOL {AXI3}`、`C_AUX_RESET_HIGH=1`、HP0/GP0 完整 BD。
- `data/logs/ps_stage1/{timing,utilization,drc}.rpt`：50 MHz 下 WNS +5.857 ns、DRC 0 违例、
  切片 RAM 落 2 × BRAM36 —— 说明上述约束不影响时序收敛。
- `sim/tb_hub75_ddr_reader.v`：行为级 AXI3 slave，检查两片 4096 字写入顺序。

## 可移植性

坑 1、3、4 对任何 Zynq-7000 + HP 口设计成立。坑 2 是 `proc_sys_reset` 的通用陷阱，
ZynqMP 上用 `zynq_ultra_ps_e` 时对应属性名不同但同样是"低有效默认值"的坑。

## 边界（本技能不承诺）

- 不涉及 HPC 口、ACP 口、或带 coherent 端口的 ZynqMP 方案。
- 不给出可达带宽数字：本项目未做 DDR 带宽实测，报告里一律标 TBD。
