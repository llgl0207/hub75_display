# 2026-11-02T23:58:51.977715700
import vitis

client = vitis.create_client()
client.set_workspace(path="hub75_display")

client.delete_component(name="hub75_sd_platform")

client.delete_component(name="hub75_renderer")

