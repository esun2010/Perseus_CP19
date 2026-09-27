#!/usr/bin/env bash
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../service_helpers/second_pass_media.sh"
main() {
    account_platform_init || return 1
    init_logging
    media_review
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
