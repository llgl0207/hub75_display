# vivado_batch_build — 无 GUI 的 Vivado 批处理构建与回归

**一句话**：用 `-mode batch -source` 跑单文件 Tcl 驱动，每次构建自建工程、把报告写进固定目录，
并用**绝对路径直调 `xvlog/xelab/xsim`** 绕开 `launch_simulation` 的 `Spawn failed`。

## 何时用 / 何时不用

- 适用：可重复构建、多 testbench 回归、需要把 timing/utilization 报告归档、CI 或无人值守重跑。
- 适用：`vivado` 不在 `PATH`、工程路径含中文或空格、换一台机器要重新跑一遍。
- 不适用：需要人肉交互布局布线或 GUI 波形调试时。

## 前置条件

- Vivado 2024.x 及以上；本技能在 **Vivado 2026.1 / Windows** 上验证。
- 所有 Tcl 脚本只用相对仓库根的路径，不写死绝对路径。
- 有一个能定位 `vivado.bat` 的 wrapper（本仓库 `build/vivado.ps1`）。

## 步骤

### 1. 先做不碰硬件的语法自检

```powershell
.\build\vivado.ps1 build\check_scripts.tcl
```

wrapper 的查找顺序：`-VivadoBin` → `$env:VIVADO_BIN` → `PATH` → 各盘符下的
`AMD\*\Vivado\bin`、`AMDDesignTools\*\Vivado\bin`、`Xilinx\Vivado\*\bin`，同名取版本号最大者。
找不到就报错退出，**不要**静默回落到某个写死的路径。

### 2. 每次构建自建工程，报告落到固定目录

```powershell
.\build\vivado.ps1 build\build_board_test.tcl
```

要点：

1. 脚本自己 `create_project`（不依赖已存在的 `.xpr`），因此可以随时删掉工作目录重来。
2. 显式走 `opt_design / place_design / route_design`，不要指望 `launch_runs` 的副作用。
3. 报告逐份 `-file` 到 `build/reports/`：

```tcl
report_timing_summary -file $rpt/timing.rpt
report_utilization    -file $rpt/utilization.rpt
report_drc            -file $rpt/drc.rpt
report_cdc            -file $rpt/cdc.rpt
report_io             -file $rpt/io.rpt
```

4. 最后打印一个**唯一成功标记**（本项目 `BOARD_TEST_BUILD_COMPLETE`），供外层脚本 grep。
   多阶段构建带 `stage=N`，例如 `PS_SYSTEM_BUILD_COMPLETE stage=0`。

### 3. 回归：绝对路径直调仿真器

```powershell
.\build\vivado.ps1 sim\run_regression.tcl
```

不要在 batch 里用 `launch_simulation`。改为先定位 `xvlog.bat/xelab.bat/xsim.bat`：

```tcl
set xsim_bin [file join [file dirname [file normalize [info nameofexecutable]]]]
# 或用 [file join $::env(XILINX_VIVADO) bin]
exec [file join $xsim_bin xvlog.bat] -sv $files
exec [file join $xsim_bin xelab.bat] $top -s $snap
exec [file join $xsim_bin xsim.bat] $snap -runall
```

然后用 `catch` 读每个 transcript，**按 PASS 行判定，不按退出码判定**：

```tcl
if {![string match "*PASS: $tb*" $log]} {
    puts "FAIL: $tb printed no PASS line"
    exit 1
}
```

一条 `run all` 安静跑完不等于成功——XSim 对 `$fatal`/`$error` 的退出行为在不同版本不一致。

## 失败模式

| 症状 | 根因 | 处置 |
|---|---|---|
| `Common 17-180 Spawn failed` | `launch_simulation` 生成的 `compile.bat` 用相对名调 `xvlog`，子进程 PATH 里没有 Vivado bin | 不用 `launch_simulation`，改绝对路径直调；把 bin 加进进程 PATH 只是治标 |
| 报告互相覆盖 | 多个构建阶段写同一路径 | 每阶段一个子目录 `reports/<stage>/` |
| 中文/空格路径下工具报找不到文件 | Tcl 里用 `[pwd]` 拼路径 | 一律用 `[file normalize [info script]]` 反推仓库根 |
| `Move-Item` 报 `DirectoryNotFoundException` | 目标父目录不存在（PowerShell 不自动建） | 批量移动前先 `New-Item -ItemType Directory -Force` |
| 回归"通过"但实际有 FAIL | 只看退出码 | 强制每个 tb 必须打印 `PASS: <tb>`，否则 `exit 1` |

## 验证证据

- `build/vivado.ps1`：wrapper 实现（多盘符搜索 + 版本号排序）。
- `build/build_board_test.tcl`、`build/build_ps_system.tcl`：自建工程 + 报告归档 + 成功标记。
- `sim/run_regression.tcl`：7 个 testbench，绝对路径调用，PASS 行判定，输出 `REGRESSION_COMPLETE`。
- `data/logs/`：由上述构建产出的真实报告快照（`main/`、`ps_stage0/`、`ps_stage1/`、`ir_standalone/`）。

## 可移植性

与器件无关，换成 Artix/Kintex、换 Vivado 版本仍成立；只依赖"batch 模式 + 单文件 Tcl"这一层。
`xvlog/xelab/xsim` 的绝对路径调用方式对任何 Vivado 安装都适用。

## 边界（本技能不承诺）

- 不承诺内部时序即外部时序：板级线缆、驱动器、建立保持时间必须另外测量并加 `set_output_delay`。
- 不承诺跨版本比特流兼容；`.bit` 与器件型号、速度等级强绑定。
