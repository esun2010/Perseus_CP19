#!/usr/bin/env bash
# FreeBSD permission ceilings; preserve groups unless explicitly specified.
# Skip symbolic links instead of changing their targets.
secure_path() {
    local path="$1" ceiling="$2" owner="${3:-root}" group="${4:-}"
    local old new current current_group ownership required=0400
    [[ ! -L "$path" ]] || { log "SKIPPED symbolic link: $path"; return 0; }
    [[ -e "$path" ]] || { log "SKIPPED absent path: $path"; return 0; }
    [[ -f "$path" || -d "$path" ]] || { log "FAILED unexpected file type: $path"; return 1; }
    current=$(stat -f '%Su' "$path") || return 1
    ownership="$owner"
    current_group=
    if [[ -n "$group" ]]; then
        current_group=$(stat -f '%Sg' "$path") || return 1
        ownership="$owner:$group"
    fi
    if [[ "$current" != "$owner" || "$current_group" != "$group" ]]; then
        if [[ -f "$path" ]]; then backup_system_paths "$path" || return 1; fi
        chown "$ownership" "$path" || return 1
        log "CHANGED ownership: $path: $current${current_group:+:$current_group} -> $ownership"
    fi
    old=$(stat -f '%Lp' "$path") || return 1
    [[ ! -d "$path" ]] || required=0500
    # Remove special bits; retain at least owner read/search within the ceiling.
    printf -v new '%o' "$(( (8#$old & 8#$ceiling) | (required & 8#$ceiling) ))"
    [[ "$new" == "$old" ]] || audit_chmod "$new" "$path"
}

secure_tree() {
    local root="$1" files="${2:-644}" dirs="${3:-755}" list path status=0
    [[ ! -L "$root" ]] || { log "SKIPPED symbolic-link tree: $root"; return 0; }
    [[ -d "$root" ]] || { log "SKIPPED absent directory: $root"; return 0; }
    list=$(mktemp) || return 1
    if ! find -P "$root" -xdev \( -type d -o -type f \) -print0 > "$list"; then
        rm -f "$list"; return 1
    fi
    while IFS= read -r -d '' path; do
        if [[ -d "$path" ]]; then secure_path "$path" "$dirs" || status=1
        else secure_path "$path" "$files" || status=1; fi
    done < "$list"
    rm -f "$list"
    return "$status"
}

secure_account_permissions() {
    local path
    for path in /etc/passwd /etc/group /etc/master.passwd; do
        [[ -f "$path" && ! -L "$path" ]] || {
            log "FAILED expected regular account database: $path"; return 1;
        }
    done
    # FreeBSD stores password hashes in master.passwd/spwd.db, not shadow.
    for path in /etc/master.passwd /etc/spwd.db; do
        secure_path "$path" 600 root wheel || return 1
    done
    for path in /etc/passwd /etc/group /etc/pwd.db; do
        secure_path "$path" 644 root wheel || return 1
        # These public databases must remain readable for user/group lookup.
        [[ ! -f "$path" ]] || audit_chmod 644 "$path" || return 1
    done
}

secure_auth_permissions() {
    local path
    secure_account_permissions || return 1
    secure_tree /etc/pam.d || return 1
    secure_tree /usr/local/etc/pam.d || return 1
    for path in /etc/login.conf /etc/login.conf.db; do secure_path "$path" 644 || return 1; done
    for path in /usr/lib/pam_*.so* /usr/local/lib/pam_*.so*; do
        [[ -e "$path" ]] || continue
        secure_path "$path" 755 || return 1
    done
    secure_path /usr/local/etc/sudoers 440 || return 1
    secure_tree /usr/local/etc/sudoers.d 440 750 || return 1
    for path in /var/log/auth.log /var/log/auth.log.*; do
        [[ -f "$path" && ! -L "$path" ]] || continue
        secure_path "$path" 640 || return 1
    done
}

secure_service_permissions() {
    local service="$1" path
    case "$service" in
        ssh|sshd)
            secure_tree /etc/ssh || return 1
            secure_path /etc/ssh/sshd_config 600 || return 1
            secure_tree /etc/ssh/sshd_config.d 600 || return 1
            for path in /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.* /etc/ssh/sshd_config.*; do
                [[ -f "$path" && "$path" != *.pub ]] || continue
                secure_path "$path" 600 || return 1
            done ;;
        apache2|apache24)
            secure_tree /usr/local/etc/apache24 || return 1
            secure_tree /usr/local/etc/ssl/private 640 750 || return 1 ;;
        vsftpd)
            for path in /usr/local/etc/vsftpd.conf /usr/local/etc/vsftpd.conf.*; do
                secure_path "$path" 600 || return 1
            done
            secure_tree /usr/local/etc/vsftpd 600 || return 1
            secure_path /etc/ftpusers 600 || return 1
            secure_path /usr/local/etc/ssl/private/cyberpatriot-vsftpd.key 600 || return 1
            secure_path /usr/local/etc/ssl/certs/cyberpatriot-vsftpd.pem 644 || return 1 ;;
        pf|ufw)
            secure_path /etc/pf.conf 600 || return 1 ;;
        *) log "FAILED unknown service permission profile: $service"; return 1 ;;
    esac
}
