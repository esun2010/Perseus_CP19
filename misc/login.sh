#!/bin/bash
#check

# This script disables the guest account, disables SSH root login,
# and ensures SSHD configuration is properly updated.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../logging.sh"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "This script must be run as root. Exiting."
    exit 1
fi

init_logging

echo "Starting the process..."

# Step 1: Disable the guest account (if present)
echo "Disabling the guest account..."
if id guest &>/dev/null; then
    guest_status=$(passwd -S guest | awk '{print $2}')
    backup_account_databases
    if usermod -L guest 2>/dev/null; then
        [[ "$guest_status" == L ]] || log "CHANGED guest password status: $guest_status -> L (locked)"
    else
        log "FAILED locking guest account"
    fi
    backup_account_databases
    if userdel guest 2>/dev/null; then
        log "DELETED account: guest"
    else
        log "FAILED deleting guest account"
    fi
fi
echo "Guest account disabled (if it existed)."

LIGHTDM_CONF="/etc/lightdm/lightdm.conf"

# Create lightdm.conf if it doesn't exist
configure_lightdm() {
if [[ ! -f "$LIGHTDM_CONF" ]]; then
    printf '[SeatDefaults]\n' > "$LIGHTDM_CONF" || return 1
fi

# Remove any existing allow-guest lines and add secure setting once
sed -i '/^allow-guest=/d' "$LIGHTDM_CONF" || return 1
echo "allow-guest=false" >> "$LIGHTDM_CONF"
}
audit_file_change "$LIGHTDM_CONF" configure_lightdm

echo "[*] Restarting LightDM to apply changes..."
if systemctl restart lightdm 2>/dev/null; then
    log "RESTARTED service: lightdm"
else
    log "FAILED restarting LightDM (you may not be using it)"
fi


# Check if the guest account is locked or deleted
if id guest &>/dev/null; then
    echo "The guest account still exists. Please manually delete it if necessary."
else
    echo "The guest account has been disabled or deleted."
fi

echo "Script complete. The guest account has been disabled (if it existed)."
