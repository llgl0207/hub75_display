# Linux 移植计划：Zynq-7020 旋转 HUB75 显示

> 状态：**规划 / 待选 Linux 基础路线**。最后更新：2026-11-02。
> 本文件是 Linux 部分的唯一事实来源；上下文压缩后从这里继续。

## 1. 目标

- Linux 跑在 PS（Cortex-A9），PL 位流保持现有体系：IR 捕获、调度、DDR reader、slice RAM 乒乓、HUB75 全部时序。
- **开机后 shell 文字直接显示在旋转 HUB75 上**，像显卡驱动一样随系统启动。
- **每个动画是一个可执行文件或文件**，可以在 shell 里直接控制播放；控制台/文字/动画模式通过 Linux 配置文件或 sysfs 切换（“一切皆文件”）。
- 优先开源、资料完整、可长期维护的 Linux 基础。

## 2. 当前已知状态（2026-11-02）

| 项 | 状态 |
|---|---|
| 裸机 PS+DDR | 已验证：UART1 COM11、DDR PASS、帧握手、静止动画、两球、3D 心形、SD BOOT.BIN |
| PL 接口 | AXI GPIO ctrl `0x41200000` / status `0x41210000`；S_AXI_HP0 DDR reader |
| 帧格式 | 64 slice × 3072 B；slice = 32 row_addr × 128 col × 6-bit word；word[2:0]=rgb1/upper，[5:3]=rgb2/lower；A/B 各 192 KiB |
| 顶部 row0 ghost | PL 对 `row_addr=0` 关 OE 后仍未消除；很可能为面板首行硬件/导光行为；Linux 下同一 PL 仍会保留，暂不追 |
| 原卡启动镜像 | **已解析（2026-11-02）**：`BOOT.bin.original` = FSBL + `system_wrapper.bit` + `hello_world.elf`（Vitis 裸机 demo，platform_sine），**不含 U-Boot/内核**；卡上 image.ub/rootfs 即使存在也无法由它启动。原厂 Linux/PYNQ 镜像需从微相课程资料/客服获取 |
| 厂商资料 | 目录结构：01 开箱检测、02 硬件资料、03 source（Linux 4.14 / PetaLinux 2018.3 内核源码，官方版 + 微相修改版）、04 配套模块、05 Datasheet、06 开发教程（Part4 Linux、Part5 PYNQ）、07 Demo。**已找到并校验 Part4_Linux_Demo/1_petalinux_boot_from_sd 的真实 Linux 启动文件**，详见 §12 |
| 本机环境 | Windows 10；Vivado/Vitis 2026.1；WSL 功能已启用但无发行版/WSL2 内核；**PetaLinux 未安装**；Vitis 自带 `arm-linux-gnueabihf-gcc` 13.4（Windows 上可直接交叉编译 hub75d） |

## 3. Linux 基础路线（已选 B，2026-11-02）

**已选：B. 原厂 SD Linux + 用户态 `hub75d`**。理由：本机无 WSL/PetaLinux，原 SD 卡已有厂商 Linux；先用用户态方案最快跑通。A（PetaLinux + WSL2）保留为后续迁移到内核 fbdev/开源基础的选项。

### A. PetaLinux 2026.1（WSL2/Ubuntu 或 Linux 主机）— 推荐用于“开源+资料完整”

- 从 `board/output/hub75_ps_stage1.xsa`（或厂商 Mizar BSP）创建工程；可加厂商 BSP 的 DDR/PHY/U-Boot 配置。
- 开源：Xilinx kernel/U-Boot/rootfs（Yocto）；官方文档 UG1144。
- 需要安装 WSL2 + PetaLinux 2026.1（AMD 下载），构建时间长、磁盘需求大。
- 可控设备树、内核模块、rootfs、启动脚本；最适合做 fbdev + 配置化 shell。

### B. 原厂 SD Linux 镜像 + 用户态 `hub75d` — 最快跑通

- 直接恢复卡上厂商 Linux（`BOOT.bin.original` + `image.ub` + rootfs）。
- 用户态程序通过 `/dev/mem`/UIO 映射 AXI GPIO 和帧缓存；用 PTY/终端模拟器把 shell 文字渲染到 128×64。
- 免内核模块编译；但基础系统可能闭源，fbcon 级“显卡驱动”体验弱一些。
- 适合先验证 Linux 下 PL/DDR 通路，再迁到 A。
- **2026-11-02 前提变更**：`BOOT.bin.original` 解析为 FSBL + `system_wrapper.bit` + `hello_world.elf` 的裸机 demo，**不是 Linux 启动镜像**。B 需要先取得原厂 Linux/PYNQ 镜像（课程资料/淘宝客服/公众号）；否则改用 A（WSL2 + PetaLinux 自建）或 D（Buildroot）。

### C. PYNQ/Ubuntu 现成 Zynq-7020 镜像

- 开源、资料多；但 Mizar-Z7 的 DDR3/PHY/MIO 与 PYNQ-Z1/Z2 不同，需先试启动。
- 成功后可用 PYNQ/Ubuntu 的 `/dev/mem`、framebuffer、Python/CLI。

### D. Buildroot + mainline

- 完全开源；需要 Linux host 和板级 bring-up（FSBL/U-Boot/DDR/DT），工作量最大。

## 4. 目标架构

```text
Linux (PS)                                   PL (现有 bitstream)
────────────────────────────                 ─────────────────────────────
hub75 驱动/守护进程
  - fbdev 128×64 (fbcon)                     IR revolution_start
  - /dev/hub75 (64-slice 帧)                   -> 64 slots/rev
  - sysfs/config 模式切换                      -> DDR reader (S_AXI_HP0)
  - 帧 A/B, frame_done                         -> slice RAM ping-pong
  - dma_alloc_coherent / uncached              -> HUB75 scan
        |                                          |
        +---- AXI GPIO 0x41200000/0x41210000 ------+
```

- **PL 不需要改**（顶部行硬件问题除外）。
- 帧缓存在 Linux 侧用 `dma_alloc_coherent`（或固定预留区 + uncached 映射）；HP0 非一致性由 coherent/uncached 保证。
- 驱动按 IR `frame_done`/bench 节奏提交；屏幕上的文本/动画都走同一帧格式。

## 5. 接口设计（一切皆文件）

| 路径 | 作用 |
|---|---|
| `/dev/fb0` | 128×64 2D framebuffer；`fbcon` 的 shell 文字 |
| `/dev/hub75` | 3D 帧字符设备；ioctl 提交 64-slice 帧、等待 frame_done |
| `/sys/class/graphics/fb0/hub75/mode` | `console2d` / `text3d` / `animation` |
| `/sys/class/graphics/fb0/hub75/text_geometry` | 3D 文字圆柱半径/高度/字体 |
| `/etc/hub75.conf` | 开机默认：`text_mode`、`default_animation`、`font` |
| `/usr/share/hub75/animations/*` | 动画文件/可执行文件（heart、balls、…） |
| `/usr/bin/hub75-play` | shell 播放器：`hub75-play heart` |

> **当前 B 路线（用户态）**：没有内核 `/dev/fb0`/sysfs；实际使用
> `/etc/hub75.conf`、`/run/hub75.cmd`（FIFO）或 `/run/hub75.sock`、
> `/usr/share/hub75/animations/`、`hub75-play`。下表 `/dev/fb0`、
> `/dev/hub75`、`/sys/class/...` 是后续 A 路线内核模块才有的接口。

示例（B 路线）：

```sh
cat /etc/hub75.conf                       # text_mode=console2d / text3d
hub75-play /usr/share/hub75/animations/heart
echo "mode text3d" > /run/hub75.cmd       # FIFO：切 3D 文字
echo "animate /usr/share/hub75/animations/balls" > /run/hub75.cmd
kill -HUP $(pidof hub75d)                 # 改 /etc/hub75.conf 后重载
```

（A 路线内核模块示例：`echo text3d > /sys/class/graphics/fb0/hub75/mode`，
`hub75-play ...`，动画退出后回 `console2d`。）

- `console2d`：把 128×64 控制台图像复制到全部 64 slice（旋转屏上是稳定的 2D 文字）。
- `text3d`：把控制台图像映射到圆柱/体积的 64 slice（文字随旋转成为 3D 效果）。
- `animation`：`hub75-play` 直接提交 64 slice；退出回控制台。
- 字体/几何/默认动画都在 config/FIFO（后续 A 路线为 sysfs），符合“一切皆文件”。

## 6. 驱动/守护进程要点

### 内核模块（后续 A/C/D 路线；B 路线暂不要求）

