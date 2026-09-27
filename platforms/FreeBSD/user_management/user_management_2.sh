#!/usr/bin/env bash
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../service_helpers/second_pass_accounts.sh"
main() {
    account_platform_init || return 1
    LOG_FILE="$SECOND_ROOT/log/user_management(2).txt"
    prepare_review_logs "$LOG_FILE" || return 1
    (umask 077; touch "$LOG_FILE") && chmod 600 "$LOG_FILE" || return 1
    init_logging
    account_cleanup
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
