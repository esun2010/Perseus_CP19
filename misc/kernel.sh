#!/bin/bash
#check

###############################################################################
# CyberPatriot-safe Linux hardening script (refined, conservative)
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../logging.sh"
SYSCTL_FILE="/etc/sysctl.d/99-hardening.conf"

# Ensure root
if [[ $EUID -ne 0 ]]; then
    echo "Run this script as root."
    exit 1
fi

init_logging

###############################################################################
# Helpers
###############################################################################

ensure_sysctl_file() {
    if [[ ! -d /etc/sysctl.d ]]; then
        mkdir -p /etc/sysctl.d || { log "FAILED creating /etc/sysctl.d"; return 1; }
        log "CREATED directory: /etc/sysctl.d"
    fi
    if [[ ! -f "$SYSCTL_FILE" ]]; then
        touch "$SYSCTL_FILE" || { log "FAILED creating $SYSCTL_FILE"; return 1; }
        log "Created $SYSCTL_FILE"
    fi
}

backup_once() {
    local file="$1"
    local marker="$file.cp_hardened_backup_done"
    if [[ -f "$file" && ! -f "$marker" ]]; then
        local backup="${file}.bak.$(date +%s)"
        cp "$file" "$backup" || { log "FAILED backing up $file"; return 1; }
        log "Backup created: $backup"
        touch "$marker" || { log "FAILED creating $marker"; return 1; }
        log "CREATED backup marker: $marker"
    fi
}

write_sysctl_setting() {
    local key="$1" value="$2"
    sed -i "/^[[:space:]]*${key//./\\.}[[:space:]]*=/d" "$SYSCTL_FILE" || return 1
    echo "$key = $value" >> "$SYSCTL_FILE"
}

add_sysctl_setting() {
    local key="$1"
    local value="$2"

    ensure_sysctl_file || return 1
    backup_once "$SYSCTL_FILE" || return 1
    audit_file_change "$SYSCTL_FILE" write_sysctl_setting "$key" "$value" || return 1

    # Apply immediately, but don't abort on failure
    local old new
    old=$(sysctl -n "$key" 2>/dev/null) || old="<unavailable>"
    if sysctl -w "$key=$value" >/dev/null 2>&1; then
        new=$(sysctl -n "$key" 2>/dev/null) || new="<unavailable>"
        [[ "$old" == "$new" ]] || log "CHANGED runtime sysctl: $key: $old -> $new"
    else
        log "WARNING: Failed to apply sysctl at runtime: $key"
    fi
}

###############################################################################
# Sysctl hardening (conservative)
###############################################################################

log "Applying sysctl hardening..."

# IPv4 network hardening
add_sysctl_setting net.ipv4.tcp_syncookies 1
add_sysctl_setting net.ipv4.conf.all.rp_filter 1
add_sysctl_setting net.ipv4.conf.default.rp_filter 1
add_sysctl_setting net.ipv4.conf.all.accept_redirects 0
add_sysctl_setting net.ipv4.conf.default.accept_redirects 0
add_sysctl_setting net.ipv4.conf.all.accept_source_route 0
add_sysctl_setting net.ipv4.conf.default.accept_source_route 0
add_sysctl_setting net.ipv4.conf.all.log_martians 1
add_sysctl_setting net.ipv4.conf.default.log_martians 1
add_sysctl_setting net.ipv4.icmp_echo_ignore_broadcasts 1
add_sysctl_setting net.ipv4.icmp_ignore_bogus_error_responses 1
add_sysctl_setting net.ipv4.tcp_rfc1337 1
add_sysctl_setting net.ipv4.conf.all.send_redirects 0
add_sysctl_setting net.ipv4.conf.default.send_redirects 0

# NOTE: ip_forward can be scenario-dependent (routing/VPN/NAT).
# For CyberPatriot, it's safer to NOT force it unless you know it's not needed.
# Uncomment only if the scenario clearly does NOT require routing:
# add_sysctl_setting net.ipv4.ip_forward 0

# IPv6 – light hardening, do NOT disable IPv6
add_sysctl_setting net.ipv6.conf.all.accept_redirects 0
add_sysctl_setting net.ipv6.conf.default.accept_redirects 0

# Kernel info leak / memory protections
add_sysctl_setting kernel.kptr_restrict 1
add_sysctl_setting kernel.randomize_va_space 2
add_sysctl_setting kernel.dmesg_restrict 1
add_sysctl_setting kernel.yama.ptrace_scope 1
add_sysctl_setting fs.suid_dumpable 0

log "Sysctl hardening complete."

###############################################################################
# /tmp and /dev/shm hardening
###############################################################################

harden_mountpoint() {
    local path="$1"
    local label="$2"

    log "Hardening $path..."

    if [[ -d "$path" ]]; then
        audit_chmod 1777 "$path"
    fi

    if mountpoint -q "$path"; then
        local old new
        old=$(findmnt -n -o OPTIONS --target "$path") || old="<unavailable>"
        if mount -o remount,noexec,nosuid,nodev "$path" 2>/dev/null; then
            new=$(findmnt -n -o OPTIONS --target "$path") || new="<unavailable>"
            log "REMOUNTED $path: $old -> $new"
        else
            log "WARNING: Failed to remount $path with noexec,nosuid,nodev"
        fi
    else
        log "NOTE: $path is not a mountpoint; skipping remount."
    fi
}

write_fstab_entry() {
    local path="$1" fstab="$2"
    local temp
    temp=$(mktemp "${fstab}.XXXXXX") || return 1
    # Preserve ownership and permissions when replacing fstab.
    cp -p -- "$fstab" "$temp" || { rm -f -- "$temp"; return 1; }
    awk -v tgt="$path" '
    $2 == tgt && $1 !~ /^#/ {
        n=split($4, a, ",")
        delete seen
        opts=""
        for (i=1; i<=n; i++) {
            if (!seen[a[i]]++) opts=opts (opts == "" ? "" : ",") a[i]
        }
        n=split("noexec,nosuid,nodev", a, ",")
        for (i=1; i<=n; i++) {
            if (!seen[a[i]]++) opts=opts (opts == "" ? "" : ",") a[i]
        }
        if ($4 != opts) $4=opts
    }
    {print}
    ' "$fstab" > "$temp" && mv -- "$temp" "$fstab" && return 0
    rm -f -- "$temp"
    return 1
}

harden_fstab_entry() {
    local path="$1"
    local fstab="/etc/fstab"

    backup_once "$fstab" || return 1

    if grep -qE "^[^#].*\s${path//\//\\/}\s" "$fstab"; then
        audit_file_change "$fstab" write_fstab_entry "$path" "$fstab"
    else
        log "No explicit $path entry in /etc/fstab; leaving as-is."
    fi
}

harden_mountpoint /tmp "/tmp"
harden_fstab_entry /tmp

harden_mountpoint /dev/shm "/dev/shm"
harden_fstab_entry /dev/shm

###############################################################################
# Final log
###############################################################################

log "Hardening script finished. Review $LOG_FILE and test services (SSH, web, DB, etc.)."
echo "[+] Hardening complete. Reboot recommended after verifying services."
