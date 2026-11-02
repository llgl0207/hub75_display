# 2026-11-02T01:28:16.268776300
import vitis

client = vitis.create_client()
client.set_workspace(path="hub75_display")

client.delete_component(name="hub75_renderer")

client.delete_component(name="hub75_sd_platform")

