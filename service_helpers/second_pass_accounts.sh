#!/usr/bin/env bash
# Shared local-account audit and explicitly invoked second-pass cleanup.
SECOND_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SECOND_ROOT/logging.sh"

account_platform_init() {
    case "$(uname -s)" in
        Linux) ACCOUNT_PLATFORM=linux ;;
        FreeBSD) ACCOUNT_PLATFORM=freebsd ;;
        *) echo 'Unsupported account platform.' >&2; return 1 ;;
    esac
    [[ $(id -u) == 0 ]] || { echo 'Run as root.' >&2; return 1; }
    if [[ "$ACCOUNT_PLATFORM" == freebsd ]]; then
        source "$SECOND_ROOT/platforms/FreeBSD/service_helpers/platform.sh"
        require_freebsd_root || return 1
    fi
}

prepare_review_logs() {
    [[ ! -L "$SECOND_ROOT/log" ]] || return 1
    (umask 077; mkdir -p "$SECOND_ROOT/log") || return 1
    local file
    for file in "$@"; do
        [[ ! -L "$file" && ( ! -e "$file" || -f "$file" ) ]] || return 1
    done
}

read_authorized_list() {
    local file="$1" line skip_password=0
    local -n dest="$2"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$file" == */auth_admins.txt ]] && ((skip_password)); then skip_password=0; continue; fi
        line=${line%%#*}; line=${line//$'\r'/}
        line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
        [[ -n "$line" ]] || continue
        [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_.-]*\$?$ ]] || { log "FAILED invalid username in $file"; return 1; }
        dest["$line"]=1
        [[ "$file" == */auth_admins.txt ]] && skip_password=1
    done < "$file"
}

local_account_records() {
    if [[ "$ACCOUNT_PLATFORM" == freebsd ]]; then pw usershow -7 -a
    else cat /etc/passwd; fi
}

load_authorized_accounts() {
    AUTH_USERS=(); AUTH_ADMINS=()
    read_authorized_list "$SECOND_ROOT/input/auth_users.txt" AUTH_USERS || return 1
    read_authorized_list "$SECOND_ROOT/input/auth_admins.txt" AUTH_ADMINS || return 1
    local name real_admin=0 uid
    for name in "${!AUTH_ADMINS[@]}"; do
        [[ "$name" == root ]] || real_admin=1
        AUTH_USERS["$name"]=1
    done
    ((real_admin)) || { log 'FAILED: list at least one authorized non-root administrator before generating or applying cleanup'; return 1; }
    AUTH_USERS[root]=1; AUTH_ADMINS[root]=1
    ACCOUNT_RECORDS=$(local_account_records) || return 1
    for name in "${!AUTH_USERS[@]}"; do
        awk -F: -v name="$name" '$1==name {found=1} END {exit !found}' <<< "$ACCOUNT_RECORDS" || {
            log "FAILED authorized account does not exist locally: $name"; return 1;
        }
        uid=$(awk -F: -v name="$name" '$1==name {print $3; exit}' <<< "$ACCOUNT_RECORDS")
        [[ "$name" == root || "$uid" != 0 ]] || { log "FAILED unexpected authorized UID-zero alias: $name"; return 1; }
    done
}

privileged_group() {
    case "$1" in root|sudo|wheel|admin|docker|lxd|incus-admin|disk) return 0;; *) return 1;; esac
}

has_admin_access() {
    local user="$1" uid="$2" groups group grants
    [[ "$uid" != 0 ]] || return 0
    groups=$(id -nG "$user") || return 2
    for group in $groups; do privileged_group "$group" && return 0; done
    if command -v sudo >/dev/null; then
        if grants=$(LC_ALL=C sudo -n -l -U "$user" 2>&1); then
            # Include command-specific direct sudo grants, not just sudo/wheel.
            if awk '/^[[:space:]]*\(/ && $0 !~ /\)[[:space:]]*!ALL[[:space:]]*$/ {found=1} END {exit !found}' <<< "$grants"; then return 0; fi
        elif [[ "$grants" != *'not allowed to run sudo'* && "$grants" != *'is not in the sudoers file'* ]]; then
            log "FAILED inspecting sudo privileges for $user" >&2; return 2
        fi
    fi
    local config token
    for config in /etc/doas.conf /usr/local/etc/doas.conf; do
        [[ -f "$config" ]] || continue
        for token in "$user" $groups; do
            if awk -v user="$user" -v token="$token" '
                $1=="permit" {for(i=2;i<=NF;i++) if($i==user || $i==":" token) found=1}
                END {exit !found}' "$config"; then return 0; fi
        done
    done
    return 1
}

