#!/usr/bin/env bash
# Compatibility entry point: FreeBSD uses native PF.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${BASH:-/usr/local/bin/bash}" "$SCRIPT_DIR/pf.sh" "$@"
