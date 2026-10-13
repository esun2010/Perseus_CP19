#!/usr/bin/env bash
# Requires logging helpers and apply_sysctl_setting from main/kernel.sh.
disable_forwarding() {
    local key file directory
    require_commands sysrc || return 1
    # Unlike optional hardening knobs, forwarding must not silently skip.
    for key in net.inet.ip.forwarding net.inet6.ip6.forwarding; do
        sysctl -n "$key" >/dev/null 2>&1 || {
            log "FAILED: required forwarding control unavailable: $key"; return 1;
        }
    done
    local -a configs=(/etc/rc.conf)
    for file in /etc/rc.conf.local /etc/rc.conf.d/routing /usr/local/etc/rc.conf.d/routing; do
        [[ -e "$file" || -L "$file" ]] || continue
        [[ ! -L "$file" ]] || { log "FAILED: linked routing configuration $file"; return 1; }
        if [[ -d "$file" ]]; then
            for directory in "$file"/*; do
                [[ -e "$directory" || -L "$directory" ]] || continue
                [[ -f "$directory" && ! -L "$directory" ]] || {
                    log "FAILED: unexpected routing configuration $directory"; return 1;
                }
                configs+=("$directory")
            done
        else configs+=("$file"); fi
    done
    for file in "${configs[@]}"; do
        [[ ! -L "$file" && ( ! -e "$file" || -f "$file" ) ]] || return 1
        # Keep native rc startup from enabling forwarding after sysctl.conf.
        audit_file_change "$file" sysrc -f "$file" gateway_enable=NO ipv6_gateway_enable=NO || return 1
        [[ $(sysrc -f "$file" -n gateway_enable) == NO && $(sysrc -f "$file" -n ipv6_gateway_enable) == NO ]] || return 1
    done
    [[ $(sysrc -n gateway_enable) == NO && $(sysrc -n ipv6_gateway_enable) == NO ]] || {
        log 'FAILED: another rc configuration overrides gateway settings'; return 1;
    }
    apply_sysctl_setting net.inet.ip.forwarding 0 || return 1
    apply_sysctl_setting net.inet6.ip6.forwarding 0 || return 1
    log 'VERIFIED IPv4/IPv6 forwarding disabled at runtime and persisted in sysctl.conf and gateway rc settings'
}
