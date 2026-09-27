#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/service_helpers/additional_services.sh"
TEMP=$(mktemp -d)
trap 'rm -rf "$TEMP"' EXIT
log() { printf '%s\n' "$*" >> "$TEMP/log"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
# Parser aliases and mutually exclusive time providers.
printf 'openssh\nnfs-server\ncupsd\ncrony\nsnmp\nsssd\n' > "$TEMP/list"
load_critical_services "$TEMP/list"
[[ "${CRITICAL_SERVICES[*]}" == 'ssh nfs cups chrony snmpd sssd' ]] || fail aliases
printf 'chrony\nntpsec\n' > "$TEMP/list"
if load_critical_services "$TEMP/list" 2>/dev/null; then fail 'competing time services'; fi
# Preserve the actual profile dispatch but redirect primary configs into fixture.
eval "$(declare -f additional_profile | sed '1s/additional_profile/original_profile/')"
additional_profile() { original_profile "$1"; PROFILE_FILES=("$TEMP/config"); }
service_init() { :; }
load_critical_services() { CRITICAL_SERVICES=("${required[@]}"); }
state=active
installed=yes
systemctl() {
    printf '%s\n' "$*" >> "$TEMP/calls"
    case "$1" in
        show) [[ $installed != yes ]] || echo loaded ;;
        is-active) [[ $state == active ]] ;;
        *) fail "unexpected service mutation: $*" ;;
    esac
}
additional_validate() { printf 'validate\n' >> "$TEMP/calls"; return "$validation_status"; }
additional_review() { :; }
export CP_BACKUP_ROOT="$TEMP/backups"
required=(); validation_status=0
printf 'fixture\n' > "$TEMP/config"
chmod 666 "$TEMP/config"
additional_main sssd
[[ ! -e "$TEMP/calls" ]] || fail 'unlisted identity service touched'
additional_main rsyslog
[[ $(stat -c %a "$TEMP/config") == 644 ]] || fail 'writable config retained'
grep -q '^validate$' "$TEMP/calls" || fail 'missing validator'
# Validation failure must propagate, and never reload or restart the daemon.
validation_status=1
if additional_main rsyslog; then fail 'invalid configuration accepted'; fi
validation_status=0
state=inactive; required=(rsyslog)
if additional_main rsyslog; then fail 'required inactive service accepted'; fi
required=(); additional_main rsyslog
installed=no; required=(sssd)
if additional_main sssd; then fail 'required missing service accepted'; fi
required=(); additional_main chrony
ln -s "$TEMP/config" "$TEMP/linked"
if additional_protect "$TEMP/linked"; then fail 'linked config accepted'; fi
printf 'PASS additional service aliases, gating, permissions, validation failure, and no lifecycle mutation\n'
