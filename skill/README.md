# skill/ — 从本项目提炼的可复用技能包

四个技能包都来自本项目**真实踩过的坑**，每条结论都在本仓库的脚本或实测记录里能找到出处。
每个包按同一结构写：适用范围 → 前置条件 → 可照抄的步骤 → **失败模式表** → 验证证据 → 可移植性 → 边界。

## 索引

| 技能包 | 解决的问题 | 关键结论 |
|---|---|---|
| [`vivado_batch_build/`](vivado_batch_build/SKILL.md) | 无人值守构建与回归：目录隔离、报告归集、仿真器调用方式 | `launch_simulation` 报 `Common 17-180 Spawn failed` 时，改用绝对路径直调 `xvlog/xelab/xsim`；回归按 transcript 的 PASS 行判定，不看退出码 |
| [`zynq_ps7_axi3_hp0/`](zynq_ps7_axi3_hp0/SKILL.md) | PS7 的 HP 口接 PL 主设备时必然遇到的三个坑 | HP0 是 **AXI3**（≤16 beats）；`proc_sys_reset.aux_reset_in` **默认低有效**，接 0 会让 A9 首次访问 AXI GPIO 挂死；HP 口**非一致**，用 `ARCACHE=4'b0010` 或显式 flush |
| [`vitis_2026_headless_sd_boot/`](vitis_2026_headless_sd_boot/SKILL.md) | Vitis 2026.1 无 XSCT 的脚本化构建与 SD 脱机启动 | `xsct` 已被禁用，改 `vitis.bat -s script.py`；中文 Windows 必须 `chcp 65001` + `PYTHONUTF8=1` 否则 `create_client()` 撞 UTF-8；SD0 固定 MIO40..45，boot mode 只在 POR 采样 |
| [`zynq_bringup_evidence_kit/`](zynq_bringup_evidence_kit/SKILL.md) | 许可证没有 ILA 时，如何客观证明"配置成功"且"跑的是这一版" | 没有 `PROGRAM.IS_PROGRAMMED`，改读 DONE/EOS；用 `BITSTREAM.CONFIG.USERID` + `REGISTER.USERCODE` 读回自证构建来源 |

## 使用方式

1. 先读目标包的"何时用 / 何时不用"，确认场景匹配。
2. 按"步骤"里的命令逐步执行；每步都有对应的判据，**不要跳过判据直接看结果**。
3. 出错时先查该包的"失败模式"表，再看"验证证据"里本仓库的参考实现。

## 编写规范（新增技能包时）

每个 `SKILL.md` 必须包含以下七节，缺一不可：

1. **一句话** —— 这个包到底解决什么问题。
2. **何时用 / 何时不用** —— 明确边界，避免被套用到不适用的场景。
3. **前置条件** —— 工具版本、器件、许可证。
4. **步骤** —— 可直接复制的命令/代码，每步带判据。
5. **失败模式** —— 表格：症状 / 根因 / 处置。这一节是技能包的核心价值。
6. **验证证据** —— 指向本仓库里能证明结论的文件路径。
7. **可移植性 + 边界** —— 换板换题是否成立，以及**不承诺**什么。

硬性要求：

- 只写**已经在本项目里验证过**的结论。做过但失败的（例如 BASIC 许可证下的 ILA）要明写成"不可用"，
  不能含糊成"支持"。
- 涉及数字的必须能追到 `data/logs/` 或实测记录；没有实测的写 TBD。
- 不写死本机绝对路径（用 `%~dp0`、`[file normalize [info script]]`、`os.path.dirname(__file__)`）。

## 未收录的候选

以下想法评估过但**没有沉淀成技能包**，原因是证据不足或不可复现：

- 七系列异步 GPIO 同步 + `set_false_path` 约束 —— 只做了 2FF 同步，没有做跨时钟域约束的完整验证。
- HUB75 面板电气时序（建立/保持、线缆、驱动器）—— 无示波器实测，19 个输出未加 `set_output_delay`。
- PYNQ / Ubuntu 镜像 —— 未实现，不宣称。
