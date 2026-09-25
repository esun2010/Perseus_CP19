#!/usr/bin/env bash
# Shared permission ceilings: preserve stricter read/execute permissions and groups.
# Source logging.sh first. Do not traverse symlinks inside a protected tree.
secure_path() {
    local path="$1" ceiling="$2" owner="${3:-root}" old new current required=0600
    [[ ! -L "$path" ]] || { log "SKIPPED symbolic link: $path"; return 0; }
    [[ -e "$path" ]] || { log "SKIPPED absent path: $path"; return 0; }
    [[ -f "$path" || -d "$path" ]] || { log "FAILED unexpected file type: $path"; return 1; }
    current=$(stat -c '%U' -- "$path") || return 1
    if [[ "$current" != "$owner" ]]; then
        chown -- "$owner" "$path" || return 1
        log "CHANGED owner: $path: $current -> $owner (group retained)"
    fi
    old=$(stat -c '%a' -- "$path") || return 1
    # Also remove setuid/setgid/sticky from these config/module paths.
    [[ ! -d "$path" ]] || required=0700
    printf -v new '%o' "$(( (8#$old & 8#$ceiling) | required ))"
    [[ "$new" == "$old" ]] || audit_chmod "$new" "$path"
}

secure_tree() {
    local root="$1" files="${2:-644}" dirs="${3:-755}" list path status=0
    [[ ! -L "$root" ]] || { log "SKIPPED symbolic-link tree: $root"; return 0; }
    [[ -d "$root" ]] || { log "SKIPPED absent directory: $root"; return 0; }
    list=$(mktemp) || return 1
    if ! find -P "$root" -xdev \( -type d -o -type f \) -print0 > "$list"; then
        rm -f -- "$list"; return 1
    fi
    while IFS= read -r -d '' path; do
        if [[ -d "$path" ]]; then secure_path "$path" "$dirs" || status=1
        else secure_path "$path" "$files" || status=1; fi
    done < "$list"
    rm -f -- "$list"
    return "$status"
}

secure_auth_permissions() {
    local path resolved owner
    secure_tree /etc/pam.d || return 1
    secure_tree /etc/security || return 1
    secure_path /etc/security/opasswd 600 || return 1
    secure_path /etc/security/opasswd.old 600 || return 1
    # Handle both lib64 layouts and Debian/Ubuntu multiarch module directories.
    for path in /usr/lib64/security /lib64/security /usr/lib/security /lib/security \
                /usr/lib/*-linux-gnu/security /lib/*-linux-gnu/security; do
        [[ -d "$path" ]] || continue
        resolved=$(readlink -f -- "$path") || return 1
        secure_tree "$resolved" 755 || return 1
    done
    for path in /var/log/secure /var/log/secure.* /var/log/auth.log /var/log/auth.log.*; do
        [[ -f "$path" && ! -L "$path" ]] || continue
        owner=$(stat -c '%U' -- "$path") || return 1
        # Preserve syslog ownership where required for unprivileged log writers.
        [[ "$owner" == syslog ]] || owner=root
        secure_path "$path" 640 "$owner" || return 1
    done
}

secure_service_permissions() {
    local service="$1" path
    case "$service" in
        ssh)
            secure_tree /etc/ssh || return 1
            secure_path /etc/ssh/sshd_config 600 || return 1
            secure_tree /etc/ssh/sshd_config.d 600 || return 1
            for path in /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.bak* /etc/ssh/sshd_config.*; do
                [[ -f "$path" ]] || continue
                secure_path "$path" 600 || return 1
            done ;;
        apache2)
            secure_tree /etc/apache2 || return 1
            secure_tree /etc/ssl/private 640 750 || return 1 ;;
        vsftpd)
            for path in /etc/vsftpd.conf /etc/vsftpd.conf.*; do
                secure_path "$path" 600 || return 1
            done
            secure_tree /etc/vsftpd 600 || return 1
            secure_path /etc/ftpusers 600 || return 1
            secure_path /etc/ssl/private/cyberpatriot-vsftpd.key 600 || return 1
            secure_path /etc/ssl/certs/cyberpatriot-vsftpd.pem 644 || return 1 ;;
        ufw)
            secure_tree /etc/ufw 750 750 || return 1
            secure_path /etc/default/ufw 640 || return 1 ;;
        *) log "FAILED unknown service permission profile: $service"; return 1 ;;
    esac
}
