#!/usr/bin/env python3
"""Rebuild the Zynq FSBL from the current stage-1 XSA (Vitis platform only).

The Linux boot chain uses our FSBL (it applies the PS7 configuration: SD0,
ENET0, GP0/HP0, FCLK0 and now USB0) + our bitstream + the vendor U-Boot.
This script recreates the Vitis platform in build/work/vitis_sd so the BIF
at build/work/vendor_linux/hub75_linux.bif picks up the new fsbl.elf.

Run through build/run_rebuild_fsbl.bat (UTF-8 console).
"""
import glob
import os
import shutil
import stat
import sys

import vitis

REPO = r"C:\Users\210\Documents\intcode\123\hub75_display"
XSA = os.path.join(REPO, "board", "output", "hub75_ps_stage1.xsa")
WORKSPACE = os.path.join(REPO, "build", "work", "vitis_sd")
PLATFORM = "hub75_sd_platform"
DOMAIN = "standalone_a9_0"


def find_one(pattern):
    hits = glob.glob(pattern, recursive=True)
    if not hits:
        return None
    hits.sort(key=os.path.getmtime, reverse=True)
    return hits[0]


def remove_readonly(func, path, exc_info):
    os.chmod(path, stat.S_IWRITE)
    func(path)


def main():
    if not os.path.isfile(XSA):
        print("ERROR: XSA not found:", XSA)
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

    for dname in ("zynq_fsbl", DOMAIN):
        try:
            dom = platform.get_domain(dname)
            dom.set_config('os', 'standalone_stdout', 'ps7_uart_1')
        except Exception as exc:
            print("WARN: could not set stdout for", dname, ":", exc)

    print("== build platform (BSP + FSBL)")
    platform.build()

    fsbl = find_one(os.path.join(WORKSPACE, "**", "fsbl.elf"))
    if not fsbl:
        print("ERROR: fsbl.elf not found")
        return 1
    print("FSBL:", fsbl, os.path.getsize(fsbl), "bytes")
    print("FSBL_BUILD_COMPLETE")
    vitis.dispose()
    return 0


if __name__ == "__main__":
    sys.exit(main())
