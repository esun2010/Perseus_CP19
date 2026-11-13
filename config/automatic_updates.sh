#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
source "$ROOT_DIR/config/logging.sh"
source "$ROOT_DIR/service_helpers/distribution.sh"
[[ $EUID -eq 0 ]] || { echo 'Run this script as root.' >&2; exit 1; }
init_logging
load_distribution || exit 1
[[ "$CP_DISTRO" != freebsd ]] || { log 'SKIPPED: APT automatic refresh settings do not apply to FreeBSD'; exit 0; }
directory=/etc/apt/apt.conf.d
file="$directory/20auto-upgrades"
[[ -d "$directory" && ! -L "$directory" && ! -L "$file" ]] || { log "FAILED: unsafe APT configuration path: $file"; exit 1; }
backup_system_paths "$file" || exit 1
temporary=$(mktemp "$directory/.20auto-upgrades.XXXXXX")
trap 'rm -f -- "$temporary"' EXIT
if [[ -f "$file" ]]; then
    [[ ! -L "$file" ]] || { log "FAILED: refusing symlink $file"; exit 1; }
    awk '!/^[[:space:]]*APT::Periodic::Update-Package-Lists[[:space:]]+/' "$file" > "$temporary"
fi
printf 'APT::Periodic::Update-Package-Lists "1";\n' >> "$temporary"
chown root:root "$temporary" && chmod 0644 "$temporary" && mv -f -- "$temporary" "$file" || exit 1
apt-config dump | grep -Eq '^APT::Periodic::Update-Package-Lists "1";$' || { log 'FAILED validating daily APT package-list refresh'; exit 1; }
log 'CONFIGURED daily APT package-list checks; automatic package installation remains unchanged'