- `hub75` 平台驱动或模块参数：`ioremap` ctrl/status；`dma_alloc_coherent` 2×`HUB75_FRAME_BYTES`。
- `register_framebuffer`：128×64、16 bpp；`fb_sys_*` 软件画图；worker 把 shadow 转成 slice 并提交。
- `cdev`/`/dev/hub75`：`SUBMIT`（64 slice 帧）、`WAIT_DONE`、`SET_MODE`。
- sysfs 属性：模式、字体、默认动画；`/etc/hub75.conf` 由启动服务读取并写 sysfs。
- 启动：模块 built-in 或 initramfs；`fbcon` 绑定 `/dev/fb0`；UART1（`ttyPS1`）仍保留 console。
- 顶部行：OE blank 未消除；不要再为此改 PL，按面板硬件行为记录。

### 用户态守护进程 `hub75d`（当前 B 路线）

- `/dev/mem` 映射 AXI GPIO `0x41200000`/`0x41210000` 和帧缓存；帧缓存用启动参数 `mem=256M` 把内核限制在 256 MiB 以下，`0x10000000..0x103FFFFF` 留给 PL；若内核开了 `CONFIG_STRICT_DEVMEM`，加 `iomem=relaxed` 或走 UIO。
- `/dev/mem` 映射通常 uncached，CPU 写后 PL 直接读，无需 cache flush。
- Shell 文字：PTY + 自写简易 VT100 终端，8×16 字库，128×64；默认 `console2d` 把画面复制到 64 slice；`text3d` 映射到圆柱/体积。
- 动画：`/run/hub75.sock`（或 FIFO）+ `hub75-play`；daemon 加载动画文件/可执行程序，提交 64 slice；退出后回控制台。
- 配置：`/etc/hub75.conf`（text_mode、default_animation、font、geometry）；daemon 启动读取，SIGHUP 重载。
- 开机：init/systemd 先启动 `hub75d`，再起 UART1 的 shell；daemon 读 UART/PTY 输出并渲染。
- 后续可迁到 A 路线内核 fbdev，得到 `/dev/fb0`/sysfs 和标准 `fbcon`。

## 7. 动画程序

- 复用现有 `hub75_frame` 格式和 heart/balls 渲染器，移植成 Linux 用户态程序。
- 每个动画：可执行文件（如 `hub75-heart`）或帧文件（64×3072 B）；`hub75-play` 统一加载/循环/退出。
- 建议先保留 2～3 个：heart、balls、DNA/helix；后续可加。
- shell 控制：启动/停止/切换；退出后控制台恢复。

## 8. 启动与构建

- 位流进 `BOOT.BIN`（FSBL + bitstream + U-Boot）；内核/DT/rootfs 由 PetaLinux 或厂商镜像提供。
- UART1（MIO48/49，COM11）作为 Linux console 和调试口；`fbcon` 用 `/dev/fb0` 显示 shell 文字。
- SD 卡：BOOT.BIN + image.ub + rootfs；SW4=SD，断电上电；保留 `BOOT.bin.original` 备份。
- PetaLinux 路线：`petalinux-config --get-hw-description <XSA>`；加 bitstream、`hub75` 模块、动画、config、systemd/init；`petalinux-package --boot --fsbl --fpga --u-boot`；SD 镜像。
- 厂商镜像路线（B，当前）：
  - 把 `build/work/sd_backup/BOOT.bin.original` 恢复到卡根目录，先启动原厂 Linux，确认 UART1 console、登录、rootfs；当前裸机 `BOOT.BIN` 保留为回退。
  - 用 `bootgen` 检查原厂 BOOT.bin 的 FSBL/U-Boot/bitstream 分区；生成新 BOOT.BIN = 原厂 FSBL + 我们的 `hub75_ps_stage1.bit` + 原厂 U-Boot；或在 U-Boot 里从 SD 加载我们的 bit 再 boot。
  - U-Boot bootargs 加 `mem=256M`（把 `0x10000000` 帧缓存区留给 PL）；若 `/dev/mem` 被 `CONFIG_STRICT_DEVMEM` 限制，加 `iomem=relaxed` 或改 UIO/DT。
  - rootfs 放 `hub75d`、动画文件/程序、`/etc/hub75.conf`；init/systemd 先启 daemon，再起 UART1 shell。
  - 原卡 `image.ub`/rootfs 不要覆盖；备份原 `BOOT.bin` 已在 `build/work/sd_backup/BOOT.bin.original`。

## 9. 风险与待确认

- **Linux 主机**：本机 Windows 10 无 WSL/PetaLinux；A/D 路线需要 WSL2、Linux VM 或独立 Linux 机器。
- **厂商 BSP/内核源码**：原卡 BOOT.bin 已确认是裸机 demo（无 U-Boot/内核）；原厂 Linux/PYNQ 镜像不在卡上，需课程资料/客服获取，或自建 PetaLinux/Buildroot。
- **板级兼容**：PYNQ/Ubuntu 现成镜像对 Mizar-Z7 的 DDR/PHY/MIO 兼容性未知。
- **HP0 非一致性**：coherent/uncached 映射；避免 CPU cache 与 PL 读到旧帧。
- **fbcon 尺寸**：128×64 约 16×4（8×16）或 16×8（8×8）字符；3D 文本模式可改善观感。
- **顶部 row0 硬件**：OE blank 无效，疑似面板首行导光/硬件；Linux 下保留，不再阻塞。
- **性能**：Linux 下帧提交/文本渲染需 20～30 fps；fbdev worker 与动画共用 PL，注意 A/B 和 frame_done。
- **现成镜像调查（2026-11-02）**：微相公开文档站只有硬件手册；GitHub `bravesy1125/Mizar-Zynq7020-DEV-board` 的 `BOOT.BIN`/`image.ub` 是 4 MB 全零占位（SHA 一致，确认文件本身为空），不能用；其 PetaLinux 工程配置（1 GB DDR、UART1、SD rootfs）可作参考。PYNQ-Z2/ZedBoard 镜像的 FSBL/DDR/U-Boot/DT 是别的板子的，不能直接启动。

## 10. 下一步顺序（B 路线）

1. **取得并启动原厂 Linux（已找到，见 §12）**：把 `build/work/vendor_linux/BOOT.bin` + `image.ub` 写到 SD FAT 根（`build/copy_vendor_linux_to_sd.ps1 -Drive F:`），SW4=SD 上电，COM11 确认 U-Boot 和 `ttyPS0` 登录；检查 `free`、`/proc/cmdline`、`/dev/mmcblk0p1`、`/dev/mem`。
2. **把我们的 bitstream 放进 Linux 启动链**：厂商 FSBL 未启用 GP0/HP0/FCLK0，所以用 bootgen 生成新 `BOOT.bin` = 我们的 `zynq_fsbl.elf` + `hub75_ps_stage1.bit` + 厂商 `u-boot.elf`；U-Boot 继续加载厂商 `image.ub`。确认 FCLK/GP0/HP0 生效、`/dev/mem` 可访问 AXI GPIO/帧缓存。
3. **hub75d 最小原型**：`/dev/mem` 映射 AXI GPIO + 预留帧缓存（`mem=256M`）；提交现有 heart 帧；确认 PL 在 Linux 下显示。
4. **Shell 文字**：PTY + VT100 + 8×16 字库；`console2d`/`text3d`；`/etc/hub75.conf` + `/run/hub75.cmd`。
5. **动画**：heart/balls 用户态程序 + `hub75-play`；shell 控制；退出回控制台。
6. **开机自启/打包**：init/systemd 先起 `hub75d`；SD 镜像；补文档；后续可选 A（PetaLinux/fbdev）迁移。

## 11. 当前构建/文件索引

| 路径 | 作用 |
|---|---|
| `board/output/hub75_ps_stage1.bit/.xsa` | 当前 PL 位流/XSA（含 row0 OE blank） |
| `board/output/BOOT.BIN` | 裸机 SD 启动镜像（heart app） |
| `build/work/sd_backup/BOOT.bin.original` | 原厂裸机 demo 启动备份（非 Linux） |
| `build/work/vendor_linux/` | 原厂 Linux 启动文件：`BOOT.bin`（FSBL+U-Boot）、`image.ub`（kernel+DTB+initramfs）、FSBL/U-Boot ELF、HDF |
| `build/copy_vendor_linux_to_sd.ps1` | 把原厂 Linux 写到 SD 卡 FAT 根（自动备份旧 BOOT.bin/image.ub） |
| `build/work/vitis_sd/` | Vitis FSBL/app 工作区 |
| `hub75_renderer/main.c` | 裸机 heart/balls 渲染器（可移植到 Linux 用户态） |
| `src/hub75_ddr_reader.v` / `slice_ram` / `scan` | PL 显示通路（Linux 下不变） |
| `sw/PS_DEVELOPER_GUIDE.md` | 帧格式、AXI GPIO 契约、提交协议 |
| `report/ps_development.md` | 裸机 PS 开发记录 |

