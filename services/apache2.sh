#!/usr/bin/env bash
# Use the native implementation when invoked directly on FreeBSD.
if [[ "${BASH_SOURCE[0]}" == "$0" && $(uname -s) == FreeBSD ]]; then
    exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/platforms/FreeBSD/services/apache2.sh" "$@"
fi
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../service_helpers/service_common.sh"
service_init
install_packages apache2
config=/etc/apache2/conf-available/zz-cyberpatriot.conf
existed=no
if [[ -e "$config" ]]; then
    existed=yes
    backup_config "$config"
    backup=$CONFIG_BACKUP
fi
was_enabled=no
[[ ! -e /etc/apache2/conf-enabled/zz-cyberpatriot.conf ]] || was_enabled=yes
configure_apache() {
    printf '%s\n' 'ServerTokens Prod' 'ServerSignature Off' 'TraceEnable Off' > "$config"
}
audit_file_change "$config" configure_apache
secure_service_permissions apache2
backup_system_paths /etc/apache2/conf-enabled
a2enconf zz-cyberpatriot
log 'ENABLED Apache configuration: zz-cyberpatriot'
rollback_apache() {
    if [[ "$existed" == yes ]]; then restore_config "$config" "$backup";
    else audit_file_change "$config" rm -f -- "$config"; fi
    if [[ "$was_enabled" == no ]]; then
        backup_system_paths /etc/apache2/conf-enabled || return 1
        a2disconf zz-cyberpatriot
        log 'DISABLED Apache configuration: zz-cyberpatriot (rollback)'
    fi
}
if ! apache2ctl configtest; then
    rollback_apache
    log 'FAILED Apache validation; previous configuration restored'
    exit 1
fi
if ! enable_service apache2; then
    rollback_apache
    refresh_service apache2 || log "PENDING: restored configuration could not be reloaded"
    log 'FAILED starting Apache; previous configuration restored'
    exit 1
fi
log 'Apache configured; existing sites, document roots, listeners and TLS settings retained'
