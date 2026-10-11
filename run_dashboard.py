#!/usr/bin/env python3
"""Start the local CyberPatriot Flask dashboard."""
import os

try:
    from webapp.app import app
except ImportError as exc:
    raise SystemExit(f"Could not load the dashboard dependencies: {exc}. Run ./setup.sh to install them.") from None

host = os.environ.get("CYBERPATRIOT_HOST", "127.0.0.1")
port = int(os.environ.get("CYBERPATRIOT_PORT", "5000"))
try:
    app.run(host=host, port=port, debug=False, threaded=True)
except KeyboardInterrupt:
    print("\nDashboard stopped.")
except OSError as exc:
    raise SystemExit(f"Could not start the dashboard at http://{host}:{port}: {exc}") from None
