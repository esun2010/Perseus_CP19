#!/usr/bin/env bash
# Native FreeBSD prerequisites shared by every task. Sourcing is side-effect free.
require_freebsd_root() {
    PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
    export PATH
    [[ $(uname -s) == FreeBSD ]] || {
        echo 'This toolkit requires native FreeBSD; no changes were made.' >&2
        return 1
    }
    [[ $(id -u) == 0 ]] || {
        echo 'Run from a root shell (su -), or use sudo if installed.' >&2
        return 1
    }
    [[ $(sysctl -n security.jail.jailed) == 0 ]] || {
        echo 'Run on a FreeBSD host or VM, outside a jail.' >&2
        return 1
    }
    ((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3))) || {
        echo 'Bash 4.3 or newer is required. Run sh bootstrap.sh first.' >&2
        return 1
    }
    umask 077
}

require_commands() {
    local command_name missing=0
    for command_name in "$@"; do
        command -v "$command_name" >/dev/null 2>&1 || {
            printf 'Missing required command: %s\n' "$command_name" >&2
            missing=1
        }
    done
    ((missing == 0))
}

package_installed() {
    pkg info -e "$1" >/dev/null 2>&1
}

ensure_packages() {
    local package
    local -a missing=()
    require_commands pkg || return 1
    if ! pkg -N >/dev/null 2>&1; then
        backup_package_configuration || return 1
        pkg bootstrap -y || return 1
    fi
    for package in "$@"; do
        [[ "$package" =~ ^[A-Za-z0-9][A-Za-z0-9_+.-]*$ ]] || {
            printf 'Invalid package name: %s\n' "$package" >&2
            return 1
        }
        package_installed "$package" || missing+=("$package")
    done
    if ((${#missing[@]})); then
        backup_package_configuration || return 1
        pkg install -y "${missing[@]}" || return 1
    fi
    for package in "$@"; do
        package_installed "$package" || return 1
    done
}
