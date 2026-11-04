# zynq_bringup_evidence_kit — 没有 ILA 时怎么证明"板上跑的是哪一版、活没活"

**一句话**：BASIC 许可证没有 `create_debug_core`，也就没有 ILA/VIO/`.ltx`。替代证据链是
**DONE/EOS 配置状态 + USERCODE 读回自证构建来源 + LED/UART 分级观测 + 离线报告**，
每一层都能被第三方复现，而不是靠"我看它亮了"。

## 何时用 / 何时不用

- 适用：许可证受限（BASIC/WebPACK）无法用 ILA，但仍要给出客观的上板证据。
- 适用：需要向评审/同事证明"板上烧的就是仓库里这次提交构建出来的那个 bit"。
- 不适用：有完整许可证、可以上 ILA 抓内部波形的场合——那时 ILA 更直接。

## 核心事实（先记住，能省几小时）

1. **Vivado 2026.1 没有 `PROGRAM.IS_PROGRAMMED` 属性**。对 `arm_dap_0` 或 `xc7z020_1` 读取都会抛
   `Labtoolstcl 44-56`。用它判断"是否已配置"必然失败。
2. 正确判据是配置状态寄存器：
   - `REGISTER.CONFIG_STATUS.BIT14_DONE_PIN`（DONE）
   - `REGISTER.CONFIG_STATUS.BIT04_END_OF_STARTUP_(EOS)_STATUS`（EOS）
3. 读属性必须 `catch` 保护，否则一个不可读属性会中断整条设备枚举循环。
4. JTAG 链上 Zynq-7000 同时暴露 **`arm_dap_0`（PS 调试）** 和 **`xc7z020_1`（PL）**，
   遍历时要按 PART 名称过滤，别对第一个 target 就下手。
5. **`BITSTREAM.CONFIG.USERID` 是本技能的关键**：给 bitstream 写一个唯一 32 位标识，
   下载后从 `REGISTER.USERCODE` 读回。本项目用 `0x48554237`（"HUB7"）。

## 步骤

### 1. 只读枚举 JTAG 链（不碰设备）

```tcl
open_hw_manager
catch { connect_hw_server -url localhost:3121 }
foreach tgt [get_hw_targets] {
    catch { current_hw_target $tgt; open_hw_target -quiet }
    foreach dev [get_hw_devices] {
        if {![string match "*7z020*" [get_property PART $dev]]} { continue }
        puts "DEV $dev PART=[get_property PART $dev]"
    }
}
```

Vitis 2026.1 可能把 hw_server 起在**动态端口**（本项目实测过 3122），所以先试 3121，失败再试 3122。

### 2. 给构建打标

```tcl
set_property BITSTREAM.CONFIG.USERID 0x48554237 [current_design]
write_bitstream -force board/output/system.bit
```

### 3. 下载并按寄存器判据判定

```tcl
set done [get_property REGISTER.CONFIG_STATUS.BIT14_DONE_PIN $dev]
set eos  [get_property REGISTER.CONFIG_STATUS.BIT04_END_OF_STARTUP_\(EOS\)_STATUS $dev]
if {$done != 1 || $eos != 1} { error "PL not configured: DONE=$done EOS=$eos" }
```

### 4. 读回 USERCODE，自证来源

```tcl
set uid [get_property REGISTER.USERCODE $dev]
if {$uid != "0x48554237"} { error "wrong build on board: USERCODE=$uid" }
```

这一步是"证据链"和"我觉得成功"的分界线：它能把"板上跑的是哪次构建"从推测变成事实。

### 5. 分级观测（由粗到细）

| 层级 | 手段 | 判据 |
|---|---|---|
| L0 | DONE / EOS | 都为 1 |
| L1 | USERCODE | 等于本次构建的 USERID |
| L2 | 板载 LED | 反逻辑 LED 按设计翻转（本项目 D6 跟随遮挡、D8 第 6 次才亮） |
| L3 | RTL 自带 UART | 115200 8N1，10 字节包 `55 AA` + 间隔 LE32 + 均值 LE32 |
| L4 | 面板现象 | 静态彩条 → "2280" 数字可辨认 → 旋转体成像 |

L4 只能由人确认，必须**记录谁在什么时候看到什么**，不能写成"已验证"。

## 失败模式

| 症状 | 根因 | 处置 |
|---|---|---|
| `Labtoolstcl 44-56` | 读了不存在的属性（如 `PROGRAM.IS_PROGRAMMED`） | 改读 CONFIG_STATUS，且全部 `catch` 保护 |
| `End of startup status: LOW` | 偶发配置失败，**与 USERID 属性无关** | 重下一次；本项目中同一份带 USERID 的 bit 后续配置成功 |
| 读回 USERCODE 全 `ffffffff` | PL 没配置成功 / 读到未配置态 | 回到 L0 重判 |
| hw_server 连不上 3121 | Vitis 起了动态端口 | 再试 3122 |
| 把 `docker`/`get_hw_devices` 第一个当目标 | 链上有 `arm_dap_0` | 按 PART 过滤 `7z020` |

## 验证证据

- `build/program_board.tcl`：DONE/EOS 判据实现，含 `catch` 保护与 3121/3122 回退。
- `build/verify_bitstream.tcl`：USERCODE 读回自证。
- `build/probe_hw.tcl`：只读枚举。
- `board/board_test_procedure.md`：人工观测步骤与期望值。
- `src/ir_debug_uart.v`：L3 观测通道。
- `data/logs/`：与之对应的离线综合实现报告。

## 可移植性

- 属性名会随 Vivado 版本变，但"用配置状态寄存器而不是 `IS_PROGRAMMED`"、"用 USERCODE 自证来源"
  的思路在任何版本都成立；换 Xilinx/AMD 工具链时值得先查这两个属性是否存在。
- USERID 取值任意 32 位，只要有唯一含义即可。

## 边界（本技能不承诺）

- 不能替代 ILA：内部总线/握手时序的真实波形，本技能给不出来。
- 不能证明"功能正确"，只能证明"配置成功且是这一版"；功能正确性仍要靠 L2–L4 的现象判据与仿真。
- 本项目在 BASIC 许可证下的 ILA 尝试**已经失败并放弃**，不要把它写成"支持 ILA"。
