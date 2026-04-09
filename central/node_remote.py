"""
VP Stage Sync Manager — Node Remote Control
Uses native PowerShell Invoke-Command (no pywinrm dependency).
"""

import subprocess
import tempfile
import json
import logging
import os
import sys
from pathlib import Path

from config import WINRM_USERNAME, WINRM_PASSWORD, WINRM_TIMEOUT

logger = logging.getLogger("node_remote")


def _runtime_root():
    if getattr(sys, "frozen", False):
        return Path(getattr(sys, "_MEIPASS", Path.cwd()))
    return Path(__file__).resolve().parent.parent


_SCRIPTS_DIR = _runtime_root() / "remote_scripts"
_GET_STATUS_PS1 = (_SCRIPTS_DIR / "get_status.ps1").read_text(encoding="utf-8")
_FIX_EDID_SYNC_PS1 = (_SCRIPTS_DIR / "fix_edid_sync.ps1").read_text(encoding="utf-8")


def _run_remote_ps(ip: str, script: str) -> dict:
    """Run a PowerShell script on a remote node via Invoke-Command -FilePath."""
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".ps1", delete=False, encoding="utf-8"
    ) as f:
        f.write(script)
        tmp_path = f.name
    try:
        ps_cmd = f"""
$secpw = ConvertTo-SecureString '{WINRM_PASSWORD}' -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential('{WINRM_USERNAME}', $secpw)
Invoke-Command -ComputerName '{ip}' -Credential $cred -FilePath '{tmp_path}' -ErrorAction Stop
"""
        result = subprocess.run(
            [
                "powershell",
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-Command",
                ps_cmd,
            ],
            capture_output=True,
            text=True,
            timeout=WINRM_TIMEOUT + 10,
        )
        stdout = result.stdout.strip()
        stderr = result.stderr.strip()
        if result.returncode != 0:
            logger.error(f"[{ip}] PS exited {result.returncode}: {stderr[:300]}")
            return {"error": stderr[:300] or f"Exit code {result.returncode}"}
        if not stdout:
            return {"error": "Empty response"}
        return json.loads(stdout)
    except json.JSONDecodeError as e:
        logger.error(f"[{ip}] JSON parse error: {e}")
        return {"error": f"JSON parse: {e}"}
    except subprocess.TimeoutExpired:
        return {"error": "Timeout"}
    except Exception as e:
        logger.error(f"[{ip}] Error: {e}")
        return {"error": str(e)}
    finally:
        try:
            os.unlink(tmp_path)
        except Exception:
            pass


# --------------- Public API ---------------

def get_status(ip: str) -> dict:
    """Get GPU, EDID, and sync status from a remote node."""
    return _run_remote_ps(ip, _GET_STATUS_PS1)


def fix_node(ip: str, output_id: int) -> dict:
    """Run the EDID+sync fix script for a specific output on a remote node."""
    script = f"$OutputId = {output_id}\n" + _FIX_EDID_SYNC_PS1
    return _run_remote_ps(ip, script)


def edid_load(ip: str, output_id: int, edid_base64: str = "") -> dict:
    """Load EDID override on a specific output. If edid_base64 provided, write that EDID."""
    params = f'$Action = "edid_load"\n$OutputId = {output_id}\n$EdidData = "{edid_base64}"\n'
    script = params + _FIX_EDID_SYNC_PS1
    return _run_remote_ps(ip, script)


def edid_unload(ip: str, output_id: int) -> dict:
    """Unload EDID override on a specific output."""
    script = f"$Action = 'edid_unload'\n$OutputId = {output_id}\n" + _FIX_EDID_SYNC_PS1
    return _run_remote_ps(ip, script)


def sync_enable(ip: str) -> dict:
    """Enable frame-lock sync on the node."""
    script = "$Action = 'sync_enable'\n" + _FIX_EDID_SYNC_PS1
    return _run_remote_ps(ip, script)


def sync_disable(ip: str) -> dict:
    """Disable frame-lock sync on the node."""
    script = "$Action = 'sync_disable'\n" + _FIX_EDID_SYNC_PS1
    return _run_remote_ps(ip, script)
