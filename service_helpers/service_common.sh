#!/usr/bin/env bash
# Native implementations live under platforms; policy and callers stay shared.
if [[ $(uname -s) == FreeBSD ]]; then
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/platforms/FreeBSD/service_helpers/service_common.sh"
    return $?
fi
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_DIR/logging.sh"
source "$REPO_DIR/service_helpers/distribution.sh"
source "$REPO_DIR/service_helpers/permissions.sh"
source "$REPO_DIR/service_helpers/critical_services.sh"

service_init() {
    [[ $(id -u) == 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
    command -v apt-get >/dev/null || { echo 'Requires Debian/Ubuntu with apt-get.' >&2; exit 1; }
    [[ -d /run/systemd/system ]] || { echo 'Requires a running systemd system.' >&2; exit 1; }
    load_distribution || exit 1
    init_logging
    trap 'log "FAILED at line $LINENO (exit $?)"' ERR
}

install_packages() {
    log "Installing required packages: $*"
    backup_package_configuration || return 1
    apt-get update || return 1
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" || return 1
    log "VERIFIED installed packages: $*"
}

enable_service() {
    local unit
    load_distribution || return 1
    unit=$(distribution_service_unit "$1") || return 1
    backup_system_paths /etc/systemd/system || return 1
    systemctl enable "$unit" || return 1
    refresh_service "$unit" || return 1
    systemctl is-enabled --quiet "$unit" || return 1
    systemctl is-active --quiet "$unit" || return 1
    log "VERIFIED $unit active and enabled at boot"
}

backup_config() {
    local file="$1"
    CONFIG_BACKUP=
    [[ -f "$file" && ! -L "$file" ]] || { log "FAILED expected regular configuration file: $file"; return 1; }
    backup_system_paths "$file" || return 1
    CONFIG_BACKUP="$SYSTEM_BACKUP_DIR/files$file"
}

restore_config() {
    local file="$1" backup="$2"
    audit_file_change "$file" cp -p -- "$backup" "$file" || return 1
    log "RESTORED $file from $backup"
}

set_config_values() {
    local file="$1"; shift
    local setting key value
    for setting in "$@"; do
        key=${setting%%=*}; value=${setting#*=}
        sed -i "/^[[:space:]]*${key}[[:space:]]*=/d" "$file" || return 1
        printf '%s=%s\n' "$key" "$value" >> "$file" || return 1
    done
}

# Never fall back to restarting or starting an inactive daemon.
refresh_service() {
    local unit
    load_distribution || return 1
    unit=$(distribution_service_unit "$1") || return 1
    systemctl is-active --quiet "$unit" || { log "PENDING: $unit is inactive; configuration not applied to a running daemon"; return 1; }
    [[ $(systemctl show --property=CanReload --value "$unit") == yes ]] || {
        log "PENDING: $unit does not support configuration reload"; return 1;
    }
    systemctl reload "$unit" || { log "FAILED: configuration reload for $unit"; return 1; }
    systemctl is-active --quiet "$unit" || return 1
}
