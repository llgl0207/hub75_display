#!/usr/bin/env python3
"""Build a Zynq SD boot image (BOOT.BIN) for the HUB75 PS renderer.

Run through build/run_build_sd_boot.bat so the console code page is UTF-8;
the Vitis 2026.1 Python client reads the server's startup text as UTF-8.

Flow:
  1. create a fresh Vitis workspace under build/work/vitis_sd
  2. create a Zynq platform from board/output/hub75_ps_stage1.xsa
     (the platform builder creates the zynq_fsbl boot domain and its BSP)
  3. create the standalone domain and build the platform (BSP + FSBL)
  4. create an empty app, copy the renderer sources into it, build it
  5. bootgen: BOOT.BIN = FSBL + bitstream + renderer ELF
"""

import glob
import os
import shutil
import stat
import subprocess
import sys

import vitis

REPO = r"C:\Users\210\Documents\intcode\123\hub75_display"
XSA = os.path.join(REPO, "board", "output", "hub75_ps_stage1.xsa")
BIT = os.path.join(REPO, "board", "output", "hub75_ps_stage1.bit")
WORKSPACE = os.path.join(REPO, "build", "work", "vitis_sd")
PLATFORM = "hub75_sd_platform"
DOMAIN = "standalone_a9_0"
APP = "hub75_renderer"
BOOT_BIN = os.path.join(REPO, "board", "output", "BOOT.BIN")
BOOTGEN = r"E:\AMD\2026.1\Vitis\bin\bootgen.bat"
APP_SOURCES = ["main.c", "hub75_frame.c", "hub75_frame.h", "hub75_regs.h"]


def find_one(pattern):
    hits = glob.glob(pattern, recursive=True)
    if not hits:
        return None
    hits.sort(key=os.path.getmtime, reverse=True)
    return hits[0]


def remove_readonly(func, path, exc_info):
    """Vitis leaves read-only headers in the platform export; clear the
    attribute and retry the delete so a rebuild can start from scratch."""
    os.chmod(path, stat.S_IWRITE)
    func(path)


def main():
    if not os.path.isfile(XSA):
        print("ERROR: XSA not found:", XSA)
        return 1
    if not os.path.isfile(BIT):
        print("ERROR: bitstream not found:", BIT)
        return 1

    if os.path.isdir(WORKSPACE):
        shutil.rmtree(WORKSPACE, onexc=remove_readonly)
    os.makedirs(WORKSPACE, exist_ok=True)

    client = vitis.create_client()
    client.set_workspace(WORKSPACE)

    print("== create platform from", XSA)
    platform = client.create_platform_component(name=PLATFORM, hw_design=XSA)
    platform.add_domain(name=DOMAIN, cpu="ps7_cortexa9_0", os="standalone")
    platform.list_domains()

    # The board's CP2102 is on UART1 (MIO48/49). Point both the FSBL and the
    # standalone BSP stdout at it so boot messages are visible on COM11.
    for dname in ("zynq_fsbl", DOMAIN):
        try:
            dom = platform.get_domain(dname)
            print("stdout before", dname, ":", dom.get_config('os', 'standalone_stdout'))
            dom.set_config('os', 'standalone_stdout', 'ps7_uart_1')
            print("stdout after ", dname, ":", dom.get_config('os', 'standalone_stdout'))
        except Exception as exc:
            print("WARN: could not set stdout for", dname, ":", exc)

    print("== build platform (BSP + FSBL)")
    platform.build()

    platform_xpfm = client.find_platform_in_repos(PLATFORM)
    print("== create application", APP)
    app = client.create_app_component(
        name=APP, platform=platform_xpfm, domain=DOMAIN,
        template="empty_application")

    app_src = os.path.join(WORKSPACE, APP, "src")
    if not os.path.isdir(app_src):
        print("ERROR: app src dir not found:", app_src)
        return 1
    for name in APP_SOURCES:
        shutil.copy(os.path.join(REPO, "hub75_renderer", name),
                    os.path.join(app_src, name))
        print("   copied", name)

    print("== build application")
    app.build()

    fsbl = find_one(os.path.join(WORKSPACE, "**", "fsbl.elf"))
    elf = find_one(os.path.join(WORKSPACE, "**", APP + ".elf"))
    print("FSBL:", fsbl)
    print("ELF :", elf)
    if not fsbl or not elf:
        print("ERROR: FSBL or application ELF not found")
        return 1

    bif = os.path.join(WORKSPACE, "boot.bif")
    with open(bif, "w", encoding="ascii") as f:
        f.write("the_ROM_image:\n{\n")
        f.write("    [bootloader] %s\n" % fsbl)
        f.write("    %s\n" % BIT)
        f.write("    %s\n" % elf)
        f.write("}\n")
    print("BIF :", bif)

    cmd = [BOOTGEN, "-image", bif, "-arch", "zynq",
           "-o", BOOT_BIN, "-w", "on"]
    print("== bootgen:", " ".join(cmd))
    subprocess.run(cmd, check=True)
    if not os.path.isfile(BOOT_BIN):
        print("ERROR: bootgen did not produce", BOOT_BIN)
        return 1
    print("BOOT_BIN:", BOOT_BIN, os.path.getsize(BOOT_BIN), "bytes")
    print("SD_BOOT_BUILD_COMPLETE")
    vitis.dispose()
    return 0


if __name__ == "__main__":
    sys.exit(main())
