#!/usr/bin/env bash
# Source logging.sh and permissions.sh before using these routines.
# Refuse linked ancestors for user-controlled paths as well as linked leaves.
plain_path() {
    local path="$1"
    [[ "$path" == /* && "$path/" != *'/../'* && "$path/" != *'/./'* ]] || return 1
    while [[ -n "$path" ]]; do
        [[ ! -L "$path" ]] || return 1
        path=${path%/*}
    done
}

secure_login_home() {
    local home_dir="$1" owner="$2" file
    [[ -d "$home_dir" && "$home_dir" != / ]] || return 0
    if ! plain_path "$home_dir"; then
        log "REVIEW: linked home path left unchanged: $home_dir"; return 1
    fi
    for file in .bash_profile .bashrc .bash_login .profile .zshrc .bash_history; do
        [[ ! -L "$home_dir/$file" ]] || { log "REVIEW: linked login file $home_dir/$file"; return 1; }
        secure_path "$home_dir/$file" 600 "$owner" || return 1
    done
    [[ -e "$home_dir/.ssh" || -L "$home_dir/.ssh" ]] || return 0
    plain_path "$home_dir/.ssh" || { log "REVIEW: linked SSH directory $home_dir/.ssh"; return 1; }
    secure_path "$home_dir/.ssh" 700 "$owner" || return 1
    for file in authorized_keys config id_rsa id_ed25519; do
        [[ ! -L "$home_dir/.ssh/$file" ]] || { log "REVIEW: linked SSH file $home_dir/.ssh/$file"; return 1; }
        secure_path "$home_dir/.ssh/$file" 600 "$owner" || return 1
    done
    log "VERIFIED login/SSH file permissions: $home_dir (contents retained, secrets not logged)"
}

secure_local_login_files() {
    local name password uid gid gecos home_dir shell
    # Local account database includes root and nonstandard home locations. Avoid
    # remote NSS enumeration and service accounts with nologin/false shells.
    while IFS=: read -r name password uid gid gecos home_dir shell; do
        [[ "$uid" =~ ^[0-9]+$ ]] || continue
        if [[ "$uid" != 0 ]]; then
            case "$shell" in */bash|*/zsh|*/sh|*/dash|*/ksh|*/fish|*/csh|*/tcsh) ;; *) continue ;; esac
        fi
        secure_login_home "$home_dir" "$name" || return 1
    done < /etc/passwd
}

secure_vendor_units_and_trust() {
    local path resolved
    # Resolve distribution-owned /lib -> /usr/lib aliases once; secure_tree
    # never follows links within the tree (e.g. systemd aliases to /dev/null).
    for path in /lib/systemd/system /usr/lib/systemd/system \
        /usr/share/ca-certificates /etc/pki/tls/certs \
        /etc/pki/ca-trust/source/anchors /usr/local/share/ca-certificates; do
        [[ -d "$path" ]] || continue
        resolved=$(readlink -f -- "$path") || return 1
        secure_tree "$resolved" 644 755 || return 1
        log "VERIFIED permissions: $path; certificate trust and unit contents retained"
    done
}

secure_boot_paths() {
    local path filesystem
    for path in /boot/grub/grub.cfg /boot/grub2/grub.cfg \
        /boot/efi/EFI/ubuntu/grub.cfg /boot/efi/EFI/centos/grub.cfg \
        /boot/efi/EFI/redhat/grub.cfg /boot/loader/entries; do
        [[ -e "$path" || -L "$path" ]] || continue
        plain_path "$path" || { log "REVIEW: linked boot path $path"; return 1; }
        filesystem=$(findmnt -n -o FSTYPE --target "$path") || return 1
        case "$filesystem" in
            vfat|msdos|exfat)
                log "REVIEW: $path resides on $filesystem; protect it with mount uid/gid/umask options (per-file chmod unavailable)"
                continue ;;
        esac
        if [[ -d "$path" ]]; then secure_tree "$path" 600 700 || return 1
        else secure_path "$path" 600 root root || return 1; fi
    done
}
