#!/usr/bin/env python3
"""Start the local CyberPatriot Flask dashboard."""
import os
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_ROOT))

try:
    from webapp.app import app
except ImportError as exc:
    raise SystemExit(f"Could not load the dashboard dependencies: {exc}. Run ./setup.sh to install them.") from None

from werkzeug.serving import WSGIRequestHandler


class QuietRequestHandler(WSGIRequestHandler):
    """Keep routine browser polling out of the setup terminal output."""

    def log_request(self, code="-", size="-"):
        pass

host = os.environ.get("CYBERPATRIOT_HOST", "127.0.0.1")
port = int(os.environ.get("CYBERPATRIOT_PORT", "5000"))
if hasattr(os, "geteuid") and os.geteuid() == 0:
    raise SystemExit("Do not run the Flask dashboard as root. Start it with ./setup.sh from your desktop user account.")
try:
    app.run(host=host, port=port, debug=False, threaded=True, request_handler=QuietRequestHandler)
except KeyboardInterrupt:
    print("\nDashboard stopped.")
except OSError as exc:
    raise SystemExit(f"Could not start the dashboard at http://{host}:{port}: {exc}") from None
