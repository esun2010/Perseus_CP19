#!/usr/bin/env bash
source "$REPO_DIR/service_helpers/managed_platform.sh"
append_managed_firewall_rules() {
    local listeners proto port process key pattern needed=0
    for key in bind9 mysql postfix sendmail samba nginx openvpn; do
        critical_service "$key" && needed=1
    done
    ((needed)) || return 0
    listeners=$(native_managed_listeners) || return 1
    for key in bind9 mysql postfix sendmail samba nginx openvpn; do
        critical_service "$key" || continue
        case "$key" in
            bind9) pattern='named' ;; mysql) pattern='mysqld|mariadbd' ;;
            postfix) pattern='master|smtpd' ;; sendmail) pattern='sendmail' ;;
            samba) pattern='smbd|nmbd|samba' ;; nginx) pattern='nginx' ;; openvpn) pattern='openvpn' ;;
        esac
        while read -r proto port process; do
            if [[ "$process" =~ (^|[^[:alnum:]_])($pattern)($|[^[:alnum:]_]) ]]; then
                valid_port_rule "$port/$proto" || return 1
                rules+=("$port/$proto")
            fi
        done <<< "$listeners"
    done
}
