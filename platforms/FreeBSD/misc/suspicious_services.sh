#!/usr/bin/env bash
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../service_helpers/managed_services.sh"
source "$REPO_DIR/service_helpers/suspicious_services.sh"
service_init
load_critical_services "$REPO_DIR/input/critical_services.txt"
audit_suspicious_services
