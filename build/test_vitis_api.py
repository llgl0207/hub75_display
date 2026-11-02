import sys
print("PYTHON_OK", sys.version)
import vitis
print("VITIS_IMPORT_OK")
client = vitis.create_client()
print("CLIENT_OK")
client.set_workspace(r"C:\Users\210\Documents\intcode\123\hub75_display\build\work\vitis_api_test")
print("WORKSPACE_OK")
vitis.dispose()
print("DISPOSE_OK")
