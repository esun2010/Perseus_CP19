#!/usr/bin/env bash
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_DIR/service_helpers/platform.sh"
source "$REPO_DIR/logging.sh"
source "$REPO_DIR/service_helpers/permissions.sh"
source "$REPO_DIR/service_helpers/critical_services.sh"

service_init() {
    require_freebsd_root || exit 1
    require_commands sysrc service awk mktemp || exit 1
    init_logging
    trap 'log "FAILED at line $LINENO (exit $?)"' ERR
}

install_packages() {
    log "Ensuring required FreeBSD packages: $*"
    ensure_packages "$@" || return 1
    log "VERIFIED installed packages: $*"
}

# Capture before changing either the configuration or its boot setting.
capture_service_state() {
    local name="$1"
    SERVICE_WAS_ENABLED=$(sysrc -n "${name}_enable" 2>/dev/null) || SERVICE_WAS_ENABLED=NO
    SERVICE_WAS_RUNNING=no
    if service "$name" onestatus >/dev/null 2>&1; then SERVICE_WAS_RUNNING=yes; fi
}

# sysrc -l reports its configured rc.conf file list, including custom locations.
set_rc_value() {
    local files
    local -a paths=()
    files=$(sysrc -l) || return 1
    # sysrc itself treats this as a whitespace-separated list, not shell code.
    read -r -a paths <<< "${files//$'\n'/ }"
    ((${#paths[@]})) || { log 'FAILED: sysrc reported no rc.conf files'; return 1; }
    backup_system_paths "${paths[@]}" || return 1
    sysrc "$@"
}

enable_service() {
    local name="$1"
    set_rc_value "${name}_enable=YES" || return 1
    refresh_service "$name" || return 1
    service "$name" onestatus || return 1
    [[ "$(sysrc -n "${name}_enable")" == YES ]] || return 1
    log "VERIFIED $name active and enabled at boot"
}

restore_service_state() {
    local name="$1" enabled="$2" running="$3" status=0
    set_rc_value "${name}_enable=$enabled" || status=1
    if [[ "$running" == yes ]]; then
        refresh_service "$name" || status=1
    elif service "$name" onestatus >/dev/null 2>&1; then
        service "$name" onestop || status=1
    fi
    return "$status"
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
    # Redirection retains the destination's ownership and restrictive mode.
    audit_file_change "$file" copy_config_contents "$backup" "$file" || return 1
    log "RESTORED $file from $backup"
}

copy_config_contents() { cat "$1" > "$2"; }

# Portable key=value editing: retain comments and unrelated configuration.
set_config_values() {
    local file="$1" setting key value temp
    shift
    for setting in "$@"; do
        [[ "$setting" == *=* ]] || return 1
        key=${setting%%=*}; value=${setting#*=}
        [[ "$key" =~ ^[a-zA-Z_][a-zA-Z_0-9]*$ && "$value" != *$'\n'* ]] || return 1
        temp=$(mktemp) || return 1
        if ! awk -v key="$key" '
            { line=$0; sub(/^[ \t]*/, "", line); split(line, parts, "=");
              sub(/[ \t]*$/, "", parts[1]); if (parts[1] != key) print }
        ' "$file" > "$temp"; then rm -f "$temp"; return 1; fi
        printf '%s=%s\n' "$key" "$value" >> "$temp" || { rm -f "$temp"; return 1; }
        cat "$temp" > "$file" || { rm -f "$temp"; return 1; }
        rm -f "$temp" || return 1
    done
}

# FreeBSD sockstat fields: USER COMMAND PID FD PROTO LOCAL-ADDRESS FOREIGN-ADDRESS.
listening_tcp_ports() {
    local command_name="$1" sockets
    sockets=$(sockstat -46l -P tcp) || return 1
    awk -v name="$command_name" '$2 == name && $5 ~ /^tcp/ {
        endpoint=$6; sub(/^.*:/, "", endpoint);
        if (endpoint ~ /^[0-9]+$/) print endpoint
    }' <<< "$sockets" | sort -nu
}

# Use the rc script's reload action only; unsupported reloads remain pending.
refresh_service() {
    local name="$1"
    service "$name" onestatus >/dev/null 2>&1 || {
        log "PENDING: $name is inactive; configuration not applied to a running daemon"; return 1;
    }
    service "$name" onereload || { log "PENDING: reload unsupported or failed for $name"; return 1; }
    service "$name" onestatus || return 1
}
