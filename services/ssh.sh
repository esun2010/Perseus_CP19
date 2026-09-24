# Step 2: Disable SSH root login
echo "Disabling root login via SSH..."
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_BACKUP="/etc/ssh/sshd_config.bak"

if [[ -f "$SSHD_CONFIG" ]]; then
    cp "$SSHD_CONFIG" "$SSHD_BACKUP"
    echo "Backup of SSH config created at $SSHD_BACKUP."

    if grep -Eq '^[[:space:]]*PermitRootLogin\b' "$SSHD_CONFIG"; then
        sed -i 's/^[[:space:]]*PermitRootLogin.*/PermitRootLogin no/' "$SSHD_CONFIG"
    else
        echo 'PermitRootLogin no' >> "$SSHD_CONFIG"
    fi

    echo "Restarting SSH service to apply the changes..."
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || \
        echo "[-] Could not restart ssh/sshd automatically."

    echo "Verifying changes..."
    grep -i 'PermitRootLogin' "$SSHD_CONFIG" || true
else
    echo "[-] $SSHD_CONFIG not found; skipping SSH root login hardening."
fi