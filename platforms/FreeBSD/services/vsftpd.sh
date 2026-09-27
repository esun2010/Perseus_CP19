#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../service_helpers/service_common.sh"
service_init
# The default FreeBSD port package with FTPS support is named vsftpd-ssl.
install_packages vsftpd-ssl openssl
require_commands openssl
tls_required=${VSFTPD_TLS_REQUIRED:-YES}
[[ "$tls_required" == YES || "$tls_required" == NO ]] || { log 'VSFTPD_TLS_REQUIRED must be YES or NO'; exit 1; }
config=$(sysrc -n vsftpd_config 2>/dev/null || true)
config=${config:-/usr/local/etc/vsftpd.conf}
[[ "$config" == /* && ! -L "$config" ]] || { log 'FAILED vsftpd_config must be an absolute regular file path'; exit 1; }
if [[ ! -e "$config" && "$config" == /usr/local/etc/vsftpd.conf ]]; then
    [[ -f "$config.sample" ]] || { log "FAILED missing package configuration sample: $config.sample"; exit 1; }
    audit_file_change "$config" cp -p "$config.sample" "$config"
fi
[[ -f /etc/pam.d/ftp ]] || { log 'FAILED missing FreeBSD FTP PAM policy /etc/pam.d/ftp'; exit 1; }
# Do not collide with an FTP server already managed by inetd.
if [[ -f /etc/inetd.conf ]] && grep -Eq '^[[:space:]]*ftp[[:space:]]' /etc/inetd.conf; then
    log 'FAILED: FTP is enabled in /etc/inetd.conf; select one FTP server before using standalone vsftpd'
    exit 1
fi
backup_config "$config"
backup=$CONFIG_BACKUP
capture_service_state vsftpd
[[ -d /usr/local/share/vsftpd/empty && ! -L /usr/local/share/vsftpd/empty ]] || {
    log 'FAILED missing regular vsftpd package chroot directory /usr/local/share/vsftpd/empty'; exit 1;
}
secure_path /usr/local/share/vsftpd/empty 755
settings=(anonymous_enable=NO local_enable=YES xferlog_enable=YES
    background=YES pam_service_name=ftp secure_chroot_dir=/usr/local/share/vsftpd/empty
    pasv_enable=YES pasv_min_port=40000 pasv_max_port=40100)
# The FreeBSD rc.d script requires standalone listen=YES. Keep IPv6 disabled
# here so the service check and the discovered PF listener agree; add a separate
# IPv6 service configuration only when the scenario explicitly requires it.
settings+=(listen=YES listen_ipv6=NO)
if [[ "$tls_required" == YES ]]; then
    cert=/usr/local/etc/ssl/certs/cyberpatriot-vsftpd.pem
    key=/usr/local/etc/ssl/private/cyberpatriot-vsftpd.key
    [[ -d /usr/local/etc/ssl/certs ]] || install -d -m 755 /usr/local/etc/ssl/certs
    [[ -d /usr/local/etc/ssl/private ]] || install -d -m 700 /usr/local/etc/ssl/private
    [[ ! -L "$key" && ! -L "$cert" ]] || { log 'FAILED symbolic-link FTPS certificate/key'; exit 1; }
    if [[ ! -s "$cert" || ! -s "$key" ]]; then
        [[ ! -e "$key" ]] || backup_config "$key"
        [[ ! -e "$cert" ]] || backup_config "$cert"
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
if ! audit_file_change "$config" set_config_values "$config" "${settings[@]}" ||
   ! secure_service_permissions vsftpd ||
   ! secure_path "$config" 600; then
    restore_config "$config" "$backup"
    log 'FAILED configuring vsftpd; previous configuration restored'
    exit 1
fi
# vsftpd has no syntax-check-only flag; check startup and restore on failure.
if ! enable_service vsftpd; then
    restore_config "$config" "$backup"
    restore_service_state vsftpd "$SERVICE_WAS_ENABLED" "$SERVICE_WAS_RUNNING" || log 'FAILED restoring vsftpd service state; inspect service vsftpd status'
    log 'FAILED starting vsftpd; previous configuration restored'
    exit 1
fi
log 'vsftpd ready: local accounts, anonymous access disabled, passive ports 40000:40100; trust the generated certificate in FTPS clients'
