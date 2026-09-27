#!/usr/bin/env bash
# Installed-service checks and configuration permission hardening. No package
# installation, start/stop/restart, domain migration or network-role changes.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/service_common.sh"

additional_profile() {
    PROFILE_KEY="$1"; PROFILE_EXTENDED=0; PROFILE_SECRET=0
    PROFILE_FILES=(); PROFILE_UNITS=(); PROFILE_COMMAND=()
    case "$1" in
        sssd) PROFILE_FILES=(/etc/sssd/sssd.conf); PROFILE_UNITS=(sssd); PROFILE_COMMAND=(sssctl config-check); PROFILE_SECRET=1 ;;
        fail2ban) PROFILE_EXTENDED=1; PROFILE_FILES=(/etc/fail2ban/jail.conf); PROFILE_UNITS=(fail2ban); PROFILE_COMMAND=(fail2ban-client -t) ;;
        chrony) PROFILE_EXTENDED=1; PROFILE_FILES=(/etc/chrony/chrony.conf); PROFILE_UNITS=(chrony chronyd); PROFILE_COMMAND=(chronyd -p -f /etc/chrony/chrony.conf) ;;
        ntpd) PROFILE_EXTENDED=1; PROFILE_FILES=(/etc/ntpsec/ntp.conf /etc/ntp.conf); PROFILE_UNITS=(ntpsec ntp ntpd) ;;
        dhcpd) PROFILE_FILES=(/etc/dhcp/dhcpd.conf); PROFILE_UNITS=(isc-dhcp-server); PROFILE_COMMAND=(dhcpd -t -cf /etc/dhcp/dhcpd.conf); PROFILE_SECRET=1 ;;
        nfs) PROFILE_FILES=(/etc/exports); PROFILE_UNITS=(nfs-server nfs-kernel-server) ;;
        avahi) PROFILE_FILES=(/etc/avahi/avahi-daemon.conf); PROFILE_UNITS=(avahi-daemon) ;;
        cups) PROFILE_FILES=(/etc/cups/cupsd.conf); PROFILE_UNITS=(cups); PROFILE_COMMAND=(cupsd -t) ;;
        acpid) PROFILE_EXTENDED=1; PROFILE_FILES=(/etc/acpi/events); PROFILE_UNITS=(acpid) ;;
        smartd) PROFILE_EXTENDED=1; PROFILE_FILES=(/etc/smartd.conf); PROFILE_UNITS=(smartmontools smartd) ;;
        rsyslog) PROFILE_EXTENDED=1; PROFILE_FILES=(/etc/rsyslog.conf); PROFILE_UNITS=(rsyslog); PROFILE_COMMAND=(rsyslogd -N1) ;;
        snmpd) PROFILE_FILES=(/etc/snmp/snmpd.conf); PROFILE_UNITS=(snmpd); PROFILE_SECRET=1 ;;
        *) log "FAILED: unknown additional service $1"; return 1 ;;
    esac
}

additional_protect() {
    local file="$1" secret="${2:-0}" mode owner
    [[ -e "$file" || -L "$file" ]] || return 0
    [[ ! -L "$file" && ( -f "$file" || -d "$file" ) ]] || {
        log "FAILED: review linked/nonregular configuration $file"; return 1;
    }
    # Preserve daemon-specific owners/groups (SSSD may run unprivileged).
    owner=$(stat -c '%U' "$file") || return 1
    mode=644
    [[ ! -d "$file" ]] || mode=755
    ((secret == 0)) || mode=600
    secure_path "$file" "$mode" "$owner" || return 1
}

