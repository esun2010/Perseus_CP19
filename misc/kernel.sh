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
        audit_file_change "$SYSCTL_FILE" touch "$SYSCTL_FILE" || { log "FAILED creating $SYSCTL_FILE"; return 1; }
        log "Created $SYSCTL_FILE"
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
# Administrator allowlist: sudoers and polkit
###############################################################################

load_admin_allowlist() {
    local file="$SCRIPT_DIR/../input/auth_admins.txt" line uid
    ADMIN_USERS=()
    [[ -r "$file" ]] || { log "FAILED: cannot read $file"; return 1; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        # Keep generated sudoers and JavaScript free of injected syntax.
        [[ "$line" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*[$]?$ ]] || {
            log "FAILED: invalid administrator username: $line"; return 1;
        }
        uid=$(id -u -- "$line") || { log "FAILED: account does not exist: $line"; return 1; }
        if [[ "$uid" == 0 ]]; then
            [[ "$line" == root ]] || { log "FAILED: unexpected UID-zero account: $line"; return 1; }
            continue
        fi
        [[ " ${ADMIN_USERS[*]} " == *" $line "* ]] || ADMIN_USERS+=("$line")
    done < "$file"
    ((${#ADMIN_USERS[@]} > 0)) || {
        log "FAILED: auth_admins.txt must contain at least one existing non-root administrator"; return 1;
    }
}

write_admin_sudoers() {
    local user
    cat <<'SUDOERS'
# Managed by misc/kernel.sh using input/auth_admins.txt.
# Deliberately no include directives: old grants must not bypass the allowlist.
Defaults env_reset
Defaults use_pty
Defaults timestamp_timeout=0
root ALL=(ALL:ALL) ALL
SUDOERS
    for user in "${ADMIN_USERS[@]}"; do
        printf '%s ALL=(ALL:ALL) PASSWD: ALL\n' "$user"
    done
}

write_admin_polkit() {
    local user
    cat <<'POLKIT'
// Managed by misc/kernel.sh using input/auth_admins.txt.
polkit.addAdminRule(function(action, subject) {
    return ["unix-user:root"
POLKIT
    for user in "${ADMIN_USERS[@]}"; do
        printf '        , "unix-user:%s"\n' "$user"
    done
    cat <<'POLKIT'
    ];
});
POLKIT
}

# Write beside the destination, then rename to avoid exposing partial policies.
install_admin_policy() {
    local source="$1" target="$2" mode="$3" temporary
    temporary=$(mktemp "${target}.tmp.XXXXXX") || return 1
    if install -o root -g root -m "$mode" -- "$source" "$temporary" &&
       mv -f -- "$temporary" "$target"; then
        return 0
    fi
    rm -f -- "$temporary"
    return 1
}

configure_admin_access() {
    local sudoers=/etc/sudoers rules_dir=/etc/polkit-1/rules.d
    local rule_name=00-cyberpatriot-admins.rules rule backup file name
    local had_rule=0 failed=0
    rule="$rules_dir/$rule_name"
    load_admin_allowlist || return 1
    command -v visudo >/dev/null || { log "FAILED: visudo is required"; return 1; }
    command -v pkaction >/dev/null || { log "FAILED: polkit is required"; return 1; }
    # Require the JavaScript rules backend; do not write ineffective legacy rules.
    [[ -d /usr/share/polkit-1/rules.d ]] || {
        log "FAILED: polkit JavaScript rules support is required"; return 1;
    }
    [[ -f "$sudoers" && ! -L "$sudoers" && ! -L "$rules_dir" && ! -L "$rule" ]] || {
        log "FAILED: unexpected sudoers or polkit file layout"; return 1;
    }
    [[ ! -e "$rule" || -f "$rule" ]] || { log "FAILED: $rule is not a regular file"; return 1; }
    visudo -c || { log "FAILED: existing sudoers configuration is invalid"; return 1; }
    # Any earlier rule could install an administrator override. Fail for review.
    local LC_ALL=C
    for file in "$rules_dir"/*.rules /usr/share/polkit-1/rules.d/*.rules; do
        [[ -e "$file" ]] || continue
        name=${file##*/}
        if [[ "$name" < "$rule_name" ]]; then
            log "FAILED: polkit rule sorts before our allowlist; review $file"; return 1
        fi
    done
    backup=$(mktemp -d /var/backups/cyberpatriot-admin-access.XXXXXX) || return 1
    chmod 700 "$backup" || return 1
    cp -p -- "$sudoers" "$backup/sudoers" || return 1
    if [[ -e "$rule" ]]; then
        cp -p -- "$rule" "$backup/polkit.rules" || return 1
        had_rule=1
    fi
    log "Administrator policy backups: $backup (root-only)"
    write_admin_sudoers > "$backup/new-sudoers" || return 1
    write_admin_polkit > "$backup/new-polkit.rules" || return 1
    visudo -cf "$backup/new-sudoers" || {
        log "FAILED: generated sudoers did not validate; policies unchanged"; return 1;
    }
    mkdir -p -- "$rules_dir" || return 1
    # Backups are retained even after success. Restore both policies on failure.
    audit_file_change "$sudoers" install_admin_policy "$backup/new-sudoers" "$sudoers" 0440 || failed=1
    if ((failed == 0)); then
        visudo -c || failed=1
    fi
    if ((failed == 0)); then
        audit_file_change "$rule" install_admin_policy "$backup/new-polkit.rules" "$rule" 0644 || failed=1
    fi
    if ((failed)); then
        log "FAILED configuring administrator access; restoring policies from $backup"
        audit_file_change "$sudoers" install_admin_policy "$backup/sudoers" "$sudoers" 0440 || {
            log "CRITICAL: restore $backup/sudoers to $sudoers manually"; return 1;
        }
        if ((had_rule)); then
            audit_file_change "$rule" install_admin_policy "$backup/polkit.rules" "$rule" 0644 || return 1
        else
            audit_file_change "$rule" rm -f -- "$rule" || return 1
        fi
        visudo -c || log "CRITICAL: restored sudoers failed validation"
        return 1
    fi
    log "Configured sudo and polkit administrators: root ${ADMIN_USERS[*]}"
    log "Existing sudoers includes are now inactive; polkit reloads rules automatically"
    log "Polkit action rules granting access without administrator authentication remain separate; review local YES rules"
}

configure_admin_access || exit 1

###############################################################################
# Sysctl hardening (conservative)
###############################################################################

log "Applying sysctl hardening..."

# IPv4 network hardening
add_sysctl_setting net.ipv4.tcp_syncookies 1 || exit 1
add_sysctl_setting net.ipv4.conf.all.rp_filter 1 || exit 1
add_sysctl_setting net.ipv4.conf.default.rp_filter 1 || exit 1
add_sysctl_setting net.ipv4.conf.all.accept_redirects 0 || exit 1
add_sysctl_setting net.ipv4.conf.default.accept_redirects 0 || exit 1
add_sysctl_setting net.ipv4.conf.all.accept_source_route 0 || exit 1
add_sysctl_setting net.ipv4.conf.default.accept_source_route 0 || exit 1
add_sysctl_setting net.ipv4.conf.all.log_martians 1 || exit 1
add_sysctl_setting net.ipv4.conf.default.log_martians 1 || exit 1
add_sysctl_setting net.ipv4.icmp_echo_ignore_broadcasts 1 || exit 1
add_sysctl_setting net.ipv4.icmp_ignore_bogus_error_responses 1 || exit 1
add_sysctl_setting net.ipv4.tcp_rfc1337 1 || exit 1
add_sysctl_setting net.ipv4.conf.all.send_redirects 0 || exit 1
add_sysctl_setting net.ipv4.conf.default.send_redirects 0 || exit 1

# NOTE: ip_forward can be scenario-dependent (routing/VPN/NAT).
# For CyberPatriot, it's safer to NOT force it unless you know it's not needed.
# Uncomment only if the scenario clearly does NOT require routing:
# add_sysctl_setting net.ipv4.ip_forward 0

# IPv6 – light hardening, do NOT disable IPv6
add_sysctl_setting net.ipv6.conf.all.accept_redirects 0 || exit 1
add_sysctl_setting net.ipv6.conf.default.accept_redirects 0 || exit 1

# Kernel info leak / memory protections
add_sysctl_setting kernel.kptr_restrict 1 || exit 1
add_sysctl_setting kernel.randomize_va_space 2 || exit 1
add_sysctl_setting kernel.dmesg_restrict 1 || exit 1
add_sysctl_setting kernel.yama.ptrace_scope 1 || exit 1
add_sysctl_setting fs.suid_dumpable 0 || exit 1

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

    if grep -qE "^[^#].*\s${path//\//\\/}\s" "$fstab"; then
        audit_file_change "$fstab" write_fstab_entry "$path" "$fstab"
    else
        log "No explicit $path entry in /etc/fstab; leaving as-is."
    fi
}

harden_mountpoint /tmp "/tmp" || exit 1
harden_fstab_entry /tmp || exit 1

harden_mountpoint /dev/shm "/dev/shm" || exit 1
harden_fstab_entry /dev/shm || exit 1

###############################################################################
# Final log
###############################################################################

log "Hardening script finished. Review $LOG_FILE and test services (SSH, web, DB, etc.)."
echo "[+] Hardening complete. Reboot recommended after verifying services."
