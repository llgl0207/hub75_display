# 2026-11-02T00:51:58.206617700
import vitis

client = vitis.create_client()
client.set_workspace(path="hub75_display")

platform = client.get_component(name="platform")
status = platform.build()

comp = client.get_component(name="hub75_renderer")
comp.build()

vitis.dispose()

