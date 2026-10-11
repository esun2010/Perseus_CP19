#!/usr/bin/env bash
# Use the native implementation when invoked directly on FreeBSD.
if [[ "${BASH_SOURCE[0]}" == "$0" && $(uname -s) == FreeBSD ]]; then
    exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/platforms/FreeBSD/password_management/reset_admin_pwd.sh" "$@"
fi
#check

set -euo pipefail

# ============================================================
# Admin Password Reset Script
#
# Reads admin usernames from ../input/auth_admins.txt and sets each
# listed account to the same password.
#
# Run with sudo/root.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../logging.sh"
AUTH_ADMINS_FILE="$SCRIPT_DIR/../input/auth_admins.txt"

# Change this password to whatever you want:
NEW_PASSWORD="ChangeMe123!"

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (use sudo)." >&2
  exit 1
fi

if [[ ! -f "$AUTH_ADMINS_FILE" ]]; then
  echo "Missing $AUTH_ADMINS_FILE" >&2
  exit 1
fi

if [[ -z "$NEW_PASSWORD" ]]; then
  echo "NEW_PASSWORD is empty. Set it before running the script." >&2
  exit 1
fi

init_logging

echo "Resetting passwords for admins listed in $AUTH_ADMINS_FILE ..."
echo

skip_password=0
while IFS= read -r line || [[ -n "$line" ]]; do
  if ((skip_password)); then skip_password=0; continue; fi
  username="$(echo "$line" | xargs)"

  [[ -z "$username" ]] && continue
  [[ "$username" =~ ^# ]] && continue
  skip_password=1

  if id "$username" >/dev/null 2>&1; then
    backup_account_databases
    echo "$username:$NEW_PASSWORD" | chpasswd
    echo "Password updated for: $username"
  else
    echo "Skipping '$username' (user does not exist)"
  fi
done < "$AUTH_ADMINS_FILE"

echo
echo "Done."
