"""
VP Stage Sync Manager — Central Server Configuration
WinRM-based (agentless) architecture.
"""

# Render node definitions: Nodes 1-17, IPs 10.10.10.21 - 10.10.10.37
NODES = [
    {"id": i, "name": f"Node {i:02d}", "ip": f"10.10.10.{20 + i}"}
    for i in range(1, 18)
]

# Central server settings
CENTRAL_HOST = "0.0.0.0"
CENTRAL_PORT = 8500

# WinRM authentication (hardcoded for convenience in local deployment)
WINRM_USERNAME = "AVStumpfl"
WINRM_PASSWORD = "AVStumpfl"
WINRM_TRANSPORT = "ntlm"  # "ntlm" or "kerberos"
WINRM_PORT = 5985  # HTTP (5986 for HTTPS)
WINRM_USE_SSL = False
WINRM_TIMEOUT = 15  # seconds per WinRM operation

# Operational settings
FIX_DELAY_BETWEEN_NODES = 3.0  # seconds between sequential fixes
STATUS_POLL_INTERVAL = 5  # seconds between status polls