additional_validate() {
    local output status=0
    ((${#PROFILE_COMMAND[@]})) || return 0
    command -v "${PROFILE_COMMAND[0]}" >/dev/null || {
        log "FAILED: ${PROFILE_COMMAND[0]} required for $PROFILE_KEY validation"; return 1;
    }
    # Validators can echo passwords, community strings or complete configs.
    # Keep diagnostics in a private snapshot, never in the public audit log.
    backup_system_paths "${PROFILE_FILES[@]}" || return 1
    output="$SYSTEM_BACKUP_DIR/validation.txt"
    (umask 077; "${PROFILE_COMMAND[@]}" > "$output" 2>&1) || status=$?
    if ((status)); then
        log "FAILED: $PROFILE_KEY validation; private diagnostics: $output"; return 1
    fi
    log "VERIFIED $PROFILE_KEY native configuration validation"
}

additional_review() {
    local file key="$1" failed=0
    case "$key" in
        sssd)
            for file in /etc/sssd/sssd.conf /etc/sssd/conf.d/*.conf; do
                [[ -f "$file" ]] || continue
                if grep -Eiq '^[[:space:]]*(ldap_tls_reqcert[[:space:]]*=[[:space:]]*(never|allow)|access_provider[[:space:]]*=[[:space:]]*permit)([[:space:]]|$)' "$file"; then
                    log "REVIEW: weak TLS verification or unrestricted domain access in $file"; failed=1
                fi
            done ;;
        nfs)
            for file in /etc/exports /etc/exports.d/*.exports; do
                [[ -f "$file" ]] || continue
                if grep -Eq '^[[:space:]]*[^#].*\b(no_root_squash|insecure)\b' "$file"; then
                    log "REVIEW: permissive NFS export options in $file"; failed=1
                fi
            done
            log 'REVIEW NFS export client ranges, writable shares, NFS version and RPC firewall ports; exportfs -ra was not run' ;;
        snmpd)
            if grep -Eq '^[[:space:]]*(rocommunity6?|rwcommunity6?|com2sec6?)[[:space:]]' /etc/snmp/snmpd.conf; then
                log 'REVIEW: SNMP v1/v2 community access configured; prefer scenario-approved SNMPv3 authPriv'; failed=1
            fi
            log 'REVIEW SNMP include files, users, views and source restrictions; credentials retained' ;;
        avahi)
            if grep -Eiq '^[[:space:]]*enable-reflector[[:space:]]*=[[:space:]]*yes' /etc/avahi/avahi-daemon.conf; then
                log 'REVIEW: Avahi reflects mDNS between interfaces'; failed=1
            fi ;;
        ntpd) log 'REVIEW NTP restrict rules, configured peers and drift/key files; no portable offline ntpd validator used' ;;
        chrony) log 'REVIEW Chrony allow/cmdallow ranges and configured time sources; server role retained' ;;
        fail2ban) fail2ban-client ping >/dev/null || return 1
            log 'REVIEW enabled Fail2ban jails, trusted addresses and backend; no arbitrary SSH port or jail assumed' ;;
        smartd) log 'REVIEW smartd device coverage and notification destination; no disk tests initiated' ;;
        acpid) log 'REVIEW ACPI event actions and referenced scripts; hardware power behavior retained' ;;
        cups) log 'REVIEW CUPS listeners, sharing, authentication and administrative access rules' ;;
        rsyslog) log 'REVIEW log destinations, retention, remote listeners and TLS forwarding' ;;
        dhcpd) log 'REVIEW DHCP interfaces, pools, DNS updates and failover; existing address allocations retained' ;;
    esac
    ((failed == 0)) || { log "PENDING: $key findings need scenario-specific remediation"; return 1; }
}

additional_main() {
    local key="$1" unit='' candidate config='' file
    shift
    (($# == 0)) || { echo 'This script accepts no arguments.' >&2; return 1; }
    additional_profile "$key" || return 1
    service_init
    load_critical_services "$REPO_DIR/input/critical_services.txt" || return 1
    if ((PROFILE_EXTENDED == 0)) && ! critical_service "$key"; then
        log "SKIPPED $key: not listed as critical; existing service state retained"; return 0
    fi
    for candidate in "${PROFILE_UNITS[@]}"; do
        if [[ $(systemctl show --property=LoadState --value "$candidate") == loaded ]]; then
            unit="$candidate"; break
        fi
    done
    if [[ -z "$unit" ]]; then
        if critical_service "$key"; then log "FAILED: required $key service is not installed"; return 1; fi
        log "SKIPPED: $key service not installed"; return 0
    fi
    # Inactive optional services are not installed or activated by an 'all' run.
    if ! systemctl is-active --quiet "$unit"; then
        if critical_service "$key"; then log "PENDING: required $unit is inactive; start it after reviewing its configuration"; return 1; fi
        log "SKIPPED: optional $unit is inactive"; return 0
    fi
    for file in "${PROFILE_FILES[@]}"; do
        [[ -e "$file" ]] || continue
        config="$file"
        additional_protect "$file" "$PROFILE_SECRET" || return 1
    done
    [[ -n "$config" ]] || { log "FAILED: expected $key configuration not found"; return 1; }
    # Includes commonly carry credentials or override the primary file.
    case "$key" in
        sssd) for file in /etc/sssd/conf.d/*.conf; do additional_protect "$file" 1 || return 1; done ;;
        fail2ban) for file in /etc/fail2ban/jail.local /etc/fail2ban/jail.d/* /etc/fail2ban/action.d/* /etc/fail2ban/filter.d/*; do additional_protect "$file" || return 1; done ;;
        chrony) for file in /etc/chrony/conf.d/*.conf /etc/chrony/sources.d/*.sources; do additional_protect "$file" || return 1; done
            additional_protect /etc/chrony/chrony.keys 1 || return 1 ;;
        ntpd) for file in /etc/ntp.keys /etc/ntpsec/ntp.keys; do additional_protect "$file" 1 || return 1; done ;;
        nfs) for file in /etc/exports.d/*.exports; do additional_protect "$file" || return 1; done ;;
        cups) additional_protect /etc/cups/cups-files.conf || return 1 ;;
        acpid) for file in /etc/acpi/events/*; do additional_protect "$file" || return 1; done ;;
        rsyslog) for file in /etc/rsyslog.d/*.conf; do additional_protect "$file" || return 1; done ;;
    esac
    additional_validate || return 1
    additional_review "$key" || return 1
    systemctl is-active --quiet "$unit" || return 1
    log "VERIFIED $unit remains active; configuration permissions checked; content and boot enablement retained"
}