account_review() {
    local users="$SECOND_ROOT/log/unauth_users(2).txt" admins="$SECOND_ROOT/log/unauth_admins(2).txt"
    local name uid gid shell status tmp_users tmp_admins
    prepare_review_logs "$users" "$admins" || return 1
    load_authorized_accounts || return 1
    tmp_users=$(mktemp "$users.XXXXXX") || return 1
    tmp_admins=$(mktemp "$admins.XXXXXX") || return 1
    printf '# Second-pass user deletion candidates: username<TAB>UID. Remove or comment out lines to retain accounts.\n' > "$tmp_users"
    printf '# Second-pass administrator revocation candidates: username<TAB>UID. Remove or comment out lines to retain administrator access.\n' > "$tmp_admins"
    while IFS=: read -r name _ uid gid _ _ shell; do
        [[ -n "$name" && "$name" != root ]] || continue
        [[ "$uid" =~ ^[0-9]+$ ]] || return 1
        if [[ -z "${AUTH_USERS[$name]:-}" ]] && { ((uid == 0)) || { ((uid != 65534)) && [[ "$shell" != */nologin && "$shell" != */false && "$shell" != */sync && "$shell" != */halt && "$shell" != */shutdown ]]; }; }; then
            printf '%s\t%s\n' "$name" "$uid" >> "$tmp_users"
        elif [[ -z "${AUTH_ADMINS[$name]:-}" ]]; then
            status=0; has_admin_access "$name" "$uid" || status=$?
            ((status < 2)) || { rm -f "$tmp_users" "$tmp_admins"; return 1; }
            ((status)) || printf '%s\t%s\n' "$name" "$uid" >> "$tmp_admins"
        fi
    done <<< "$ACCOUNT_RECORDS"
    chmod 644 "$tmp_users" "$tmp_admins" || return 1
    mv "$tmp_users" "$users" && mv "$tmp_admins" "$admins" || return 1
    log "AUDIT ONLY: review $users and $admins, then run run_all_2.sh; no accounts changed"
}

load_review_candidates() {
    local file="$1" kind="$2" line name uid extra record actual
    [[ -f "$file" && ! -L "$file" ]] || { log "FAILED: run the first-pass $kind audit first"; return 1; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" && "$line" != \#* ]] || continue
        read -r name uid extra <<< "$line"
        [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_.-]*\$?$ && "$uid" =~ ^[0-9]+$ && -z "$extra" ]] || {
            log "FAILED invalid review entry in $file"; return 1;
        }
        [[ "$name" != root && "$uid" != 0 ]] || { log 'FAILED: root/UID-zero entries need manual recovery; automatic cleanup stopped'; return 1; }
        if [[ "$kind" == users && -n "${AUTH_USERS[$name]:-}" ]] || [[ "$kind" == admins && -n "${AUTH_ADMINS[$name]:-}" ]]; then
            log "PRESERVED now-authorized account: $name"; continue
        fi
        record=$(awk -F: -v name="$name" '$1==name {print; exit}' <<< "$ACCOUNT_RECORDS")
        [[ -n "$record" ]] || { log "ALREADY ABSENT: $name"; continue; }
        IFS=: read -r _ _ actual _ <<< "$record"
        [[ "$actual" == "$uid" ]] || { log "FAILED account identity changed: $name; rerun the audit"; return 1; }
        [[ "$name" != "${SUDO_USER:-root}" && "$name" != "${DOAS_USER:-root}" ]] || {
            log "FAILED: refusing to alter the account running this cleanup: $name"; return 1;
        }
        if [[ "$kind" == users ]]; then DELETE_USERS["$name"]=$uid
        else REVOKE_ADMINS["$name"]=$uid; fi
    done < "$file"
}

remove_admin_groups() {
    local user="$1" group groups primary keep='' own_group
    primary=$(id -gn "$user") || return 1
    groups=$(id -nG "$user") || return 1
    backup_account_databases || return 1
    if privileged_group "$primary"; then
        own_group="$user"
        if ! getent group "$own_group" >/dev/null; then
            if [[ "$ACCOUNT_PLATFORM" == linux ]]; then groupadd "$own_group" || return 1
            else pw groupadd "$own_group" || return 1; fi
        fi
        privileged_group "$own_group" && { log "FAILED no safe primary group for $user"; return 1; }
        if [[ "$ACCOUNT_PLATFORM" == linux ]]; then usermod -g "$own_group" "$user" || return 1
        else pw usermod "$user" -g "$own_group" || return 1; fi
    fi
    for group in $groups; do privileged_group "$group" || keep+="${keep:+,}$group"; done
    if [[ "$ACCOUNT_PLATFORM" == linux ]]; then usermod -G "$keep" "$user" || return 1
    else pw usermod "$user" -G "$keep" || return 1; fi
    groups=$(id -nG "$user") || return 1
    for group in $groups; do privileged_group "$group" && { log "FAILED privileged group remains for $user"; return 1; }; done
    log "REMOVED privileged group memberships: $user"
}

