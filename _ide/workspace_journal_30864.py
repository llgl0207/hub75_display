# 2026-11-01T22:48:49.043675900
import vitis

client = vitis.create_client()
client.set_workspace(path="hub75_display")

platform = client.create_platform_component(name = "platform",hw_design = "$COMPONENT_LOCATION/../board/output/hub75_ps_stage1.xsa",os = "standalone",cpu = "ps7_cortexa9_0",domain_name = "standalone_ps7_cortexa9_0",compiler = "gcc")

platform = client.get_component(name="platform")
status = platform.build()

comp = client.create_app_component(name="hub75_renderer",platform = "$COMPONENT_LOCATION/../platform/export/platform/platform.xpfm",domain = "standalone_ps7_cortexa9_0")

comp = client.get_component(name="hub75_renderer")
status = comp.import_files(from_loc="", files=["C:\Users\210\Documents\intcode\123\hub75_display\sw\renderer\main.c", "C:\Users\210\Documents\intcode\123\hub75_display\sw\common\hub75_frame.c", "C:\Users\210\Documents\intcode\123\hub75_display\sw\common\hub75_frame.h", "C:\Users\210\Documents\intcode\123\hub75_display\sw\common\hub75_regs.h"], is_skip_copy_sources = False)

status = platform.build()

comp = client.get_component(name="hub75_renderer")
comp.build()

status = platform.build()

comp.build()

status = platform.build()

comp.build()

status = platform.build()

comp.build()

status = platform.build()

comp.build()

status = platform.build()

comp.build()

