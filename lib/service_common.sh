#!/usr/bin/env bash
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_DIR/logging.sh"
source "$REPO_DIR/lib/critical_services.sh"

service_init() {
    [[ $(id -u) == 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
    command -v apt-get >/dev/null || { echo 'Requires Debian/Ubuntu with apt-get.' >&2; exit 1; }
    [[ -d /run/systemd/system ]] || { echo 'Requires a running systemd system.' >&2; exit 1; }
    init_logging
    trap 'log "FAILED at line $LINENO (exit $?)"' ERR
}

install_packages() {
    log "Installing required packages: $*"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
    log "VERIFIED installed packages: $*"
}

enable_service() {
    local unit="$1"
    systemctl enable "$unit" || return 1
    systemctl restart "$unit" || return 1
    systemctl is-enabled --quiet "$unit" || return 1
    systemctl is-active --quiet "$unit" || return 1
    log "VERIFIED $unit active and enabled at boot"
}

backup_config() {
    local file="$1"
    CONFIG_BACKUP=$(mktemp "${file}.cp-backup.XXXXXX")
    cp -p -- "$file" "$CONFIG_BACKUP"
    log "BACKUP $file -> $CONFIG_BACKUP"
}

restore_config() {
    local file="$1" backup="$2"
    audit_file_change "$file" cp -p -- "$backup" "$file"
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
