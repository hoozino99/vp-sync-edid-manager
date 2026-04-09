"""
PyInstaller build script for VP Stage Sync Manager.
Produces a single VPSyncManager.exe that includes the FastAPI server,
static assets, config, and remote PowerShell scripts.

Run from the project root:
    python build/build_exe.py
"""

import PyInstaller.__main__
import os

# Ensure we run from project root
project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(project_root)

assets_static = os.path.join(project_root, "central", "static")
assets_config = os.path.join(project_root, "central", "config.py")
assets_node_remote = os.path.join(project_root, "central", "node_remote.py")
assets_remote_scripts = os.path.join(project_root, "remote_scripts")

PyInstaller.__main__.run([
    os.path.join(project_root, "central", "server.py"),
    "--onefile",
    "--name=VPSyncManager",
    f"--add-data={assets_static};static",
    f"--add-data={assets_config};.",
    f"--add-data={assets_node_remote};.",
    f"--add-data={assets_remote_scripts};remote_scripts",
    "--hidden-import=uvicorn",
    "--hidden-import=uvicorn.logging",
    "--hidden-import=uvicorn.loops",
    "--hidden-import=uvicorn.loops.auto",
    "--hidden-import=uvicorn.protocols",
    "--hidden-import=uvicorn.protocols.http",
    "--hidden-import=uvicorn.protocols.http.auto",
    "--hidden-import=uvicorn.protocols.websockets",
    "--hidden-import=uvicorn.protocols.websockets.auto",
    "--hidden-import=uvicorn.lifespan",
    "--hidden-import=uvicorn.lifespan.on",
    "--hidden-import=fastapi",
    "--distpath=dist",
    "--workpath=build/temp",
    "--specpath=build",
    "--noconfirm",
])

print("\nBuild complete! -> dist/VPSyncManager.exe")
