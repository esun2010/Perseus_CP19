#!/usr/bin/env bash
# FreeBSD kernel, administrator-policy, and temporary-filesystem hardening.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../service_helpers/platform.sh"
require_freebsd_root
source "$SCRIPT_DIR/../../../main/logging.sh"
init_logging
require_commands sysctl pw mount awk install
mkdir -p /var/backups
backup=$(mktemp -d /var/backups/cyberpatriot-kernel.XXXXXX)
log "Hardening configuration backups: $backup"

load_admin_allowlist() {
    local file="$SCRIPT_DIR/../../../input/auth_admins.txt" line uid
    ADMIN_USERS=()
    [[ -r "$file" ]] || { log "FAILED: cannot read $file"; return 1; }
    local skip_password=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if ((skip_password)); then skip_password=0; continue; fi
        line=${line%$'\r'}
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        skip_password=1
        [[ "$line" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*[$]?$ ]] || {
            log "FAILED: invalid administrator username: $line"; return 1;
        }
        pw usershow -n "$line" >/dev/null 2>&1 || {
            log "FAILED: local administrator does not exist: $line"; return 1;
        }
        uid=$(id -u "$line") || return 1
        if [[ "$uid" == 0 ]]; then
            [[ "$line" == root ]] || { log "FAILED: unexpected UID-zero account: $line"; return 1; }
            continue
        fi
        [[ " ${ADMIN_USERS[*]} " == *" $line "* ]] || ADMIN_USERS+=("$line")
    done < "$file"
    ((${#ADMIN_USERS[@]} > 0)) || {
        log 'FAILED: auth_admins.txt must contain an existing non-root administrator'; return 1;
    }
}

install_policy() {
    local source_file="$1" target="$2" mode="$3" temporary
    backup_system_paths "$target" || return 1
    temporary=$(mktemp "${target}.XXXXXX") || return 1
    if install -o root -g wheel -m "$mode" "$source_file" "$temporary" && mv -f "$temporary" "$target"; then
        return 0
    fi
    rm -f "$temporary"
    return 1
}

configure_admin_access() {
    local sudoers=/usr/local/etc/sudoers rules_dir=/usr/local/etc/polkit-1/rules.d
    local rule_name=00-cyberpatriot-admins.rules rule user file name
    local had_rule=0 with_polkit=0 failed=0
    rule="$rules_dir/$rule_name"
    load_admin_allowlist || return 1
    ensure_packages sudo || return 1
    require_commands visudo || return 1
    [[ -f "$sudoers" && ! -L "$sudoers" ]] || {
        log 'FAILED: unexpected sudoers file layout'; return 1;
    }
    visudo -c || { log 'FAILED: existing sudoers is invalid'; return 1; }
    if package_installed polkit; then
        with_polkit=1
        [[ -d /usr/local/share/polkit-1/rules.d && ! -L /usr/local/etc/polkit-1 && ! -L "$rules_dir" && ! -L "$rule" ]] || {
            log 'FAILED: unexpected polkit JavaScript rules layout'; return 1;
        }
        [[ ! -e "$rule" || -f "$rule" ]] || return 1
        local LC_ALL=C
        for file in "$rules_dir"/*.rules /usr/local/share/polkit-1/rules.d/*.rules; do
            [[ -e "$file" ]] || continue
            name=${file##*/}
            if [[ "$name" < "$rule_name" ]]; then
                log "FAILED: polkit rule precedes the allowlist; review $file"; return 1
            fi
        done
        install -d -o root -g wheel -m 755 "$rules_dir" || return 1
        if [[ -e "$rule" ]]; then
            cp -p "$rule" "$backup/polkit.rules" || return 1
            had_rule=1
        fi
        {
            printf '// Managed by misc/kernel.sh from input/auth_admins.txt.\n'
            printf 'polkit.addAdminRule(function(action, subject) {\n    return ["unix-user:root"'
            for user in "${ADMIN_USERS[@]}"; do printf ', "unix-user:%s"' "$user"; done
            printf '];\n});\n'
        } > "$backup/new-polkit.rules" || return 1
    fi
    cp -p "$sudoers" "$backup/sudoers" || return 1
    {
        printf '# Managed by misc/kernel.sh from input/auth_admins.txt.\n'
        printf '# Old include directives are deliberately inactive.\n'
        printf 'Defaults env_reset\nDefaults use_pty\nDefaults timestamp_timeout=0\n'
        printf 'root ALL=(ALL:ALL) ALL\n'
        for user in "${ADMIN_USERS[@]}"; do printf '%s ALL=(ALL:ALL) PASSWD: ALL\n' "$user"; done
    } > "$backup/new-sudoers" || return 1
    visudo -cf "$backup/new-sudoers" || return 1
    audit_file_change "$sudoers" install_policy "$backup/new-sudoers" "$sudoers" 0440 || failed=1
    if ((failed == 0)); then visudo -c || failed=1; fi
    if ((failed == 0 && with_polkit)); then
        audit_file_change "$rule" install_policy "$backup/new-polkit.rules" "$rule" 0644 || failed=1
    fi
    if ((failed)); then
        log "FAILED configuring administrator access; restoring from $backup"
        install_policy "$backup/sudoers" "$sudoers" 0440 || log 'CRITICAL: restore sudoers manually'
        if ((with_polkit)); then
            if ((had_rule)); then install_policy "$backup/polkit.rules" "$rule" 0644 || return 1
            else audit_file_change "$rule" rm -f "$rule" || return 1; fi
        fi
        return 1
    fi
    log "Configured sudo administrators: root ${ADMIN_USERS[*]}; old sudoers includes are inactive"
    if ((with_polkit)); then
        log 'Configured installed polkit administrator identities; review separate action rules granting YES access'
    else
        log 'Polkit is not installed; no desktop authorization policy was created'
    fi
    log 'Wheel membership is managed by user_management; review any independent doas policy separately'
}
configure_admin_access

SYSCTL_FILE=/etc/sysctl.conf
[[ ! -L "$SYSCTL_FILE" ]] || { log 'FAILED: sysctl.conf is a symbolic link'; exit 1; }
if [[ -e "$SYSCTL_FILE" ]]; then cp -p "$SYSCTL_FILE" "$backup/sysctl.conf"
else audit_file_change "$SYSCTL_FILE" install -o root -g wheel -m 644 /dev/null "$SYSCTL_FILE"; fi

write_sysctl_setting() {
    local key="$1" value="$2" temporary
    temporary=$(mktemp /etc/.sysctl.conf.XXXXXX) || return 1
    if ! awk -v key="$key" -v value="$value" '
        /^[[:space:]]*#/ { print; next }
        { candidate=$0; sub(/=.*/, "", candidate); gsub(/[[:space:]]/, "", candidate)
          if (candidate != key) print }
        END { print key "=" value }
    ' "$SYSCTL_FILE" > "$temporary"; then rm -f "$temporary"; return 1; fi
    if chown root:wheel "$temporary" && chmod 644 "$temporary" && mv -f "$temporary" "$SYSCTL_FILE"; then return 0; fi
    rm -f "$temporary"
    return 1
}
apply_sysctl_setting() {
    local key="$1" value="$2" old new
    if ! old=$(sysctl -n "$key" 2>/dev/null); then
        log "SKIPPED unavailable kernel setting on this architecture/release: $key"
        return 0
    fi
    if ! sysctl "$key=$value" >/dev/null; then
        log "FAILED applying kernel setting: $key (not persisted)"; return 1
    fi
    new=$(sysctl -n "$key") || return 1
    [[ "$new" == "$value" ]] || { log "FAILED verifying $key"; return 1; }
    if ! audit_file_change "$SYSCTL_FILE" write_sysctl_setting "$key" "$value"; then
        sysctl "$key=$old" >/dev/null || log "CRITICAL: failed restoring runtime value $key=$old"
        return 1
    fi
    [[ "$old" == "$new" ]] || log "CHANGED runtime sysctl: $key: $old -> $new"
    return 0
}
source "$SCRIPT_DIR/../service_helpers/kernel_network.sh"
disable_forwarding || exit 1
failures=0
for setting in \
    net.inet.tcp.syncookies=1 \
    net.inet.ip.accept_sourceroute=0 \
    net.inet.ip.sourceroute=0 \
    net.inet.ip.redirect=0 \
    net.inet.icmp.drop_redirect=1 \
    net.inet.icmp.bmcastecho=0 \
    net.inet6.ip6.redirect=0 \
    net.inet6.icmp6.rediraccept=0 \
    security.bsd.hardlink_check_uid=1 \
    security.bsd.hardlink_check_gid=1 \
    security.bsd.unprivileged_read_msgbuf=0 \
    security.bsd.unprivileged_proc_debug=0 \
    kern.sugid_coredump=0 \
    kern.elf32.aslr.enable=1 \
    kern.elf32.aslr.pie_enable=1 \
    kern.elf64.aslr.enable=1 \
    kern.elf64.aslr.pie_enable=1; do
    apply_sysctl_setting "${setting%%=*}" "${setting#*=}" || failures=1
done
log 'IPv4/IPv6 forwarding is disabled; IPv6 host connectivity remains available'
log 'Linux protected_symlinks, SysRq and rp_filter have no direct portable FreeBSD sysctl equivalents; native firewall policy requires separate review'

write_tmp_fstab() {
    local temporary
    temporary=$(mktemp /etc/.fstab.XXXXXX) || return 1
    if ! awk '
        $1 !~ /^#/ && $2 == "/tmp" && ($3 == "ufs" || $3 == "tmpfs") {
            n=split($4, options, ","); result=""
            for (i=1; i<=n; i++) {
                if (options[i] ~ /^(exec|suid|noexec|nosuid)$/) continue
                result=result (result == "" ? "" : ",") options[i]
            }
            $4=result (result == "" ? "" : ",") "noexec,nosuid"
        }
        { print }
    ' /etc/fstab > "$temporary"; then rm -f "$temporary"; return 1; fi
    if chown root:wheel "$temporary" && chmod 644 "$temporary" && mv -f "$temporary" /etc/fstab; then return 0; fi
    rm -f "$temporary"
    return 1
}
harden_tmp() {
    local entry source_device mountpoint filesystem options rest
    [[ -d /tmp && ! -L /tmp ]] || { log 'SKIPPED /tmp: not a plain directory'; return 0; }
    audit_chmod 1777 /tmp || return 1
    entry=$(mount -p | awk '$2 == "/tmp" { print; exit }') || return 1
    [[ -n "$entry" ]] || { log '/tmp is not a separate filesystem; mount options unchanged'; return 0; }
    read -r source_device mountpoint filesystem options rest <<< "$entry"
    printf '%s\n' "$entry" > "$backup/tmp-mount.txt" || return 1
    case "$filesystem" in
        ufs|tmpfs)
            mount -u -o noexec,nosuid /tmp || { log 'FAILED updating /tmp mount options'; return 1; }
            if [[ -f /etc/fstab && ! -L /etc/fstab ]] && awk '$1 !~ /^#/ && $2 == "/tmp" { found=1 } END { exit !found }' /etc/fstab; then
                cp -p /etc/fstab "$backup/fstab" || return 1
                audit_file_change /etc/fstab write_tmp_fstab || return 1
            else
                log '/tmp has no regular fstab entry; runtime mount options will need configuring in its mount service'
            fi
            log 'Set /tmp noexec,nosuid using FreeBSD mount options' ;;
        zfs)
            require_commands zfs || return 1
            [[ "$(zfs get -H -o value mountpoint "$source_device")" == /tmp ]] || {
                log 'FAILED: /tmp does not match the ZFS dataset mountpoint'; return 1;
            }
            zfs get -H -o name,property,value,source exec,setuid,devices "$source_device" > "$backup/tmp-zfs-properties.txt" || return 1
            zfs set exec=off setuid=off devices=off "$source_device" || return 1
            log "Persisted exec=off,setuid=off,devices=off on dedicated /tmp ZFS dataset $source_device" ;;
        *) log "SKIPPED /tmp mount options for unsupported filesystem: $filesystem" ;;
    esac
    return 0
}
harden_tmp || failures=1
log 'FreeBSD POSIX shared memory does not use a Linux /dev/shm mount'
((failures == 0)) || { log 'Hardening completed with failures; review the audit log'; exit 1; }
log 'FreeBSD kernel and administrator-policy hardening complete'
