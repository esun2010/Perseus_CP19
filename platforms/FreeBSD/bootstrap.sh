#!/bin/sh
# Base FreeBSD /bin/sh entry point: Bash and sudo are not part of the base OS.
set -eu
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
export PATH
if [ "$(uname -s)" != FreeBSD ]; then
    echo 'This toolkit requires native FreeBSD; no changes were made.' >&2
    exit 1
fi
if [ "$(id -u)" != 0 ]; then
    echo 'Run sh bootstrap.sh from a root shell (su -).' >&2
    exit 1
fi
if [ "$(sysctl -n security.jail.jailed)" != 0 ]; then
    echo 'Run on a FreeBSD host or VM, outside a jail.' >&2
    exit 1
fi
if [ "$#" != 0 ]; then
    echo 'Usage: sh bootstrap.sh (then select tasks interactively)' >&2
    exit 1
fi
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
selection=$(sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//; /^[[:space:]]*$/d' "$SCRIPT_DIR/../../input/distribution.txt")
case "$selection" in auto|freebsd) ;; *) echo 'Select auto or freebsd in input/distribution.txt before bootstrapping.' >&2; exit 1 ;; esac
# Save configuration before the initial pkg/Bash installation can run hooks.
# This runs before Bash exists, so logging.sh cannot be sourced yet.
if ! pkg -N >/dev/null 2>&1 || ! pkg info -e bash >/dev/null 2>&1; then
    umask 077
    for directory in /var /var/backups; do
        [ ! -L "$directory" ] || { echo "Refusing symlink backup parent: $directory" >&2; exit 1; }
    done
    mkdir -p /var/backups
    bootstrap_backup=$(mktemp -d /var/backups/cyberpatriot-bootstrap.XXXXXX)
    chmod 700 "$bootstrap_backup"
    mkdir -p "$bootstrap_backup/files/usr/local"
    cp -pPR /etc "$bootstrap_backup/files/etc"
    if [ -e /usr/local/etc ]; then
        [ ! -L /usr/local/etc ] || { echo 'Refusing symlink configuration directory.' >&2; exit 1; }
        cp -pPR /usr/local/etc "$bootstrap_backup/files/usr/local/etc"
    fi
    touch "$bootstrap_backup/COMPLETE"
    printf 'Configuration backup before bootstrap: %s\n' "$bootstrap_backup"
fi
pkg -N >/dev/null 2>&1 || pkg bootstrap -y
if ! pkg info -e bash >/dev/null 2>&1; then
    pkg install -y bash
fi
exec /usr/local/bin/bash "$SCRIPT_DIR/../../run_all.sh"
