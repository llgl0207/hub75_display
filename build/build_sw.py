#!/usr/bin/env python3
"""Create the Vitis 2026.1 platform and Stage 0 Hello World application.

Run from the repository root with the Vitis Python launcher:

    E:\\AMD\\2026.1\\Vitis\\bin\\vitis.bat -s build\\build_sw.py

XSCT is disabled in Vitis 2026.1, so this uses the supported Vitis Python API
(see E:\\AMD\\2026.1\\Vitis\\cli\\examples\\embedded\\platform_uc4_zynq.py).

The platform is created from the Stage 0 XSA (PS-only: UART0 + DDR3). The
Hello World app is linked to DDR by the default BSP linker script; its UART
output proves PS boot, UART0 MIO14/15 and DDR access. A later renderer app
will reuse the same platform.
"""

import os
import shutil
import sys

import vitis

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
XSA = os.path.join(REPO, "board", "output", "hub75_ps_stage0.xsa")
WORKSPACE = os.path.join(REPO, "build", "work", "vitis_ws")
PLATFORM_NAME = "hub75_platform"
DOMAIN_NAME = "standalone_a9_0"
APP_NAME = "hub75_hello"


def main():
    if not os.path.isfile(XSA):
        print("ERROR: XSA not found: %s" % XSA)
        print("Run build/build_ps_system.tcl first.")
        return 1

    if os.path.isdir(WORKSPACE):
        shutil.rmtree(WORKSPACE)
    os.makedirs(WORKSPACE, exist_ok=True)

    client = vitis.create_client()
    client.set_workspace(WORKSPACE)

    print("Creating platform %s from %s" % (PLATFORM_NAME, XSA))
    platform = client.create_platform_component(name=PLATFORM_NAME, hw_design=XSA)
    platform.add_domain(name=DOMAIN_NAME, cpu="ps7_cortexa9_0", os="standalone")
    platform.build()
    print("PLATFORM_BUILD_COMPLETE %s" % PLATFORM_NAME)

    platform_xpfm = client.find_platform_in_repos(PLATFORM_NAME)
    print("Creating application %s" % APP_NAME)
    app = client.create_app_component(
        name=APP_NAME,
        platform=platform_xpfm,
        domain=DOMAIN_NAME,
        template="hello_world",
    )
    app.build()
    print("APP_BUILD_COMPLETE %s" % APP_NAME)
    print("WORKSPACE=%s" % WORKSPACE)

    vitis.dispose()
    return 0


if __name__ == "__main__":
    sys.exit(main())
