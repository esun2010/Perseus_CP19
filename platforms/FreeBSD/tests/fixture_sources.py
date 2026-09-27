"""Read native/shared sources into the older flat, isolated unit-test fixtures.

Production layout and dispatch are exercised by tests/platform_integration_test.py.
"""
from pathlib import Path

NATIVE = Path(__file__).resolve().parents[1]
SHARED = NATIVE.parents[1]


def read_source(name):
    path = NATIVE / name
    if not path.exists():
        path = SHARED / name
    text = path.read_text()
    # Unit fixtures intentionally place native helpers beside their shared peers.
    text = text.replace('$SCRIPT_DIR/../../../', '$SCRIPT_DIR/../')
    text = text.replace('$COMPONENT_ROOT/../../', '$COMPONENT_ROOT/')
    text = text.replace('REPO_DIR="$(cd "$FREEBSD_DIR/../.." && pwd)"', 'REPO_DIR="$FREEBSD_DIR"')
    return text