## 12. 原厂 Linux 镜像（2026-11-02 找到并校验）

来源：`C:\baidunetdiskdownload\M\07_Demo\Part4_Linux_Demo\04_Linux_Demo\1_petalinux_boot_from_sd\`，已复制到 `build/work/vendor_linux/`。

| 文件 | 内容 |
|---|---|
| `BOOT.bin` 531,320 B | FSBL + U-Boot，**无 bitstream**（`output.bif` 只有两项） |
| `image.ub` 9,998,060 B | 裸 FIT（偏移 0 即 `d00dfeed`）：Linux 4.14 gzip kernel 3,939,628 B + `system-top.dtb` 13,217 B + `petalinux-user-image` ramdisk（initramfs）gzip 6,043,082 B → cpio 13,541,376 B |
| `zynq_fsbl.elf` / `u-boot.elf` | 可用于 bootgen 重新打包 |
| `system.hdf` | 厂商 Vivado 硬件（PS7：1 GB DDR、UART1、SD0；**GP0/HP0/FCLK0 均未启用**） |

- DTB：`/memory` 1 GB；`console=ttyPS0,115200 earlyprintk`；`serial0 = /amba/serial@e0001000`（UART1 MIO48/49 = COM11）；SD0 okay；`devcfg@f8007000` 节点存在。
- rootfs：busybox + sysvinit；`/etc/inittab` 在 `ttyPS0` 起 getty；root 有 shadow 密码（PetaLinux 默认通常 `root`）。
- kernel config：`CONFIG_DEVMEM=y`、`CONFIG_STRICT_DEVMEM` 未开（`/dev/mem` 可直接映射 AXI GPIO 和 DDR）；`CONFIG_DEVTMPFS_MOUNT=y`、`CONFIG_VFAT_FS=y`、`CONFIG_MMC_SDHCI=y`、`CONFIG_SERIAL_XILINX_PS_UART=y`；**`CONFIG_XILINX_DEVCFG` 未开**（没有 `/dev/xdevcfg`），但 `CONFIG_FPGA_MGR_ZYNQ_FPGA=y`。
- **与我们的 PL 的冲突**：厂商 FSBL 的 PS7 配置 `PCW_USE_M_AXI_GP0=0`、`PCW_USE_S_AXI_HP0=0`、`PCW_FPGA_FCLK0_ENABLE=0`，直接加载我们的 bitstream 无法工作。需要新 `BOOT.bin` = **我们的 `zynq_fsbl.elf` + `hub75_ps_stage1.bit` + 厂商 `u-boot.elf`**，再由 U-Boot 加载厂商 `image.ub`。
- 启动测试：先原样写卡（`BOOT.bin` + `image.ub` 到 FAT 根），确认 COM11 有 U-Boot/Linux 登录；再换我们的 FSBL+bitstream，验证 Linux 仍启动、PL 有 FCLK/GP0/HP0。
- 内存预留：U-Boot 里 `setenv bootargs 'console=ttyPS0,115200 earlyprintk mem=256M'`（或后续改 `image.ub` 的 DTB），把 `0x10000000..0x103FFFFF` 留给 PL。

## 13. 板级 Linux 进展（2026-11-02 晚）

- 原厂 `1_petalinux_boot_from_sd` 已实测启动成功：
  - U-Boot 2018.01（Xilinx Zynq ZC702 配置），DRAM 1 GiB，MMC SD0，console `serial@e0001000`（UART1）。
  - Linux 4.14.0-xilinx-v2018.3，`PetaLinux 2018.3 petalinux_boot_from_sd`，`root/root` 登录成功。
  - `free` ~1 GB；`/dev/mem` 存在；`/dev/mmcblk0p1`（FAT BOOT）/`p2`（ext4 rootfs，1.2 GB used，initramfs 自动挂到 `/run/media/mmcblk0p2`）。
  - `fpga_manager fpga0` 注册（state unknown）；没有 `/dev/xdevcfg`。
  - 内核 config：`CONFIG_DEVMEM=y`、`CONFIG_STRICT_DEVMEM` 未开、`CONFIG_FPGA_MGR_ZYNQ_FPGA=y`。
- 第一次换用“我们的 FSBL + `hub75_ps_stage1.bit` + 原厂 U-Boot”的 BOOT.bin 后，U-Boot 打印到 `Net: ZYNQ GEM...` 后卡死；原因是我们 PS7 里 ENET0 关闭，U-Boot 访问未开时钟的 GEM/MDIO。
- 已在 `build/create_ps_bd.tcl` 启用 ENET0：`MIO 16..27`、MDIO `MIO 52..53`、1000 Mbps（与厂商 HDF 一致），重建 XSA/FSBL 中。
- 下一步：新 FSBL + bitstream + 原厂 U-Boot → 启动 → 登录 → 运行 `sw/linux/hub75_probe.c`（已用 Vitis 的 arm-linux-gnueabihf-gcc 13.4 静态编译为 `build/work/vendor_linux/hub75_probe`）验证 AXI GPIO；之后再处理 `mem=256M` 和 hub75d。

### 13.1 板级实测补充（2026-11-02 深夜）

- 原厂 Linux + 我们的 FSBL/bitstream 启动成功；GP0 正常（`hub75_probe` 读到 ctrl/stat，`frame_base` 写入回读正常），调度器 `active_slice` 正常变化。
- 提交帧后 PS 串口挂死：`frame_ack`/`buf_ready` 未置位；HP0 读在 Linux 下死锁。调度器本身正常（100 ms 采样恰好 192 slot，看起来“不变”是采样假象）。
- `cpuidle.off=1 idle=poll` + `clk_ignore_unused` 未解决挂死。
- JTAG 对照：`build/jtag_run_app_new.tcl`（Linux MMU 开着时先 `rst -system` 再 `ps7_init`）加载新 bitstream + 裸机 heart，COM11 `id 1`、`buf_ready=1`，HP0 在裸机下正常。
- 结论：Linux 下 CPU cache 打开时，HP0 的 `ARCACHE=4'b0011`（cacheable）导致 PS 总线死锁；已改为 `4'b0010`（normal non-cacheable）并重编 bitstream。
- 持久 bootargs：FAT 根目录 `uEnv.txt` 生效（U-Boot 默认环境无 `bootargs`，DTB chosen 被 uEnv 覆盖）：`console=ttyPS0,115200 earlyprintk mem=256M clk_ignore_unused cpuidle.off=1 idle=poll`。

### 13.2 2026-11-03：OCM/HP0 与 BRAM 32-bit 决策

- **OCM 直读验证**：`dd` 写 `/dev/mem` 高端报 `Bad address`（`write()` 路径不支持该 OCM 高端地址），但 `devmem` 提交 `frame_base=0xFFFC1000`、`ctrl=0x4003` → `status=0x13B0D`（`frame_ack=1`、`buf_ready=1`、`frame_id=1`），PS 正常。说明 **reader/HP0 读 OCM 在 Linux 下可用**。
- **帧写程序挂死**：`hub75_pattern_ocm4k` 在 reader 活跃时连 “pattern written” 都未打印即挂死；怀疑 **CPU 写 OCM 与 PL HP0 读 OCM 并发**导致 PS/OCM 死锁。内核 PM 在 OCM 起始分配约 512 B suspend 代码（`suspend.S`），帧即使偏移 4 KB 也无法解决并发死锁。
- **结论：放弃 OCM 作为产品帧缓存**，回到 **PS GP0 + PL BRAM**：PS 写 BRAM（GP0），PL reader 本地读，不碰 HP0/DDR/OCM。此前 64-bit BRAM 对 32-bit GP0 的窄写会挂；改为 **32-bit BRAM（512 KB = 131072×32）**，reader 的 64-bit 读由 AXI Interconnect 降位宽。
- 当前 stage1 正按 32-bit BRAM 重建；FSBL 复用 23:23（PS7 配置不变：GP0、无 HP0），新 BOOT = 新 bit + FSBL + 原厂 U-Boot；Linux 程序 `hub75_pattern_bram`（帧基址 `0x42000000`）不变。
- **OCM 方案（2026-11-02 深夜）**：把帧缓存放到 OCM `0xFFFC0000`（192 KB），HP0 读 OCM **正常**（`frame_base=0xFFFC0000`、`frame_ctrl=0x4003` → `status=0x1150D`，`frame_ack=1`、`buf_ready=1`，串口不挂）。但 `hub75_pattern_ocm` 写完整 192 KB 帧后内核崩溃——厂商内核的 `ocmc` 驱动占用了 OCM。用 `build/patch_image_ub.py` 把 DTB 里 `xlnx,zynq-ocmc` 节点改成 `status="disabled"` 并重打包 FIT；新旧 DTB 对比只有该属性不同（47 节点，serial/aliases/pinctrl 不变），FIT hash 已更新。板上实测：**内核确实启动（JTAG PC 在内核代码），但 UART1 控制台静默**，需要先恢复原版 `image.ub` 验证是补丁/FIT 还是板子串口问题。
- **下一步架构决定**：若恢复原版后控制台正常，优先改用 **GP0 + PL BRAM 帧缓存**：PS 通过 GP0/AXI 写 2×192 KB BRAM（地址如 `0x42000000`），PL 的 DDR reader 改为从该 BRAM 读取（reader AXI master 接内部 AXI Interconnect + AXI BRAM Controller，不再接 S_AXI_HP0）。这样完全不依赖 HP0/DDR/OCM，PS 的 GP0 已验证可用。代价：BD 增加 interconnect/BRAM controller/BRAM（约 3.1 Mbit，7020 的 BRAM 够用），重新生成 XSA/bitstream/FSBL。

### 13.3 2026-11-03：提交后不锁帧的根因与 RTL 修复（IR 污染）

现象：IR 接地后运行 `hub75_pattern_bram32`，`frame_ack=0`、`frame_id=0`、
`buf_ready=0`；而此前同流程的直接 `devmem` 测试（只写 `frame_base=0x42000000`、
`frame_ctrl=0x4003`，不拷贝帧）能读到 `0x1160D`（`ack=1`、`id=1`、`buf_ready=1`）。

根因（两条都在 IR 上，均为“一次坏输入永久生效”）：

1. **`period_valid` 永久置位 + 无合理性窗口**：IR 浮空时偶尔会出现稀疏边沿。
   一旦凑满 5 个间隔，`period_ticks` 取均值后 `period_valid` 永远为 1。
   裸机日志已有实证：`com11_ir_event.txt` 第 81 行 `period 72636665`（50 MHz
   → 1.45 s）。调度器把它当真实周期 → slot = 72,636,665>>6 = 1,134,947 tick
   ≈ 22.7 ms，64 slot 一圈要 1.45 s；bench 回落 wrap 同样要等 1.45 s，
   PS 在 50 ms 内当然等不到锁帧，看起来像“画面/调度器卡死”。
2. **`ir_seen` 永久置位**：IR-fix 版本用 `revolution_start && period_valid` 置
   `ir_seen`，一旦置位就永久关闭 bench 回落。开机时浮空噪声若产生 ≥7 个边沿，
   回落被永久关闭；之后把 IR 接地不再有边沿，于是**永远没有 rev_event**，
   PS 提交的帧永远不锁存（`id=0`）。这解释了“已接地仍 `ack=0`”。

RTL 修复（回归 7/7 PASS，`sim/run_regression.tcl`）：

- `hub75_ddr_reader`：删除 `ir_seen` 永久锁存，改为 **IR 静默超时**
  `IR_TIMEOUT_CYCLES`（默认 10,000,000 tick = 200 ms @50 MHz）。只有最近
  200 ms 内收到过 IR 边沿才关闭 bench 回落；IR 静默后自动恢复。浮空/接地/
  没接传感器都能自动回到 bench 模式。
- `hub75_sched`：新增 `MIN_PERIOD_CYCLES`/`MAX_PERIOD_CYCLES`（默认
  250,000–50,000,000 tick = 5 ms–1 s，即 60–12000 RPM）。超出窗口的实测周期
  直接回落到 1800 RPM，杜绝“一个坏估计把 slot 拉到几十毫秒”。
- `hub75_system`：status 字新增调试位，便于板上直接判定提交链路：
  `[4] ir_active`、`[5] pending_valid`、`[6] active_valid`、`[7] enable`、
  `[30] submit_toggle`（PL 实际看到的 `frame_ctrl[0]`）、`[31] period_valid`。
- 新增 `sw/linux/hub75_diag.c`：测量 slot 速率、翻转 submit、轮询 2 s 报告
  `pending/active/ack/id/buf_ready` 的变化，一次运行即可区分“PL 没看到提交”
  还是“看到了提交但没有 revolution”。

上板验证顺序：新 bitstream/BOOT → 登录 → `hub75_diag`。判据：
`scheduler ... ~521 us/slot`、`submit` 后 `pend=1`，随后 ≤33 ms 内
`act=1`、`ack` 翻转、`id+1`、`buf_ready=1`。之后才恢复 `hub75_pattern_bram32`
与帧拷贝（拷贝前停 reader 的 `ctrl[2]=0` 会多产生一次 submit 边沿，属于
合法但有副作用；新 diag 用“读回取反”方式提交，不受旧状态影响）。

### 13.4 2026-11-03：新 RTL 上板验证与两个新发现

**验证方法**：由于 Zynq 调试 AHB-AP 禁止访问 PL AXI slave（`PL AXI slave ports access is not allowed`，memmap 也放不开），
改用两种 CPU 真正执行访问的方式：
1. `sw/baremetal/jtag_diag.c`（`build/work/jtag_diag.elf`）：JTAG `dow` 到 DDR、MMU 关、直接寄存器读写，
   时间线写进 DDR 的 `result[]`，调试器 `mrd` 读回。**不需要串口**。
2. Linux 启动后用 `devmem` 走同一串寄存器（`build/reports/diag_devmem2_cmds.txt`）。

**新 RTL 验证结果（bitstream 2026-11-03 01:28，含 IR 超时/周期窗口/调试位）**：
- 裸机：提交（`frame_ctrl=0x3`）→ 状态 `pend=1`，在 `slice 63→0` 的 bench 回落锁存
  → `ack=1、done=1、act=1、id=1`，随后 `reader_busy` 按 slot 脉冲、`buf_ready=1`。
  调度器 slot 由全局定时器测得约 181,345 tick，按 333 MHz 计时 ≈ 544 µs，符合 50 MHz/1800 RPM 回落。
- Linux：同样流程 `ctrl2=0x3` 后状态 `0x400107CD` → `ack=1、buf=1、done=1、act=1、id=1、en=1`，
  40 次 50 ms 采样稳定保持。**帧锁存问题在裸机和 Linux 下都已解决。**

**发现 1：Linux 下 bench 回落看起来比 33 ms 慢**。`hub75_pattern` 提交后 50 ms 读状态为
`pend=1、act=0`（slice=47），说明这一圈还没走到 `63→0`。`devmem` 采样推算约 **1 ms/slot**，
即 Linux 下 FCLK0 可能只有 ~25 MHz，而 RTL 的 `CLK_HZ=50_000_000`。若属实，HUB75 行时序
和刷新率都会减半。下一次上板先读 `/sys/kernel/debug/clk/fclk0/clk_rate`（debugfs）确认；
必要时在 U-Boot/DTB 或用户态把 FPGA0_CLK_CTRL 配回 SRCSEL=IO PLL、DIVISOR0=5、DIVISOR1=4（50 MHz）。

**发现 2：旧 `hub75_pattern` 在 reader 已活跃时运行会触发系统看门狗复位**。
现象：打印 `pattern written ...` 后串口静默；JTAG 读 `REBOOT_STATUS=0x60400000`（bit22 = SWDT 复位），
CPU 已回到 FSBL。裸机复现实验（`sw/baremetal/jtag_copy_diag*.c`）表明：
- reader 停稳后拷贝 192 KiB：正常；
- 不等待 reader 停稳就拷贝：本次未复现；
- 特意等 `busy=1`（AXI 读在途）再禁用并立即拷贝：仍正常。
所以“CPU 写 BRAM + reader 读 BRAM”本身在裸机下不必然死锁，Linux 下的停顿还需要实机定位。
**已实施的防御**：`sw/linux/hub75_pattern.c` 在拷贝前写 `enable=0`，轮询 status 直到
**PL 确认 enable=0（bit7）且 reader_busy=0（bit1）**，再等 2 ms（>1 slot）才开始拷贝；
提交后最多轮询 1 s 等 `ack/id` 变化并打印等待毫秒数。新二进制已重编
（`build/work/vendor_linux/hub75_pattern_bram32`），下次上板验证。

**发现 2.5（2026-11-03 深夜）：`frame_base=0` 会让 reader 读未映射地址，挂死 GP0 → 看门狗复位。**
板上实测：只写 `frame_ctrl=0x3`（提交+使能，**未写 frame_base**，基址仍为 0）
后几秒内 SWDT 复位（`REBOOT_STATUS` bit22）。原因：bench 回落锁存后 reader 以
`active_base=0` 发起 AXI 读，`0x00000000` 不在 PL 的 GP0 地址表里（只映射了
`0x4120_0000` 和 `0x4200_0000`），读事务挂死，PS 之后的 GP0 访问被拖住，
看门狗 10 s 后复位。裸机把同样场景做成 app 时，CPU 也在写结果前就掉进
FSBL 异常向量（数据/预取异常），说明总线确实被挂住。

同时确认 Linux 下时钟没问题：`IO_PLL_CTRL=0x0001E000`（FBDIV=30、bypass=0）、
`PLL_STATUS=0x3F`（锁定）、`FPGA0_CLK_CTRL=0x00400500` → FCLK0=50 MHz。
“提交后 1 s 仍 pend=1/act=0”此前被怀疑为时钟慢，已排除；真实原因是
**frame_base 与 submit 是两个 GPIO 通道，AXI 不保证两者写顺序**：submit 先到
时 reader 锁存到旧基址（开机时是 0），随后读未映射地址把总线挂死。

**修复**：`hub75_ddr_reader` 新增 `FRAME_BASE_MIN/MAX`（默认
`0x4200_0000–0x4207_FFFF`，即帧 BRAM 窗口），窗口外的 submit 不产生
pending；PS 端在写 `frame_base` 后读回并等 2 ms 再发 submit，提交后检查
`pend`（status bit5），未置位则再翻转一次。回归新增“窗口外基址被拒绝”用例。
这样即使顺序颠倒，也只是本次 submit 被忽略并由 PS 重试，不会把 GP0 总线挂死。

**发现 2.6（2026-11-03 深夜）：旧 HP0 设计的动态刷新隐患——HP0 读用了 cacheable 属性。**
git 提交的 `hub75_ddr_reader.v`（HEAD）里 `m_axi_arcache <= 4'b0011`（cacheable），
而裸机渲染器（`sw/renderer/main.c`）在 `Xil_DCacheEnable()` 之后工作：每帧
`Xil_DCacheFlushRange()` + 写 A/B 双缓冲 + 提交。PL 用 cacheable 属性经 HP0 读 DDR，
PS 同时又通过 D-cache 写/清同一 DDR 区域，是 Zynq 上会**死锁 PS 总线**的经典组合。
静态心形/小球只提交一次、之后不再改写 DDR，所以不容易踩到；**动态刷新每帧改写就会踩到**
（与用户观察到的“转一圈/动画跑一会儿后卡死”一致）。
工作区源码已把 ARCACHE 改为 `4'b0010`（non-cacheable），但旧 HP0 bitstream 是修复前编的。
验证方案：用 HEAD 的 HP0 BD/顶层 + 当前（已修复）reader 重编一版 HP0 bitstream，
在裸机下先跑渲染器的静态心形，再跑 `sw/baremetal/ddr_anim.c`（移动竖条、A/B 双缓冲、
逐帧提交）验证动态刷新是否还会挂死。
注意：为 HP0 测试把 reader 的 `FRAME_BASE_MIN/MAX` 临时放宽到 DDR 窗口；
BRAM32 产品版仍用 `0x4200_0000–0x4207_FFFF`。

