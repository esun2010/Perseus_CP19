#!/usr/bin/env bash
# Native FreeBSD path protection. Source permissions.sh and logging.sh first.
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
    # /home -> /usr/home is a standard FreeBSD alias; no other links allowed.
    if [[ "$home_dir" == /home/* && -L /home && $(realpath /home) == /usr/home ]]; then
        home_dir="/usr/home/${home_dir#/home/}"
    fi
    [[ -d "$home_dir" && "$home_dir" != / ]] || return 0
    plain_path "$home_dir" || { log "REVIEW: linked home $home_dir"; return 1; }
    for file in .bash_profile .bashrc .bash_login .profile .zshrc .bash_history .cshrc .login .history; do
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
    log "VERIFIED shell/SSH permissions: $home_dir; contents retained"
}
secure_local_login_files() {
    local name password uid gid gecos home_dir shell
    while IFS=: read -r name password uid gid gecos home_dir shell; do
        [[ "$uid" =~ ^[0-9]+$ ]] || continue
        if [[ "$uid" != 0 ]]; then
            case "$shell" in */bash|*/zsh|*/sh|*/dash|*/ksh|*/fish|*/csh|*/tcsh) ;; *) continue ;; esac
        fi
        secure_login_home "$home_dir" "$name" || return 1
    done < /etc/passwd
}
secure_native_trust() {
    local path
    for path in /usr/share/certs /usr/local/share/certs /usr/local/etc/ssl/certs /etc/ssl/certs /etc/ssl/untrusted; do
        [[ -e "$path" || -L "$path" ]] || continue
        plain_path "$path" || { log "REVIEW: linked certificate root $path"; return 1; }
        secure_tree "$path" 644 755 || return 1
    done
    log 'VERIFIED certificate directory permissions; trust membership and internal symlink targets retained'
}
secure_native_startup() {
    local path
    for path in /etc/rc.d /usr/local/etc/rc.d; do
        [[ -d "$path" ]] || continue
        plain_path "$path" || return 1
        secure_tree "$path" 755 755 || return 1
    done
    for path in /etc/rc.conf.d /usr/local/etc/rc.conf.d; do
        [[ -d "$path" ]] || continue
        plain_path "$path" || return 1
        secure_tree "$path" 644 755 || return 1
    done
}
secure_native_boot() {
    local path
    for path in /boot/loader.conf /boot/loader.conf.local /boot/loader.rc /boot/grub/grub.cfg /boot/grub2/grub.cfg; do
        [[ -e "$path" || -L "$path" ]] || continue
        plain_path "$path" || { log "REVIEW: linked boot file $path"; return 1; }
        secure_path "$path" 600 root wheel || return 1
    done
    if [[ -d /boot/loader.conf.d ]]; then
        plain_path /boot/loader.conf.d || return 1
        secure_tree /boot/loader.conf.d 600 700 || return 1
    fi
    log 'Protected native loader configuration; EFI boot binaries and bootcode retained; EFI FAT permissions require mount-option review'
}
