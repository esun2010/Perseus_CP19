#!/usr/bin/env bash
# Native FreeBSD equivalents for the Linux non-service task names.
COMPONENT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$COMPONENT_ROOT/service_helpers/platform.sh"
source "$COMPONENT_ROOT/../../logging.sh"
source "$COMPONENT_ROOT/service_helpers/permissions.sh"
source "$COMPONENT_ROOT/service_helpers/path_hardening.sh"
component_config() {
    local file="$1" mode="${2:-644}"
    [[ -f "$file" ]] && plain_path "$file" || { log "FAILED: regular unlinked configuration required: $file"; return 1; }
    secure_path "$file" "$mode" root wheel
}
component_main() {
    local key="$1" file directory listing found=0 owner
    shift
    (($# == 0)) || { echo 'This script accepts no arguments.' >&2; return 1; }
    case "$key" in
        nss)
            require_commands getent timeout || return 1
            component_config /etc/nsswitch.conf || return 1
            timeout 15 getent passwd root >/dev/null || return 1
            timeout 15 getent group wheel >/dev/null || return 1
            timeout 15 getent hosts localhost >/dev/null || return 1
            log 'VERIFIED NSS permissions and root/wheel/localhost lookups; existing lookup order retained' ;;
        openssl)
            require_commands openssl || return 1
            openssl version || return 1
            for file in /etc/ssl/openssl.cnf /usr/local/openssl/openssl.cnf /usr/local/etc/ssl/openssl.cnf; do
                [[ -e "$file" || -L "$file" ]] || continue
                component_config "$file" || return 1
            done
            for directory in /etc/ssl/private /usr/local/etc/ssl/private /usr/local/openssl/private; do
                [[ -d "$directory" ]] || continue
                plain_path "$directory" || return 1
                secure_path "$directory" 750 root || return 1
                listing=$(mktemp) || return 1
                if ! find -P "$directory" -xdev -type f -print0 > "$listing"; then rm -f "$listing"; return 1; fi
                while IFS= read -r -d '' file; do
                    owner=$(stat -f '%Su' "$file") || { rm -f "$listing"; return 1; }
                    secure_path "$file" 640 "$owner" || { rm -f "$listing"; return 1; }
                done < "$listing"
                rm -f "$listing"
            done
            secure_native_trust || return 1
            openssl ciphers -s >/dev/null || return 1
            log 'VERIFIED selected OpenSSL cipher configuration; application TLS policy, certificates and keys retained' ;;
        grub)
            secure_native_boot || return 1
            for file in /boot/grub/grub.cfg /boot/grub2/grub.cfg; do
                [[ -f "$file" ]] || continue
                require_commands grub-script-check || return 1
                grub-script-check "$file" || return 1
                found=1
            done
            if ((found == 0)); then log 'GRUB not installed: protected native FreeBSD loader configuration instead'; fi
            log 'Boot settings/passwords require scenario review; no bootloader regenerated or installed' ;;
        selinux)
            log 'NOT APPLICABLE: FreeBSD does not implement Linux SELinux. Native MAC policies require scenario-specific configuration; no security framework replaced' ;;
        netfilter)
            backup_system_paths /etc/pf.conf /etc/ipfw.rules /etc/rc.firewall /etc/rc.conf /etc/rc.conf.local || return 1
            # Query only already loaded firewall modules; never enable or flush.
            if [[ -c /dev/pf ]]; then
                (umask 077; pfctl -si > "$SYSTEM_BACKUP_DIR/pf-status.txt" && pfctl -a '*' -sr > "$SYSTEM_BACKUP_DIR/pf-filter.rules" && pfctl -a '*' -sn > "$SYSTEM_BACKUP_DIR/pf-nat.rules") || return 1
                found=1
            fi
            if sysctl -n net.inet.ip.fw.enable >/dev/null 2>&1; then
                (umask 077; ipfw -a list > "$SYSTEM_BACKUP_DIR/ipfw.rules") || return 1
                found=1
            fi
            if ((found)); then log "SAVED native firewall inspection: $SYSTEM_BACKUP_DIR; rules unchanged"
            else log 'SKIPPED runtime firewall snapshot: neither PF nor IPFW is loaded'; fi
            log 'Netfilter/iptables are Linux-only; services/pf.sh is the native firewall policy writer' ;;
        dhclient)
            for file in /etc/dhclient.conf /usr/local/etc/dhclient.conf; do
                [[ -e "$file" || -L "$file" ]] || continue
                component_config "$file" || return 1
                found=1
            done
            for file in /etc/dhclient-enter-hooks /etc/dhclient-exit-hooks /usr/local/etc/dhclient-enter-hooks /usr/local/etc/dhclient-exit-hooks; do
                [[ -e "$file" || -L "$file" ]] || continue
                component_config "$file" 755 || return 1
                found=1
            done
            if ((found)); then log 'VERIFIED DHCP configuration/hook permissions; leases and network settings retained'
            else log 'SKIPPED: no custom dhclient configuration/hooks; native defaults retained'; fi ;;
        *) log "FAILED: unknown component $key"; return 1 ;;
    esac
}

component_init() { require_freebsd_root && init_logging; }
