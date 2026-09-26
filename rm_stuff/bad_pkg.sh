#!/usr/bin/env bash
# CyberPatriot Safe Removal Script
# Lets you manually edit a list of dangerous packages before removing them

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../logging.sh"
source "$SCRIPT_DIR/../service_helpers/critical_services.sh"
source "$SCRIPT_DIR/../service_helpers/managed_platform.sh"
load_critical_services "$SCRIPT_DIR/../input/critical_services.txt"

protected_package() {
    local family
    if family=$(package_family "$1") && critical_service "$family"; then return 0; fi
    case "$1" in
        openssh*) critical_service ssh ;;
        apache2*|libapache2*) critical_service apache2 ;;
        vsftpd*) critical_service vsftpd ;;
        ufw) critical_service ufw ;;
        *) return 1 ;;
    esac
}

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root."
    exit 1
fi

# List of packages that are usually unsafe
BAD_PACKAGES=(
    nmap
    netcat
    netcat-openbsd
    netcat-traditional
    john
    hydra
    medusa
    ophcrack
    hashcat
    wireshark
    aircrack-ng
    kismet
    telnet
    rsh-server
    xinetd
    tor
    deluge
    transmission
    sqlmap
    nikto
)

echo "==============================================="
echo " CyberPatriot Package Removal Tool"
echo "==============================================="
echo
echo "The following packages are on the removal list:"
echo

for pkg in "${BAD_PACKAGES[@]}"; do
    echo " - $pkg"
done

echo
echo "👉 Edit the list as needed BEFORE removal."
echo "👉 If any package is needed per the README, remove it from the list."
echo

read -r -p "Do you want to edit the list now? (y/n) " edit_choice

TEMP_LIST=""
cleanup() {
    [[ -n "$TEMP_LIST" && -f "$TEMP_LIST" ]] && rm -f "$TEMP_LIST"
}
trap cleanup EXIT

if [[ "$edit_choice" =~ ^[Yy]$ ]]; then
    TEMP_LIST=$(mktemp)
    printf "%s\n" "${BAD_PACKAGES[@]}" > "$TEMP_LIST"

    echo
    echo "Opening list in nano..."
    echo "Remove any packages you DO NOT want uninstalled."
    echo "Save with CTRL+O, exit with CTRL+X."
    sleep 1
    nano "$TEMP_LIST"

    mapfile -t BAD_PACKAGES < "$TEMP_LIST"
    echo
    echo "Edited list loaded."
fi

echo "==============================================="
echo " Final package removal list:"
echo "==============================================="
for pkg in "${BAD_PACKAGES[@]}"; do
    echo " - $pkg"
done

echo
read -r -p "Proceed with removal? (y/n) " choice
echo

if [[ "$choice" =~ ^[Yy]$ ]]; then
    echo "[+] Removing packages..."
    for pkg in "${BAD_PACKAGES[@]}"; do
        [[ -z "$pkg" ]] && continue
        [[ "$pkg" =~ ^[a-z0-9][a-z0-9+.-]*$ ]] || { echo "Invalid package name: $pkg" >&2; exit 1; }
        if protected_package "$pkg"; then echo "Preserved critical package: $pkg"; continue; fi
        if dpkg -l | grep -q "^ii  $pkg "; then
            echo "Removing: $pkg"
            plan=$(LC_ALL=C apt-get -s purge -- "$pkg")
            while read -r action dependent rest; do
                if [[ "$action" == Remv || "$action" == Purg ]] && protected_package "${dependent%%:*}"; then
                    echo "Removal would affect critical package $dependent" >&2; exit 1
                fi
            done <<< "$plan"
            backup_package_configuration
            apt purge -y "$pkg"
        else
            echo "Not installed: $pkg"
        fi
    done
    echo "[+] Package removal complete."
else
    echo "[-] Aborted. No packages were removed."
fi

exit 0