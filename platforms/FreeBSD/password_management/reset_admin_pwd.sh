#!/usr/bin/env bash
# Prompt separately for each authorized administrator; never store passwords.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../service_helpers/platform.sh"
require_freebsd_root
source "$SCRIPT_DIR/../../../logging.sh"
init_logging
require_commands pw passwd

AUTH_ADMINS_FILE="$SCRIPT_DIR/../../../input/auth_admins.txt"
[[ -r "$AUTH_ADMINS_FILE" ]] || { log "FAILED: cannot read $AUTH_ADMINS_FILE"; exit 1; }
[[ -t 0 && -t 1 ]] || { log 'FAILED: password resets require an interactive terminal'; exit 1; }

# Validate the entire list before changing any password.
admins=()
skip_password=0
while IFS= read -r username || [[ -n "$username" ]]; do
    if ((skip_password)); then skip_password=0; continue; fi
    username=${username%$'\r'}
    username="${username#"${username%%[![:space:]]*}"}"
    username="${username%"${username##*[![:space:]]}"}"
    [[ -z "$username" || "$username" == \#* ]] && continue
    skip_password=1
    [[ "$username" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*[$]?$ ]] || {
        log "FAILED: invalid administrator name: $username"; exit 1;
    }
    pw usershow -n "$username" >/dev/null 2>&1 || {
        log "FAILED: local administrator does not exist: $username"; exit 1;
    }
    if [[ "$(id -u "$username")" == 0 && "$username" != root ]]; then
        log "FAILED: unexpected UID-zero administrator: $username"; exit 1
    fi
    [[ " ${admins[*]} " == *" $username "* ]] || admins+=("$username")
done < "$AUTH_ADMINS_FILE"
((${#admins[@]})) || { log 'FAILED: administrator allowlist is empty'; exit 1; }

for username in "${admins[@]}"; do
    printf '\nChoose a unique password for %s.\n' "$username"
    # passwd handles terminal echo, PAM policy, locking, and password databases.
    # Do not pipe or redirect its input through the allowlist or audit logger.
    backup_account_databases
    if passwd "$username"; then
        log "CHANGED administrator password: $username (password not logged)"
    else
        log "FAILED changing password for $username; earlier resets remain applied"
        exit 1
    fi
done
log 'Administrator password resets complete'
