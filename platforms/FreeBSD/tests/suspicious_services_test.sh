#!/usr/bin/env bash
set -euo pipefail
CP_DISTRO=freebsd
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/../../service_helpers/critical_services.sh"
source "$ROOT/service_helpers/managed_platform.sh"
source "$ROOT/../../service_helpers/suspicious_services.sh"
TEMP=$(mktemp -d)
trap 'rm -rf "$TEMP"' EXIT
REPO_DIR=$TEMP
log() { :; }
suspicious_packages() { printf 'apache2\nnginx\ntelnetd\ncurl\n'; }
managed_units() { printf 'apache2.service\nnginx.service\nredis-server.service\n'; }
suspicious_unit_state() { printf 'ActiveState=active; UnitFileState=enabled'; }
CRITICAL_SERVICES=(nginx)
audit_suspicious_services
grep -q 'family=apache2 package=apache2' "$SUSPICIOUS_LOG"
grep -q 'family=apache2 service=apache2.service state=ActiveState=active' "$SUSPICIOUS_LOG"
grep -q 'family=telnet' "$SUSPICIOUS_LOG"
grep -q 'family=redis' "$SUSPICIOUS_LOG"
! grep -q 'family=nginx\|package=curl' "$SUSPICIOUS_LOG"
CRITICAL_SERVICES=(nginx apache2)
audit_suspicious_services
[[ $(grep -c 'family=apache2 ' "$SUSPICIOUS_LOG") == 2 ]]
[[ $(grep -c 'SCAN START' "$SUSPICIOUS_LOG") == 2 ]]
suspicious_packages() { return 1; }
if audit_suspicious_services; then echo 'accepted incomplete scan' >&2; exit 1; fi
grep -q 'incomplete=1' "$SUSPICIOUS_LOG"
# Native FreeBSD aliases and systemd instances share critical-service names.
[[ $(suspicious_service_family apache24) == apache2 ]]
[[ $(suspicious_service_family telnetd) == telnet ]]
[[ $(suspicious_service_family postgresql16-server) == postgresql ]]
rm "$SUSPICIOUS_LOG"
printf 'untouched\n' > "$TEMP/target"
ln -s "$TEMP/target" "$SUSPICIOUS_LOG"
if audit_suspicious_services; then echo 'accepted symlink log' >&2; exit 1; fi
[[ $(cat "$TEMP/target") == untouched ]]
echo 'PASS suspicious-service findings, critical exclusion, append history, incomplete scans, aliases and log path safety'