**验证结果（2026-11-04 凌晨，已确认）**：
- 用 HEAD 的 HP0 BD/顶层 + 当前 reader（`ARCACHE=4'b0010`）重编，板上下载
  `build/work/hub75_ps_stage1_hp0_arcache10.bit`（临时保存名）后：
  - 旧渲染器静态心形正常（`id=1`，面板显示正常）；
  - 把 Vitis 工程 `HUB75_VOLUMETRIC_TEST` 改为 0（原双缓冲逐帧刷新逻辑）重编后，
    **连续 500+ 帧、~19.75 fps、A/B 交替、frame_id 每帧 +1，无卡死无复位**，
    面板动画正常（用户确认“正常”）。
- 结论：**3D 小球/心形渲染逻辑正确；旧 HP0 的 cacheable 读 + PS D-cache 才是
  动态刷新卡死的根因**。`ARCACHE=4'b0010` 修复后动态刷新在裸机下稳定。
- 仓库已恢复为 BRAM32 产品版（BD/顶层/基址窗口/bitstream）；
  带修复的 HP0 bitstream 另存于 `build/work/hub75_ps_stage1_hp0_arcache10.bit`。
- 说明：Vitis 工程副本 `build/work/vitis_sd/hub75_renderer/src/main.c` 当前是
  动态模式（`HUB75_VOLUMETRIC_TEST=0`）；仓库里的 `sw/renderer/main.c` 未改，
  仍默认静态体。

