#!/usr/bin/env bash
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
audit_chmod 644 "$config"
a2enconf zz-cyberpatriot
log 'ENABLED Apache configuration: zz-cyberpatriot'
rollback_apache() {
    if [[ "$existed" == yes ]]; then restore_config "$config" "$backup";
    else audit_file_change "$config" rm -f -- "$config"; fi
    if [[ "$was_enabled" == no ]]; then
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
    systemctl restart apache2 || true
    log 'FAILED starting Apache; previous configuration restored'
    exit 1
fi
log 'Apache configured; existing sites, document roots, listeners and TLS settings retained'
