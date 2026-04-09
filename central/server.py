"""
VP Stage Sync & EDID Manager — Central Dashboard Server
FastAPI + WebSocket, PyInstaller-compatible.
"""

import asyncio
import json
import logging
import sys
import threading
import webbrowser
from pathlib import Path
from typing import Dict, List

from fastapi import FastAPI, WebSocket, WebSocketDisconnect, UploadFile, File, Form
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
import base64

import node_remote
from config import NODES, CENTRAL_HOST, CENTRAL_PORT, STATUS_POLL_INTERVAL, FIX_DELAY_BETWEEN_NODES

# ---------- Path setup (PyInstaller compatible) ----------

if getattr(sys, "frozen", False):
    BASE_DIR = Path(getattr(sys, "_MEIPASS", Path.cwd()))
else:
    BASE_DIR = Path(__file__).resolve().parent

STATIC_DIR = BASE_DIR / "static"

# ---------- Logging ----------

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
)
logger = logging.getLogger("server")

# ---------- App ----------

app = FastAPI(title="VP Stage Sync & EDID Manager")
app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")

# ---------- State ----------

node_states: Dict[int, dict] = {}
ws_clients: List[WebSocket] = []


# ---------- Helpers ----------

async def run_in_executor(fn, *args):
    loop = asyncio.get_event_loop()
    return await loop.run_in_executor(None, fn, *args)


async def broadcast(data: dict):
    """Push JSON to all connected WebSocket clients."""
    msg = json.dumps(data)
    disconnected = []
    for ws in ws_clients:
        try:
            await ws.send_text(msg)
        except Exception:
            disconnected.append(ws)
    for ws in disconnected:
        ws_clients.remove(ws)


# ---------- Background poller ----------

async def poll_all_nodes():
    """Fetch status from all 17 nodes and broadcast."""
    while True:
        for node in NODES:
            nid = node["id"]
            ip = node["ip"]
            try:
                result = await run_in_executor(node_remote.get_status, ip)
                result["id"] = nid
                result["name"] = node["name"]
                result["ip"] = ip

                # PS1 sync → UI sync 변환
                sync_data = result.get("sync", {})
                result["sync"] = {
                    "role": "MASTER" if nid == 1 else "SLAVE",
                    "locked": sync_data.get("sync_status") in ("OK", "ACTIVE", "LOCKED"),
                    "synced": sync_data.get("synced", False),
                    "house_sync": sync_data.get("house_sync_incoming", False),
                    "refresh_rate": sync_data.get("refresh_rate", 0),
                    "house_incoming_rate": sync_data.get("house_incoming_rate", 0),
                    "source": sync_data.get("sync_source", "UNKNOWN"),
                    "device_found": sync_data.get("device_found", False),
                }

                # displays → outputs 변환 (connected만 포함)
                displays = result.get("displays", [])
                connected_displays = [d for d in displays if d.get("connected")]
                result["outputs"] = [
                    {
                        "id": d.get("output_id", 0),
                        "name": d.get("port", ""),
                        "connected": True,
                        "edid_loaded": d.get("edid_status") == "OK",
                    }
                    for d in connected_displays
                ]
                result["unused_ports"] = len(displays) - len(connected_displays)

                node_states[nid] = result
            except Exception as e:
                node_states[nid] = {
                    "id": nid,
                    "name": node["name"],
                    "ip": ip,
                    "error": str(e),
                }
        await broadcast({"type": "status", "nodes": list(node_states.values())})
        await asyncio.sleep(STATUS_POLL_INTERVAL)


@app.on_event("startup")
async def on_startup():
    asyncio.create_task(poll_all_nodes())
    # 1초 후 브라우저 자동 열기
    threading.Timer(1.0, lambda: webbrowser.open(f"http://localhost:{CENTRAL_PORT}")).start()


# ---------- Routes ----------

@app.get("/", response_class=HTMLResponse)
async def index():
    html_path = STATIC_DIR / "index.html"
    return HTMLResponse(html_path.read_text(encoding="utf-8"))


@app.get("/api/nodes")
async def api_nodes():
    return list(node_states.values())


def _find_node(node_id: int):
    for n in NODES:
        if n["id"] == node_id:
            return n
    return None


@app.post("/api/nodes/{node_id}/fix")
async def api_fix(node_id: int, output_id: int = 0):
    node = _find_node(node_id)
    if not node:
        return {"error": "Node not found"}
    result = await run_in_executor(node_remote.fix_node, node["ip"], output_id)
    return result


@app.post("/api/nodes/{node_id}/edid/load")
async def api_edid_load(
    node_id: int,
    output_id: int = Form(0),
    edid_file: UploadFile = File(None),
):
    node = _find_node(node_id)
    if not node:
        return {"error": "Node not found"}
    edid_base64 = ""
    if edid_file:
        raw = await edid_file.read()
        edid_base64 = base64.b64encode(raw).decode("ascii")
    return await run_in_executor(node_remote.edid_load, node["ip"], output_id, edid_base64)


@app.post("/api/nodes/{node_id}/edid/unload")
async def api_edid_unload(node_id: int, output_id: int = 0):
    node = _find_node(node_id)
    if not node:
        return {"error": "Node not found"}
    return await run_in_executor(node_remote.edid_unload, node["ip"], output_id)


@app.post("/api/nodes/{node_id}/sync/enable")
async def api_sync_enable(node_id: int):
    node = _find_node(node_id)
    if not node:
        return {"error": "Node not found"}
    return await run_in_executor(node_remote.sync_enable, node["ip"])


@app.post("/api/nodes/{node_id}/sync/disable")
async def api_sync_disable(node_id: int):
    node = _find_node(node_id)
    if not node:
        return {"error": "Node not found"}
    return await run_in_executor(node_remote.sync_disable, node["ip"])


@app.post("/api/fix-all-broken")
async def api_fix_all_broken():
    """Fix all broken nodes sequentially, lowest ID first, 3s delay between."""
    results = []
    sorted_nodes = sorted(node_states.items(), key=lambda x: x[0])
    for nid, state in sorted_nodes:
        if state.get("error") or state.get("broken"):
            node = _find_node(nid)
            if node:
                r = await run_in_executor(node_remote.fix_node, node["ip"], 0)
                results.append({"id": nid, "result": r})
                await asyncio.sleep(FIX_DELAY_BETWEEN_NODES)
    return {"fixed": results}


# ---------- WebSocket ----------

@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    await ws.accept()
    ws_clients.append(ws)
    # Send current state immediately
    if node_states:
        await ws.send_text(
            json.dumps({"type": "status", "nodes": list(node_states.values())})
        )
    try:
        while True:
            await ws.receive_text()  # keep alive
    except WebSocketDisconnect:
        pass
    finally:
        if ws in ws_clients:
            ws_clients.remove(ws)


# ---------- Main ----------

if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host=CENTRAL_HOST, port=CENTRAL_PORT)
