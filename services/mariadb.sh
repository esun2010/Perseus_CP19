#!/usr/bin/env bash
# MySQL and MariaDB are one protected database family; retain the installed engine.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/mysql.sh" "$@"
