#!/usr/bin/env bash
# Native implementations live under platforms; policy and callers stay shared.
if [[ $(uname -s) == FreeBSD ]]; then
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/platforms/FreeBSD/service_helpers/system_components.sh"
    return $?
fi
# Non-daemon Linux components. Source this file; invoke through misc/system_hardening.sh.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_DIR/logging.sh"
source "$REPO_DIR/service_helpers/distribution.sh"
source "$REPO_DIR/service_helpers/permissions.sh"
source "$REPO_DIR/service_helpers/path_hardening.sh"
init_logging

component_config() {
    local file="$1" mode="${2:-644}"
    [[ -f "$file" && ! -L "$file" ]] || {
        log "FAILED: regular configuration required: $file"; return 1;
    }
    secure_path "$file" "$mode" root || return 1
}

component_main() {
    local key="$1" file found=0 state listing
    shift
    (($# == 0)) || { echo 'This script accepts no arguments.' >&2; return 1; }
    case "$key" in
        nss)
            component_config /etc/nsswitch.conf || return 1
            # Preserve sss, LDAP, winbind, systemd and resolver ordering.
            timeout 15 getent passwd root >/dev/null || return 1
            timeout 15 getent group root >/dev/null || return 1
            timeout 15 getent hosts localhost >/dev/null || return 1
            log 'VERIFIED NSS configuration permissions and root/localhost lookups; name-service order retained' ;;
        openssl)
            command -v openssl >/dev/null || { log 'SKIPPED: OpenSSL not installed'; return 0; }
            openssl version || return 1
            component_config /etc/ssl/openssl.cnf || return 1
            # Keep ssl-cert access and service-owned keys; remove writable access
            # by other users without recursively changing private-key ownership.
            if [[ -d /etc/ssl/private && ! -L /etc/ssl/private ]]; then
                secure_path /etc/ssl/private 750 root || return 1
                listing=$(mktemp) || return 1
                if ! find -P /etc/ssl/private -xdev -type f -print0 > "$listing"; then
                    rm -f "$listing"; return 1
                fi
                while IFS= read -r -d '' file; do
                    if ! secure_path "$file" 640 "$(stat -c '%U' "$file")"; then
                        rm -f "$listing"; return 1
                    fi
                done < "$listing"
                rm -f "$listing"
            fi
            openssl ciphers -s >/dev/null || return 1
            log 'VERIFIED OpenSSL loads its cipher configuration; existing providers, certificates and application TLS policies retained' ;;
        grub)
            secure_boot_paths || return 1
            [[ -f /etc/default/grub ]] || { log 'SKIPPED: GRUB configuration not installed'; return 0; }
            component_config /etc/default/grub 600 || return 1
            for file in /boot/grub/grub.cfg /boot/grub2/grub.cfg; do
                [[ -f "$file" ]] || continue
                command -v grub-script-check >/dev/null || { log 'FAILED: grub-script-check required'; return 1; }
                grub-script-check "$file" || return 1
                component_config "$file" 600 || return 1
                found=1
            done
            ((found)) || { log 'FAILED: no generated GRUB configuration found (check mounted /boot)'; return 1; }
            log 'VERIFIED GRUB syntax and permissions; boot arguments and passwords require scenario review; bootloader not regenerated' ;;
        selinux)
            command -v getenforce >/dev/null || { log 'SKIPPED: SELinux tools absent; existing AppArmor/LSM choice retained'; return 0; }
            state=$(getenforce) || return 1
            [[ ! -f /etc/selinux/config ]] || component_config /etc/selinux/config || return 1
            log "SELinux runtime state: $state"
            if [[ "$state" != Enforcing ]]; then
                log 'PENDING: SELinux is not enforcing; review policy, labels and boot configuration before enabling'; return 1
            fi
            command -v sestatus >/dev/null || return 1
            sestatus || return 1
            log 'VERIFIED enforcing runtime; review persistent mode and policy exceptions separately' ;;
        netfilter)
            # UFW is this repository's writer. Never flush or add a competing
            # iptables ruleset that could lock out SSH or break NAT/VPN traffic.
            backup_system_paths /etc/ufw /etc/iptables /etc/nftables.conf || return 1
            for file in iptables-save ip6tables-save; do
                command -v "$file" >/dev/null || continue
                (umask 077; "$file" > "$SYSTEM_BACKUP_DIR/$file.rules") || return 1
                found=1
            done
            if command -v nft >/dev/null; then
                (umask 077; nft list ruleset > "$SYSTEM_BACKUP_DIR/nftables.rules") || return 1
                found=1
            fi
            ((found)) || { log 'SKIPPED: no Netfilter inspection utilities installed'; return 0; }
            log "SAVED IPv4/IPv6 Netfilter rules where available: $SYSTEM_BACKUP_DIR" ;;
        dhclient)
            [[ -f /etc/dhcp/dhclient.conf ]] || { log 'SKIPPED: ISC DHCP client config absent (NetworkManager/networkd may manage DHCP)'; return 0; }
            component_config /etc/dhcp/dhclient.conf || return 1
            for file in /etc/dhcp/dhclient-enter-hooks.d /etc/dhcp/dhclient-exit-hooks.d; do
                # Preserve execute bits: these hooks may be sourced or executed.
                [[ ! -d "$file" ]] || secure_tree "$file" 755 755 || return 1
            done
            log 'VERIFIED DHCP client configuration/hook permissions; leases, DNS and interface settings retained; no renewal performed' ;;
        *) log "FAILED: unknown component $key"; return 1 ;;
    esac
}

component_init() {
    [[ $(id -u) == 0 ]] || { echo 'Run with sudo.' >&2; return 1; }
    command -v apt-get >/dev/null || { echo 'Requires Debian/Ubuntu with apt-get.' >&2; return 1; }
    load_distribution || return 1
    init_logging
}
