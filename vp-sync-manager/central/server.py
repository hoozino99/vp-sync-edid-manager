"""
VP Stage Sync & EDID Manager — Central Dashboard Server
FastAPI + WebSocket, PyInstaller-compatible.
"""

import asyncio
import json
import logging
import sys
import threading
import time
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
prev_node_states: Dict[int, dict] = {}
ws_clients: List[WebSocket] = []
event_log: List[dict] = []  # max 100 entries

EVENT_LOG_MAX = 100


# ---------- Helpers ----------

def _ts():
    return time.strftime("%H:%M:%S")


def add_event(node_name: str, message: str):
    entry = {"time": _ts(), "node": node_name, "message": message}
    event_log.insert(0, entry)
    if len(event_log) > EVENT_LOG_MAX:
        event_log.pop()
    return entry


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


async def broadcast_log(entries: list):
    await broadcast({"type": "log", "entries": entries})


async def broadcast_alerts(alerts: list):
    await broadcast({"type": "alert", "alerts": alerts})


# ---------- Anomaly detection ----------

def detect_anomalies(nid: int, prev: dict, curr: dict) -> list:
    """Compare prev and curr state, return list of alert strings."""
    alerts = []
    node_name = curr.get("name", f"Node {nid:02d}")

    # error transition
    prev_err = bool(prev.get("error"))
    curr_err = bool(curr.get("error"))
    if curr_err and not prev_err:
        alerts.append(f"went OFFLINE: {curr.get('error', 'unknown')}")

    if not curr_err and not prev_err:
        # sync LOCKED → UNLOCKED
        prev_locked = (prev.get("sync") or {}).get("locked", False)
        curr_locked = (curr.get("sync") or {}).get("locked", False)
        if prev_locked and not curr_locked:
            alerts.append("Sync LOCKED → UNLOCKED")

        # EDID OK → MISSING
        prev_outs = {o.get("name", o.get("id")): o for o in (prev.get("outputs") or [])}
        curr_outs = {o.get("name", o.get("id")): o for o in (curr.get("outputs") or [])}
        for key, co in curr_outs.items():
            po = prev_outs.get(key)
            if po and po.get("edid_loaded") and not co.get("edid_loaded"):
                alerts.append(f"EDID OK → MISSING on {key}")

    return alerts


# ---------- Verify helper ----------

async def verify_after_action(ip: str, node_id: int, node_name: str) -> dict:
    """Wait 2s, re-fetch status, return verified fields."""
    await asyncio.sleep(2)
    try:
        result = await run_in_executor(node_remote.get_status, ip)
        sync_data = result.get("sync", {})
        locked = sync_data.get("sync_status") in ("OK", "ACTIVE", "LOCKED")
        displays = result.get("displays", [])
        connected = [d for d in displays if d.get("connected")]
        all_edid_ok = all(d.get("edid_status") == "OK" for d in connected) if connected else False
        return {
            "verified_sync_status": "LOCKED" if locked else "UNLOCKED",
            "verified_edid_status": "OK" if all_edid_ok else "MISSING",
        }
    except Exception as e:
        return {
            "verified_sync_status": "UNKNOWN",
            "verified_edid_status": "UNKNOWN",
            "verify_error": str(e),
        }


# ---------- Background poller ----------

async def poll_all_nodes():
    """Fetch status from all nodes and broadcast."""
    while True:
        alerts_batch = []
        log_batch = []
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
                        "edid_name": d.get("edid_name", ""),
                    }
                    for d in connected_displays
                ]
                result["unused_ports"] = len(displays) - len(connected_displays)

                new_state = result
            except Exception as e:
                new_state = {
                    "id": nid,
                    "name": node["name"],
                    "ip": ip,
                    "error": str(e),
                }

            # Anomaly detection
            if nid in prev_node_states:
                anomalies = detect_anomalies(nid, prev_node_states[nid], new_state)
                for a in anomalies:
                    alert = {"time": _ts(), "node": new_state.get("name", f"Node {nid:02d}"), "message": a}
                    alerts_batch.append(alert)
                    entry = add_event(alert["node"], f"⚠️ {a}")
                    log_batch.append(entry)

            prev_node_states[nid] = new_state
            node_states[nid] = new_state

        await broadcast({"type": "status", "nodes": list(node_states.values())})
        if alerts_batch:
            await broadcast_alerts(alerts_batch)
        if log_batch:
            await broadcast_log(log_batch)
        await asyncio.sleep(STATUS_POLL_INTERVAL)


@app.on_event("startup")
async def on_startup():
    asyncio.create_task(poll_all_nodes())
    threading.Timer(1.0, lambda: webbrowser.open(f"http://localhost:{CENTRAL_PORT}")).start()


# ---------- Routes ----------

@app.get("/", response_class=HTMLResponse)
async def index():
    html_path = STATIC_DIR / "index.html"
    return HTMLResponse(html_path.read_text(encoding="utf-8"))


@app.get("/api/nodes")
async def api_nodes():
    return list(node_states.values())