revoke_local_sudo() {
    local config=/etc/sudoers candidate user previous
    [[ "$ACCOUNT_PLATFORM" != freebsd ]] || config=/usr/local/etc/sudoers
    [[ -e "$config" ]] || return 0
    [[ -f "$config" && ! -L "$config" ]] || return 1
    command -v visudo >/dev/null || return 1
    visudo -c || return 1
    candidate=$(mktemp) || return 1
    cp -p "$config" "$candidate" || return 1
    # Last matching command rule wins, including after existing include directives.
    printf '\n# Second-pass administrator revocations\n' >> "$candidate"
    for user in "${!REVOKE_ADMINS[@]}"; do printf '%s ALL=(ALL:ALL) !ALL\n' "$user" >> "$candidate"; done
    visudo -cf "$candidate" || { rm -f "$candidate"; return 1; }
    backup_system_paths "$config" || return 1
    previous="$SYSTEM_BACKUP_DIR/files$config"
    cat "$candidate" > "$config" || return 1
    rm -f "$candidate"
    if ! visudo -c; then cp -p "$previous" "$config"; return 1; fi
    log 'REVOKED local sudo grants for reviewed unauthorized administrators; other grants retained'
}

revoke_local_doas() {
    local config candidate user previous
    for config in /etc/doas.conf /usr/local/etc/doas.conf; do
        [[ -e "$config" ]] || continue
        [[ -f "$config" && ! -L "$config" ]] || return 1
        command -v doas >/dev/null || return 1
        candidate=$(mktemp) || return 1
        cp -p "$config" "$candidate" || return 1
        printf '\n# Second-pass administrator revocations\n' >> "$candidate"
        for user in "${!REVOKE_ADMINS[@]}"; do printf 'deny %s\n' "$user" >> "$candidate"; done
        doas -C "$candidate" || { rm -f "$candidate"; return 1; }
        backup_system_paths "$config" || return 1
        previous="$SYSTEM_BACKUP_DIR/files$config"
        if ! cat "$candidate" > "$config" || ! doas -C "$config"; then cp -p "$previous" "$config"; rm -f "$candidate"; return 1; fi
        rm -f "$candidate"
        log "REVOKED reviewed users' local doas access: $config"
    done
}

account_cleanup() {
    local user uid status=0
    declare -gA DELETE_USERS=() REVOKE_ADMINS=()
    load_authorized_accounts || return 1
    load_review_candidates "$SECOND_ROOT/log/unauth_users(2).txt" users || return 1
    load_review_candidates "$SECOND_ROOT/log/unauth_admins(2).txt" admins || return 1
    # These reviewed lists are the only source of mutation targets. Never
    # regenerate them here or derive a global administrator allowlist from input/.
    if ((${#DELETE_USERS[@]} == 0 && ${#REVOKE_ADMINS[@]} == 0)); then
        log 'NO CHANGES: no user deletions or administrator revocations remain in the reviewed logs'
        return 0
    fi
    # Apply and validate privilege policy before deleting any account.
    if ((${#REVOKE_ADMINS[@]})); then
        revoke_local_sudo || return 1
        revoke_local_doas || return 1
        for user in "${!REVOKE_ADMINS[@]}"; do
            [[ -z "${DELETE_USERS[$user]:-}" ]] || continue
            remove_admin_groups "$user" || return 1
            log "DEMOTED unauthorized administrator: $user; existing sessions must log out"
        done
    fi
    for user in "${!DELETE_USERS[@]}"; do
        backup_account_databases || return 1
        # No -r/-f: keep home files and refuse unsafe forced deletion of active users.
        if [[ "$ACCOUNT_PLATFORM" == linux ]]; then userdel "$user" || { log "FAILED deleting $user (log out active sessions and retry)"; status=1; continue; }
        else pw userdel "$user" || { log "FAILED deleting $user"; status=1; continue; }; fi
        if local_account_records | awk -F: -v name="$user" '$1==name {found=1} END {exit !found}'; then
            log "FAILED account still exists: $user"; status=1
        else log "DELETED unauthorized account: $user (home directory retained)"; fi
    done
    return "$status"
}

declare -A AUTH_USERS=() AUTH_ADMINS=()
