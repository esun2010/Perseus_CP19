#!/bin/sh
# FreeBSD can install Bash using its base shell before entering the shared launcher.
set -eu
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
export PATH
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
case "$(uname -s)" in
    FreeBSD) exec sh "$SCRIPT_DIR/platforms/FreeBSD/bootstrap.sh" "$@" ;;
    Linux) exec bash "$SCRIPT_DIR/run_all.sh" "$@" ;;
    *) echo 'Unsupported operating system.' >&2; exit 1 ;;
esac