**发现 2.7（2026-11-03 深夜）：Linux 下“写整帧就复位”的根因是看门狗被设备写突发拖住。**
对照实验（同一块板、同一次启动）：
- 空闲 100 秒：uptime 32→133 连续，`[watchdogd]` 内核线程正常喂狗，不复位；
- `hub75_diag`（只写基址+提交+轮询，**无整帧拷贝**）：提交→`pend=1`→下一次
  wrap `ack=1/act=1/id=1`，reader 持续取数，**不复位**；
- `hub75_pattern_bram32`（192 KiB 整帧 GP0 写）：程序跑完后数秒内
  `REBOOT_STATUS` bit22 = **SWDT 复位**。JTAG PC 采样显示复位发生在 CPU
  回到内核 idle 之后约 2.5 s，期间 PC=0xc01168a8（内核 idle）。
结论：单核厂商内核上，持续不断的大突发 strongly-ordered 设备写会拖住
`watchdogd` 线程的喂狗，SWDT（10 s）随后复位。
**修复**：整帧拷贝分块（每 4 KiB `usleep(1000)` 让出 CPU），并用全局定时器
打印拷贝耗时。新 `hub75_pattern_bram32` 已按此重编。

**发现 2.8（2026-11-04 凌晨，最终根因）：所有“卡死/重启”其实都是 POR（上电复位）= 供电不足。**
- `SLCR.REBOOT_STATUS`(0xF8000258) bits[23:16] 是**累积**的复位原因：bit16=SWDT、
  bit19=SLCR 软复位、bit22=**POR**（依据 AMD 论坛与 QEMU Zynq 模型）。我们始终读到
  `0x40`（只有 bit22），**从来没有 bit16** → 从未发生看门狗复位，全是 POR。
- 用 `/dev/watchdog` magic close（`echo V > /dev/watchdog`，`SWDT_CR` 读到 0）
  关掉看门狗后**仍然复位**，且复位点随机（异步电源事件）。
- **换电池供电后一切正常**：帧程序完整跑完、帧锁存（`id=1`）、reader 持续取数、
  控制台 15 s 以上存活、uptime 连续。用户确认面板显示正常。
- 结论：之前的 PSU 在“整帧拷贝突发 + Linux 外设负载”时电压跌落触发 POR。
  也解释了“裸机能跑、Linux 写帧就死、复位点随机”。**产品必须用余量足够的稳定电源。**
- 显示验证：哨兵测试确认帧真的写入 DDR（`0x10000000`/`0x10000004` = `0xFFFFFFFF`，
  即白边框行）；锁存后 `id=1、act=1、buf=1、busy=1`，面板显示白边框+十字+彩条。
  遗留小问题：最右侧竖条显示为黑色（最后一列/burst 边界映射），后续再查。

**发现 3.5（2026-11-04）：Vitis 静态 glibc 是 64-bit time_t 版本，time64 系统调用在 4.14 内核上全部返回 ENOSYS。**
不只是 `clock_gettime`：`usleep/nanosleep`（表现为“睡 0 ms”，提交时序全部失效）、
`select`（`pty selftest` 里 select=-1、errno=38 ENOSYS）也都不可用。
**全部绕开**：
- 计时/延时：直接读 Zynq 全局定时器 `0xF8F00200/204`（333.33 MHz），忙等实现 `sleep_ms`；
- 多路等待：用 `poll()`（只带 int 超时，无 timespec，内核 4.14 支持）；
- 让出 CPU：`sched_yield()`。
`hub75d` 已按此实现并跑通。

**发现 3.6（2026-11-04）：`hub75d` v1（控制台文字模式）跑通。**
- `openpty` + PTY 16×4 + 列镜像修正 + 8×16 点阵字库（`sw/linux/hub75_font.h`，
  由 `build/gen_font.ps1` 从系统 Consolas 生成）；
- VT100 最小解析（打印字符/CR/LF/BS/CSI H J K A B C D）；
- 帧写 DDR A/B 双缓冲（0x10000000/0x10200000），提交时用**物理基址**
  （注意：不能把 mmap 的用户虚拟地址写给 PL，基址窗口检查会拒绝）；
- 面板实测：能看到 shell 提示符 `~#` 和刷新，**Linux shell 文字上屏第一版成功**。
- 启动方式：`/run/media/mmcblk0p1/hub75d`（电池供电）。

