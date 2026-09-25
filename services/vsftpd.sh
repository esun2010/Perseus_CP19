#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../service_helpers/service_common.sh"
service_init
install_packages vsftpd openssl

# Explicit FTPS protects passwords. Override for scenarios requiring plain FTP.
tls_required=${VSFTPD_TLS_REQUIRED:-YES}
[[ "$tls_required" == YES || "$tls_required" == NO ]] || { log 'VSFTPD_TLS_REQUIRED must be YES or NO'; exit 1; }
config=/etc/vsftpd.conf
backup_config "$config"
backup=$CONFIG_BACKUP
settings=(anonymous_enable=NO local_enable=YES xferlog_enable=YES
    listen=NO listen_ipv6=YES background=NO pam_service_name=vsftpd
    pasv_enable=YES pasv_min_port=40000 pasv_max_port=40100)
# Keep existing local upload policy, directories and access restrictions.
if [[ "$tls_required" == YES ]]; then
    cert=/etc/ssl/certs/cyberpatriot-vsftpd.pem
    key=/etc/ssl/private/cyberpatriot-vsftpd.key
    if [[ ! -s "$cert" || ! -s "$key" ]]; then
        (umask 077; openssl req -x509 -nodes -newkey rsa:3072 -days 365 \
            -subj '/CN=vsftpd' -keyout "$key" -out "$cert")
        log "CREATED self-signed FTPS certificate: $cert and private key: $key"
    fi
    audit_chmod 600 "$key"
    settings+=(ssl_enable=YES force_local_logins_ssl=YES force_local_data_ssl=YES
        ssl_sslv2=NO ssl_sslv3=NO "rsa_cert_file=$cert" "rsa_private_key_file=$key")
else
    settings+=(ssl_enable=NO)
    log 'Scenario override: plaintext FTP enabled (VSFTPD_TLS_REQUIRED=NO)'
fi
audit_file_change "$config" set_config_values "$config" "${settings[@]}"
secure_service_permissions vsftpd
# vsftpd has no syntax-check-only flag; check startup and restore on failure.
if ! enable_service vsftpd; then
    restore_config "$config" "$backup"
    systemctl restart vsftpd || true
    log 'FAILED starting vsftpd; previous configuration restored'
    exit 1
fi
log 'vsftpd ready: local accounts, anonymous access disabled, passive ports 40000:40100'
