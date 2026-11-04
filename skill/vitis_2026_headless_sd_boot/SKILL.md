# vitis_2026_headless_sd_boot — Vitis 2026.1 无 XSCT 的脚本化构建与 SD 脱机启动

**一句话**：Vitis 2026.1 **禁用了 XSCT**，脚本化只能走 `vitis.bat -s <python>`；而 Vitis Python API
在**中文 Windows** 上会在 `create_client()` 抛 UTF-8 解码错误 —— 必须在批处理里先把代码页和
Python 编码锁死。跑通后用 bootgen 把 **FSBL + bitstream + ELF** 合成 `BOOT.BIN` 实现脱机启动。

## 何时用 / 何时不用

- 适用：要在命令行/批处理里无人值守地建 platform、建 app、出 `BOOT.BIN`。
- 适用：中文 Windows 上 Vitis Python 报 `'utf-8' codec can't decode byte 0xd5`。
- 不适用：只有 GUI 一步操作（建 app、点 Run）就够的场合，用 GUI 更快。

## 步骤

### 1. 批处理先锁编码，再调 Vitis

```bat
@echo off
chcp 65001 >nul
set PYTHONUTF8=1
set PYTHONIOENCODING=utf-8
set LANG=en_US.UTF-8
"%VITIS_BIN%" -s "%~dp0build_sd_boot.py"
```

- `chcp 65001`：把控制台代码页切成 UTF-8，否则 Vitis client 用 UTF-8 读子进程输出会撞上 GBK 字节。
- `PYTHONUTF8=1` + `PYTHONIOENCODING=utf-8`：让 Python 自身所有 stdio 走 UTF-8。
- `%~dp0`：用脚本自身目录定位，避免把 `C:\Users\<别人>\...` 写死进仓库。

### 2. Python 侧：建 platform → FSBL → app → bootgen

```python
import vitis
client = vitis.create_client()          # 这一步最容易被编码问题打死
client.set_workspace(workspace)
platform = client.create_platform_component(
    name="hub75_platform", hw_design=xsa,
    os="standalone", cpu="ps7_cortexa9", domain_name="standalone_ps7_cortexa9")
app = client.create_app_component(
    name="hub75_renderer", platform=platform, domain="standalone_ps7_cortexa9")
app.set_sources([...])                   # 或用 import_files
app.build()
vitis.dispose()
```

然后在 Tcl/命令行里调 `bootgen -image boot.bif -arch zynq -o BOOT.BIN -w on`，
`boot.bif` 三段顺序固定：

```
the_ROM_image:
{
    [bootloader]fsbl.elf
    system.bit
    hub75_renderer.elf
}
```

### 3. 卡与启动模式

- SD0 固定映射 **MIO40..45**（BootROM 决定）。**不要用 SD1**：会与本项目 UART1 的 MIO48/49 冲突。
  CD/WP/POW 引脚可以不接。
- 卡：**MBR 分区表 + FAT/FAT32**，`BOOT.BIN` 放**根目录**。
- **boot mode 在 POR 采样**：拨了 SW4 之后要**断电再上电**，按复位键不保证重新采样。
- 换卡前先备份原有 `BOOT.bin`。

## 失败模式

| 症状 | 根因 | 处置 |
|---|---|---|
| `XSCT is disabled in Vitis 2026.1 release` | 2026.1 移除了 XSCT | 改用 `vitis.bat -s script.py`，或直接用 GUI |
| `'utf-8' codec can't decode byte 0xd5` in `create_client()` | 中文 Windows 控制台是 GBK，client 按 UTF-8 读子进程输出 | `chcp 65001` + `PYTHONUTF8=1` + `PYTHONIOENCODING=utf-8` |
| 上了卡不启动 | boot mode 没重新采样 / 卡不是 FAT / 分区不是 MBR | 断电上电；重新按 MBR+FAT 格式化；确认 `BOOT.BIN` 在根目录 |
| 两个串口只有一个有输出 | 板上 CP2102 实际接 **UART1 = MIO48(TX)/MIO49(RX)**，不是手册常写的 UART0 MIO14/15 | BD 里两个 UART 都使能，代码直接初始化 UART1（`UART1 @0xE0001000`、MIO48/49 的 L3_SEL=7、`UART_CLK_CTRL` 的 CLKACT1、`APER_CLK_CTRL[21]`） |
| 换机器后脚本找不到工程 | `.bat` 里写死了绝对路径 | 用 `%~dp0` / `os.path.dirname(__file__)` |

## 验证证据

- `build/build_sd_boot.py` + `build/run_build_sd_boot.bat`：完整 platform + FSBL + app + `BOOT.BIN` 链路。
- `build/rebuild_fsbl.py` + `build/run_rebuild_fsbl.bat`：XSA 变更后单独重出 FSBL。
- `board/output/BOOT.BIN`：**4,195,624 B**，插卡断电上电后无需 JTAG 即可上屏。
- `report/linux_port_plan.md` §14、`report/ps_development.md`：SD 启动与 UART1 实测记录。

## 可移植性

"锁编码 + `-s script.py` + bootgen 三段"这一套对任何 Zynq-7000 的 standalone SD boot 都成立；
UART 引脚要先确认板上 USB-UART 实际接到哪个 PS UART，**不要照抄手册**。

## 边界（本技能不承诺）

- 不涉及 PetaLinux：本项目的 Linux 用的是厂商 2018.3 镜像 + 自建 FSBL/bitstream，不是 PetaLinux 重建。
- 不承诺 QSPI flash 烧写流程（本项目只做 SD 脱机启动）。