**发现 3：静态 glibc 的 `clock_gettime` 在该 4.14 内核上不工作**。
`hub75_diag` 第一版用 `clock_gettime(CLOCK_MONOTONIC)` 做 100 ms 采样窗口，
在板上表现为进程永远不退出（JTAG 看到 CPU 一直在用户态
`main → clock_gettime → __clock_gettime64 → __libc_do_syscall → 内核`）。
原因是内核 4.14 没有 32-bit time64 syscall，静态 glibc 2.35+ 的
`__clock_gettime64` 路径拿不到推进的时间。已改为通过 `/dev/mem` 直接读
Zynq 全局定时器 `0xF8F00200/0xF8F00204`（333.33 MHz tick）计时；
`usleep/nanosleep` 本身正常。以后所有板上计时程序都不要用 `clock_gettime`。

**发现 4：SD 启动不稳定**。多次 `rst -system` 后（
`build/jtag_bt.tcl`）CPU 停在 FSBL 的
`LoadBootImage → SDAccess → XSdPs_ReadPolled → Xil_WaitForEvents`（SD 读超时轮询），
U-Boot/Linux 起不来；同一张卡有时又能正常启动。属于 SD 卡/触点/暖复位状态问题，
需要**断电重上电或重新插拔 SD 卡**。JTAG 的 `rst -por`/`rst -srst` 在该线缆上不支持，无法远程替代断电。

> 上下文约定：后续 Linux 细节写回本文件或独立 `report/linux_*` 文档；对话只保留结论和链接，避免上下文膨胀。可在本文件落盘后执行 `/compact`。

## 14. 阶段性总结（2026-11-04）：Linux 文字上屏跑通

> 本节是这一段工作的**最终结论**；§13.4 早期的看门狗/时钟假设已被 2.8 的 POR 结论取代，
> ARCACHE 修复只对“裸机 HP0 动态刷新”成立，Linux 下的复位是供电问题。

### 14.1 已验证的最终状态

- 板卡：Mizar-Z7（XC7Z020），**电池供电**（此前的 PSU 会在写帧突发时跌落触发 POR）。
- 启动链：厂商 Linux（PetaLinux 2018.3，kernel 4.14）+ 我们的 FSBL/bitstream（HP0 版，
  reader `ARCACHE=4'b0010`），SD 卡 FAT 分区放 `BOOT.bin/image.ub/hub75d/...`。
- 帧路径：PS 写 DDR `0x10000000/0x10200000`（A/B 双缓冲）→ AXI GPIO 提交（物理基址）→
  PL 在 revolution 锁存 → HP0 非 cacheable 取数 → HUB75 扫描。
- 用户态 `hub75d`（`sw/linux/hub75d.c`）：PTY 16×4 + 8×16 字库 + VT100 解析 + 列镜像修正 +
  双缓冲提交。**面板实测能看到 shell 提示符 `~#` 和实时刷新**。
- 启动方式：`/run/media/mmcblk0p1/hub75d`（需要 root）。

### 14.2 根因清单（按验证顺序，含被否定的假设）

| # | 现象 | 结论 | 状态 |
|---|---|---|---|
| 1 | 有 IR 噪声时帧不锁存/画面冻结 | 旧 RTL 的 `ir_seen`/`period_valid` 永久锁存 | 已修（IR 超时 + 周期窗口） |
| 2 | Linux 下提交后 `frame_ack=0` | `frame_base` 与 submit 是两个 GPIO 通道，AXI 不保证写顺序；非法基址让 reader 读未映射地址 | 已修（基址窗口检查 + 写后等待 + pend 重试） |
| 3 | 裸机动态刷新卡死 | 旧 HP0 reader `ARCACHE=4'b0011` cacheable + D-cache 死锁 | 已修（`4'b0010`），裸机 500+ 帧验证 |
| 4 | Linux 下“写帧就卡死/重启”，复位点随机 | **POR（上电复位）= 供电跌落**，不是看门狗/总线（`REBOOT_STATUS` 只有 bit22=POR；关掉 SWDT 仍复位；换电池后全部正常） | **硬件要求：稳定足量电源** |
| 5 | `clock_gettime`/`usleep`/`select` 异常 | Vitis 静态 glibc 是 64-bit time_t，time64 系统调用在 4.14 上返回 ENOSYS | 已绕开（全局定时器 + `poll` + `sched_yield`） |
| 6 | 面板列左右镜像 | 面板/扫描列镜像 | 已修（渲染时反转列） |
| 7 | 最右侧竖条黑 | 最后一列/burst 边界映射（小问题） | 待查 |
| 8 | 热复位后 SD 启动偶发卡死 | FSBL `XSdPs_ReadPolled` 超时轮询 | 断电重上电恢复 |

### 14.3 关键代码/产物

- `sw/linux/hub75d.c` — 控制台文字守护进程（v1）。
- `sw/linux/hub75_font.h` — 8×16 点阵字库（`build/gen_font.ps1` 生成）。
- `sw/linux/hub75_diag.c` — 板上诊断：slot 速率、submit→pend→act/id、wrap 计数、`copy` 耗时。
- `sw/linux/hub75_pattern.c` — 帧写入/提交测试（BRAM/DDR 两个构建）。
- `sw/baremetal/jtag_diag.c`、`jtag_copy_diag.c`、`bram_anim.c`、`ddr_anim.c` — 裸机 JTAG 验证工具。
- `build/work/vendor_linux/` — `BOOT_hub75_bram32_ir4.bin`（BRAM 版）、
  `BOOT_hub75_hp0fix.bin`（HP0 非 cacheable 版）、`hub75d`、`hub75_diag`、`hub75_pattern_ddr`。
- `build/work/hub75_ps_stage1_hp0_arcache10.bit` — 已修复的 HP0 bitstream。

### 14.4 下一步

1. `/etc/hub75.conf` 配置 + `/run/hub75.cmd` 命令接口（mode console/anim、文字、清屏）。
2. 动画即独立可执行文件（写 DDR 帧 + 提交），daemon 让出显示。
3. 开机自启（板上把 `/etc/init.d/S99hub75d` 写入 ext4 根文件系统，自动挂 FAT 并启动）。
4. 字库/字号可读性改进；console3d/volumetric 模式。
5. 右端竖条黑色的小问题。

> 注意：所有板上计时/等待程序不要用 `clock_gettime`/`select`/`usleep`；
> 用全局定时器 + `poll` + `sched_yield`。提交帧必须用物理基址且留 ≥2 ms 让基址先到。

### 14.5 开机自启（2026-11-04）：initramfs 重打包

关键发现：厂商 Linux 的**根文件系统是 initramfs（ramfs，在内存里）**，ext4 分区只是数据盘
（`/proc/mounts` 里 root 是 `rootfs`，`mmcblk0p2` 挂在 `/run/media/mmcblk0p2`）。
所以在板上改 `/etc` 重启即丢——开机自启必须改 `image.ub` 里的 initramfs。

做法（`build/patch_initramfs_autostart.py`）：

1. 从 `image.ub` 的 FIT 里解出 `ramdisk@1`（gzip cpio），解压后按 newc 逐条解析
   （保留每条 header 的 mode/uid/gid/mtime/dev 字段）；
2. 改 `etc/inittab`：`PS0:12345:respawn:/usr/bin/hub75-console`；
3. 新增 `usr/bin/hub75-console`（可执行，mode 0100755）：
   ```sh
   #!/bin/sh
   mkdir -p /run/media/mmcblk0p1
   mount -t vfat /dev/mmcblk0p1 /run/media/mmcblk0p1 2>/dev/null
   if [ -x /run/media/mmcblk0p1/hub75d ]; then
     printf 'shell=/bin/sh\n' > /etc/hub75.conf
     /run/media/mmcblk0p1/hub75d
   fi
   exec /bin/start_getty 115200 ttyPS0 vt102   # fallback：daemon 退出则回登录
   ```
4. 重新打包 cpio → gzip → 替换 FIT `ramdisk@1` 的 `data` 和 `sha1`；
5. 输出 `build/work/vendor_linux/image_autostart.ub`（9,998,820 B），刷到卡上 `image.ub`。

**实测**：上电后自动出现 `hub75d: pty selftest w=12 poll=1 n=12`、`pty [12]`/`pty [8]`、
`submit ... id=0/1`；在串口输入 `echo AUTO_BOOT_OK` → `pty [43]` + 新帧 `id=2`。
即：**开机自动把控制台变成面板 shell 的键盘，面板显示 shell 输出**；daemon 退出自动回退 getty。
原始 `image.ub` 备份在 `build/work/sd_backup/image_before_autostart.ub`。

## 15. USB 键盘 + 持久配置（2026-11-03，**已完成**，任务暂告一段落）