@app.get("/api/logs")
async def api_logs():
    return event_log


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

    entry = add_event(node["name"], f"Fix started (output {output_id})")
    await broadcast_log([entry])

    # Attempt fix with retry (max 2 attempts)
    for attempt in range(1, 3):
        result = await run_in_executor(node_remote.fix_node, node["ip"], output_id)

        # Verify
        verified = await verify_after_action(node["ip"], node_id, node["name"])
        result.update(verified)

        success = verified["verified_sync_status"] == "LOCKED" and verified["verified_edid_status"] == "OK"
        if success:
            entry = add_event(node["name"], f"Fix verified OK (attempt {attempt})")
            await broadcast_log([entry])
            result["fix_success"] = True
            return result

        if attempt < 2:
            entry = add_event(node["name"], f"Fix attempt {attempt} failed, retrying...")
            await broadcast_log([entry])
            await asyncio.sleep(2)

    entry = add_event(node["name"], "Fix FAILED after 2 attempts")
    await broadcast_log([entry])
    result["fix_success"] = False
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

    entry = add_event(node["name"], f"EDID Load (output {output_id})")
    await broadcast_log([entry])

    result = await run_in_executor(node_remote.edid_load, node["ip"], output_id, edid_base64)
    verified = await verify_after_action(node["ip"], node_id, node["name"])
    result.update(verified)

    entry = add_event(node["name"], f"EDID Load → {verified['verified_edid_status']}")
    await broadcast_log([entry])
    return result


@app.post("/api/nodes/{node_id}/edid/unload")
async def api_edid_unload(node_id: int, output_id: int = 0):
    node = _find_node(node_id)
    if not node:
        return {"error": "Node not found"}

    entry = add_event(node["name"], f"EDID Unload (output {output_id})")
    await broadcast_log([entry])

    result = await run_in_executor(node_remote.edid_unload, node["ip"], output_id)
    verified = await verify_after_action(node["ip"], node_id, node["name"])
    result.update(verified)

    entry = add_event(node["name"], f"EDID Unload → {verified['verified_edid_status']}")
    await broadcast_log([entry])
    return result


@app.post("/api/nodes/{node_id}/sync/enable")
async def api_sync_enable(node_id: int):
    node = _find_node(node_id)
    if not node:
        return {"error": "Node not found"}

    entry = add_event(node["name"], "Sync Enable")
    await broadcast_log([entry])

    result = await run_in_executor(node_remote.sync_enable, node["ip"])
    verified = await verify_after_action(node["ip"], node_id, node["name"])
    result.update(verified)

    entry = add_event(node["name"], f"Sync Enable → {verified['verified_sync_status']}")
    await broadcast_log([entry])
    return result


@app.post("/api/nodes/{node_id}/sync/disable")
async def api_sync_disable(node_id: int):
    node = _find_node(node_id)
    if not node:
        return {"error": "Node not found"}

    entry = add_event(node["name"], "Sync Disable")
    await broadcast_log([entry])

    result = await run_in_executor(node_remote.sync_disable, node["ip"])
    verified = await verify_after_action(node["ip"], node_id, node["name"])
    result.update(verified)

    entry = add_event(node["name"], f"Sync Disable → {verified['verified_sync_status']}")
    await broadcast_log([entry])
    return result


@app.post("/api/fix-all-broken")
async def api_fix_all_broken():
    """Fix all broken nodes with retry logic."""
    results = []
    sorted_nodes = sorted(node_states.items(), key=lambda x: x[0])
    broken = [(nid, state) for nid, state in sorted_nodes
              if state.get("error") or not (state.get("sync", {}).get("locked", False))
              or not all(o.get("edid_loaded") for o in (state.get("outputs") or []))]

    entry = add_event("System", f"Fix All Broken started ({len(broken)} nodes)")
    await broadcast_log([entry])

    for nid, state in broken:
        node = _find_node(nid)
        if not node:
            continue

        fix_ok = False
        for attempt in range(1, 3):
            r = await run_in_executor(node_remote.fix_node, node["ip"], 0)
            verified = await verify_after_action(node["ip"], nid, node["name"])
            r.update(verified)

            if verified["verified_sync_status"] == "LOCKED" and verified["verified_edid_status"] == "OK":
                fix_ok = True
                entry = add_event(node["name"], f"Fix OK (attempt {attempt})")
                await broadcast_log([entry])
                r["fix_success"] = True
                results.append({"id": nid, "result": r})
                break

            if attempt < 2:
                entry = add_event(node["name"], f"Fix attempt {attempt} failed, retrying...")
                await broadcast_log([entry])
                await asyncio.sleep(2)

        if not fix_ok:
            entry = add_event(node["name"], "Fix FAILED after 2 attempts")
            await broadcast_log([entry])
            r["fix_success"] = False
            results.append({"id": nid, "result": r})

        await asyncio.sleep(FIX_DELAY_BETWEEN_NODES)

    entry = add_event("System", f"Fix All Broken done — {sum(1 for r in results if r['result'].get('fix_success'))} / {len(results)} OK")
    await broadcast_log([entry])
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
    # Send existing logs
    if event_log:
        await ws.send_text(json.dumps({"type": "log", "entries": event_log[:20]}))
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