> 状态：USB-A 无线键盘上板可用（用户确认“键盘能用”，含 CapsLock）；
> 冷启动自动恢复逻辑已内置 hub75d。本节记录完整根因与复现步骤，
> 后续如需再动 USB 从这里开始。

目标（用户原话）：板上 USB-A 口接无线键盘直接操作 shell；Linux 里带文本编辑器。
busybox 已内置 `vi`（`/bin/vi`），所以只差 USB 主机链路和持久配置。

### 15.1 PS7/BD：USB0 + 必须保留的 SD0/ENET0

- USB0：`PCW_USB0_PERIPHERAL_ENABLE=1`、`PCW_USB0_USB0_IO {MIO 28 .. 39}`、
  `PCW_USB0_RESET_IO {MIO 46}`、`PCW_USB0_PERIPHERAL_FREQMHZ {60}`（PYNQ 官方 PS7 配置同款）。
- **教训**：HP0 基线取自老提交 `f8388e0` 时，`build/create_ps_bd.tcl` 里 SD0（MIO40..45）
  和 ENET0（MIO16..27 + MDIO52..53）都是关闭的。SD0 关闭则我们的 FSBL 读不了 SD；
  ENET0 关闭则厂商 U-Boot 在 `Net: ZYNQ GEM` 卡死。已在工作区文件补回，构建前务必核对。
- 新 HP0+USB bitstream/XSA：`board/output/hub75_ps_stage1.bit/.xsa`（2026-11-03 06:43 构建成功）。
  reader 基址窗口按 Linux DDR 放宽为 `0x0000_0000–0x1FFF_FFFF`，`ARCACHE=4'b0010`。
- 观察：Vivado 本次出现一次子进程偶发 `ERROR: Failed to create directory 'C'`
  （IP OOC synth 启动时），同批另一个 run 出现同样报错但自行恢复；重跑后成功。
  遇到时先重跑整个构建。

### 15.2 FSBL 重建（Linux 启动链）

启动链仍是：**我们的 FSBL（ps7_init 提供 SD0/ENET0/GP0/HP0/FCLK0/USB0）+ 我们的 bitstream +
厂商 `u-boot.elf`**，U-Boot 再加载厂商 `image.ub`。

- `build/rebuild_fsbl.py` + `build/run_rebuild_fsbl.bat`：从新 XSA 建 Vitis 平台、
  `ps7_uart_1` 作为 FSBL stdout，只构建平台/FSBL（不建 app）。
- FSBL 输出：`build/work/vitis_sd/hub75_sd_platform/export/hub75_sd_platform/sw/boot/fsbl.elf`，
  `build/work/vendor_linux/hub75_linux.bif` 正好引用该路径，随后用 bootgen 打包。
- 注意 Vitis 2026.1 的 XSCT 不可用，脚本走 `vitis.bat -s` 的 Python client。

### 15.3 DTB：打开 USB0（`build/patch_dtb_usb.py`）

厂商 DTB 里 `usb@e0002000` 是 `status="disabled"`、`phy_type="ulpi"`。厂商自己的
`system-user.dtsi` 叠加层写法是：

```dts
usb_phy0: usb_phy@0 {
    compatible = "ulpi-phy";
    #phy-cells = <0>;
    reg = <0xe0002000 0x1000>;
    view-port = <0x170>;
    drv-vbus;
};
&usb0 { dr_mode = "host"; usb-phy = <&usb_phy0>; };
```

`patch_dtb_usb.py` 在 FIT 里做同样的事：usb0 → `okay`/`host`/`usb-phy` 句柄，
根节点下新增 `usb_phy@0`，更新 fdt hash。结构对比确认只有该节点变化、
其余 46 个节点/属性不变；DTB 13217→9219 B 是原厂 DTB 的结构块填充被压紧，不是丢节点。
内核侧已确认厂商 config 内置 `CONFIG_USB=y`、`USB_CHIPIDEA_HOST=y`、`USB_ULPI=y`、
`USB_HID=y`、`INPUT_EVDEV=y`（`vendor_kernel.config`），且 vmlinux 含
`xlnx,zynq-usb-2.20a`、`chipidea,usb2`、`ulpi-phy`、`drv-vbus` 字符串，无需模块。

输出：`build/work/vendor_linux/image_usb_autostart.ub`（在自启版基础上加 USB 补丁）。

### 15.4 hub75d v3（`sw/linux/hub75d.c`）

- **USB 键盘**：扫描 `/dev/input/event*`，用 `EVIOCGBIT` 找带 `KEY_A` 的键盘；
  `poll` 多路复用；热插拔每 2 s 重扫。按 US 布局映射字母/数字/符号、Shift/Caps/Ctrl、
  方向键/Home/End/Delete/PgUp/PgDn（VT100 序列）、Enter=CR、Backspace=0x7f。
  - **关键**：Vitis 静态 glibc 是 64-bit time_t，头文件里的 `struct input_event`
    与 4.14 内核 16 字节记录不一致；代码自己按 16 字节记录解析（sec/usec/type/code/value）。
  - 动画播放中按任意键自动切回 console（杀动画进程并重绘 shell）。
- **持久配置**：优先读 `/run/media/mmcblk0p1/hub75.conf`（FAT，重启不丢），
  再回退 `/etc/hub75.conf`（initramfs，重启即丢）。支持 `anim=`、`shell=`；
  `kill -HUP $(pidof hub75d)` 重载。用户可用 `vi /run/media/mmcblk0p1/hub75.conf` 直接编辑。
- 仍遵守板上约束：不用 `clock_gettime`/`usleep`/`select`，用全局定时器 + `poll` + `sched_yield`；
  提交用物理基址并留 ≥2 ms。

### 15.4.1 上板实测（2026-11-03）：USB PHY 初始化失败的根因与修复

第一次上板：`/dev/input/` 不存在，`/sys/bus/usb/devices/` 为空，
`dmesg` 报：

```
chipidea-usb2 e0002000.usb: e0002000.usb supply vbus not found, using dummy regulator
ci_hdrc ci_hdrc.0: unable to init phy: -110
ci_hdrc: probe of ci_hdrc.0 failed with error -110
```

逐层定位：

1. DTB 补丁已生效：`/proc/device-tree/amba/usb@e0002000/status` = `okay`、
   `dr_mode` = `host`，根节点有 `usb_phy@0`；`ulpi-phy` 与 `chipidea-usb2` 驱动都已绑定。
2. 读 `SLCR.APER_CLK_CTRL`(0xF800012C)：实际 `0x013C044C`，而 ps7_init 写入的是
   `0x017C044D`——**GPIO 的 APER 时钟（bit22）在启动后被内核关掉了**
   （`clk_ignore_unused` 已传但没保住它，DMA bit0 也被关）。
3. 因此 MIO46 的 GPIO 寄存器读写恒为 0：`DIRM_1/OEN_1/DATA_1` 全 0（地址
   `0xE000A20C/0xE000A210/0xE000A044`，bank1 bit14 = MIO46）。
4. ps7_init 把 MIO46 配成 GPIO（`MIO_PIN_46=0x1200`）但**从不写输出值**，
   内核也没人驱动它 → USB PHY 一直处于复位（RESETB 低）→ ULPI viewport 访问超时
   `-110`。

手动验证：`devmem 0xF800012C 32 0x017C044D`（恢复 GPIO 时钟）→ 写
`0xE000A20C/0xE000A210/0xE000A044 = 0x4000`（MIO46 输出高）→ sysfs 重绑
`chipidea-usb2`。PHY 初始化不再报 -110，但随即出现 **中断风暴**
（`unexpected IRQ trap at vector 00` 刷屏，CPU 被占满）。判断是“失败探测后重新
probe”留下的控制器状态问题，不适合作为产品方案。

**最终方案：DTB gpio-hog。** `patch_dtb_usb.py` 在 `gpio@e000a000` 下加：

```dts
usb0-phy-reset {
    gpio-hog;
    gpios = <46 0>;       /* MIO46, active high */
    output-high;
    line-name = "usb0-phy-reset";
};
```

gpiochip 注册时（device_initcall，早于 USB 驱动探测）就把 MIO46 拉高；
之后 APER 时钟被关也不影响已锁存的引脚输出。产物：
`image_usb_autostart.ub` MD5 `35289e87…`。

上板验证判据：`dmesg | grep -i ci_hdrc` 无 -110；`/sys/kernel/debug/gpio`
能看到 `usb0-phy-reset` 为 output-high；插键盘后 `/dev/input/event*` 出现，
hub75d 日志出现 `hub75d: kbd /dev/input/eventN`。

**实测进阶（2026-11-03）**：

- 加 gpio-hog 后**仍偶发** `-110`：同镜像两次冷启动，一次失败、一次成功
  （成功时 dmesg 有 `ULPI transceiver vendor/product ID 0x0424/0x0007`、
  `Found SMSC USB3320 ULPI transceiver`、`ULPI integrity check: passed`，
  随后 `hub 1-0:1.0`、低速键盘枚举）。
- 原理图/手册确认板载 **Microchip USB3320C**，`OTG_nRST = PS_MIO46`
  （手册表格里 MIO8 是笔误），USB-A(J3)/micro(J4) 共用该 PHY；MIO46 有 4.7K 上拉。
- 根因判断：gpiochip 注册（hog 拉高复位）到 chipidea 探测之间间隔太短，
  PHY 复位释放后尚未稳定，`ulpi_viewport_wait()` 2000 µs 轮询超时 → `-110`；
  冷启动时晶振/时钟建立时间存在批次差异。
- **修复：U-Boot 预置。** 厂商 U-Boot 启动脚本支持 `uenvcmd`（在导入 uEnv.txt 后、
  加载内核前执行），且带 `mw` 命令。`uEnv.txt` 增加：

  ```
  uenvcmd=mw.l 0xE000A20C 0x4000; mw.l 0xE000A210 0x4000; mw.l 0xE000A044 0x4000
  ```

  即把 MIO46（GPIO bank1 bit14）设为输出高（GPIO 时钟由 FSBL ps7_init 开启），
  比内核探测早数百毫秒到数秒释放 PHY 复位。gpio-hog 保留作兜底。
- 注意：`uEnv.txt` 现由 `build/flash_usb_boot.ps1` 覆盖管理（含 `maxcpus=1`、
  `uenvcmd`）；`hub75.conf` 仍保留用户已有内容。

**最终根因（2026-11-03 晚，板上寄存器实证）**：

- 即使 U-Boot 提前数百 ms 释放 MIO46，冷启动内核探测仍会 `-110`；而同一镜像下一次
  启动又正常——所以不是单纯的复位释放时序。
- 手动读 ULPI viewport（`0xE0002170`）：
  - 写 WAKEUP(bit31) 后 bit31 能清零；
  - 但任何 READ/WRITE 事务的 RUN(bit30) **永不清零**；
  - bit27 = `ULPI_SYNC_STATE` = 1（PHY 处于正常同步状态）。
  说明**开机第一次 ULPI 访问就把控制器卡死在 RUN 状态**，之后所有事务都排不进去。
- 写 `USBCMD.RST`（`0xE0002140` bit1）控制器软复位后，viewpoint 立即恢复：
  读 ULPI 寄存器 0 返回 `0x24`（USB3320 VID 低字节 0x0424 的低 8 位），
  再 unbind/bind `chipidea-usb2` → `ULPI transceiver vendor/product ID 0x0424/0x0007`、
  `ULPI integrity check: passed`、hub + 键盘完整枚举。此路径无中断风暴
  （此前的中断风暴是“控制器已卡死还强行 probe”的次生现象）。
- **修复：hub75d v3 内置 `usb_recover()`**：启动时若
  `/sys/bus/usb/devices/usb1` 不存在，则通过 `/dev/mem` 写 `USBCMD.RST`，
  再写 `unbind`/`bind` 重绑 `chipidea-usb2` 一次，然后扫描键盘。
  即使内核冷启动探测失败，daemon 也会自动把 USB 救回来。
- 实测：daemon 日志 `hub75d: kbd /dev/input/event0`，用户确认面板键盘输入
  （字母/CapsLock 等）可用。

### 15.5 待上板验证

（USB 部分已按上述完成；以下为历史清单，保留备查。）

1. SD 卡 FAT 根：新 `BOOT.bin`（新 FSBL+bit+vendor U-Boot）、`image.ub`（USB 补丁版）、
   `uEnv.txt`（`mem=256M ...`）、`hub75d` v3、`hub75.conf` 示例、`hub75_anim_heart`。
2. 上电：COM11 应出现 FSBL/U-Boot/Linux；面板自动出现 shell。
3. 插 USB-A 无线键盘（接收器）：串口日志出现 `hub75d: kbd /dev/input/eventN`；
   面板上打字应回显、`ls`/`vi` 可用。
4. `vi /run/media/mmcblk0p1/hub75.conf` 改 `anim=` 后 `kill -HUP $(pidof hub75d)` 或重启验证持久性。

## 16. 显示：可配置字体大小（2026-11-03）

面板固定 128×64；文字网格由字体决定：

| 配置 | 网格 | 内容量 |
|---|---|---|
| `font=8x16` | 16 列 × 4 行 | 64 字符（原有） |
| `font=8x8`（新默认） | 16 列 × 8 行 | 128 字符（翻倍） |

- `hub75.conf` 新增 `font=`；`/etc/hub75.conf` 回退。
  `kill -HUP $(pidof hub75d)` 重载时若字体变化，daemon 会 `TIOCSWINSZ`
  更新 PTY 尺寸并清屏，shell/vi 按新行列工作。
- 8×8 字库 `sw/linux/hub75_font8x8.h`（95 字形 × 8 字节）由
  `build/gen_font8x8.py` 从厂商内核 `lib/fonts/font_8x8.c` 机械提取
  ASCII 32..126：经典 VGA/CP437 控制台字形（IBM PC BIOS 公有领域字形），
  bit7 = 最左像素，与现有渲染器一致。
- 渲染器改造：`g_cols/g_rows/g_char_h/g_font` 运行时变量；文本缓冲
  `[MAX_ROWS=8][MAX_COLS+1=17]`；VT100 光标/清行/Tab 等全部按运行时行列；
  光标块高度随字体。
- 使用：面板上 `vi /run/media/mmcblk0p1/hub75.conf`，把 `font=8x8` 写进去，
  重启或 `kill -HUP $(pidof hub75d)`。
- 待上板验证：刷入新 hub75d（MD5 `ec3fbac4…`）与含 `font=8x8` 的配置，
  确认 16×8 文字、光标和 vi 正常。

## 17. 简单播放接口 `hub75-play`（2026-11-03，已在板上验证）

- 卡 FAT 根新增脚本 `hub75-play`（可执行）：
  - `hub75-play heart`：按 `hub75.conf` 里的 `anim_heart=<路径>` 解析后播放；
  - `hub75-play <路径>`：直接播放该可执行文件；
  - `hub75-play stop`：写 `mode console` 回控制台。
- `hub75.conf` 中的动画映射：
  ```
  anim_heart=/run/media/mmcblk0p1/hub75_anim_heart
  ```
  新增动画 = 把可执行文件放 FAT + 加一行 `anim_<名字>=<路径>` + `hub75-play <名字>`。
- 当前会话用 `ln -sf /run/media/mmcblk0p1/hub75-play /usr/bin/hub75-play`
  让裸命令可用（ramfs，重启丢失；下次重打 image.ub 时把该 ln 加进
  `/usr/bin/hub75-console` 启动脚本即可持久）。
- 板上实测：`hub75-play heart` → daemon 日志 `anim mode -> ...`；
  `hub75-play stop` → `console mode` + 控制台帧提交。

### 17.1 板载编译环境调查（暂不可用）

- 卡上 ext4 分区 `/dev/mmcblk0p2`（挂载 `/run/media/mmcblk0p2`）其实是完整 rootfs，
  带 `gcc-4.9`、`g++`、`make`、`perl`、`python3`、`bash`。
- 但该 ext4 文件系统有错误（内核每次挂载都警告 `mounting fs with errors`，
  `ext4_find_entry ... checksumming directory block`），且动态加载器
  `/lib/arm-linux-gnueabihf/ld-2.19.so` 文件头损坏：
  `7f 41 6c 46`（正常 `7f 45 4c 46`），运行报 `Exec format error`。
- 修复加载器需要向该文件写回 2 字节（被安全策略拦截，需用户明确同意）；
  且 `e2fsck` 在 initramfs 里不存在，无法在板上完整修复文件系统。
- 结论：暂时继续 **PC 交叉编译 + SD 卡传输**；板载 gcc 待文件系统修复后再启用。
- 上板确认（2026-11-03）：`font=8x8` 生效，面板 16×8。
- **`clear` 不全屏清的修复**：busybox `clear` 输出 `ESC[H` + `ESC[J`（不带参数的
  ED），旧解析器只在 `ESC[2J` 时清屏，`ESC[J` 被忽略 → 只光标回左上、旧内容残留。
  已补全 ED/EL 参数：`J` 0/无参=光标到屏尾、1=屏首到光标、2/3=整屏；
  `K` 0=光标到行尾、1=行首到光标、2=整行；并处理 `ESC c`（RIS）整屏复位。
  （不是 PS 写显存的问题。）新 hub75d MD5 `8ff60441…`，待刷入验证。
