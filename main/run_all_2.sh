#!/usr/bin/env bash
# Explicit second pass: reviewed account and media cleanup only.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin
export LC_ALL=C
(($# == 0)) || { echo 'Usage: bash main/run_all_2.sh' >&2; exit 1; }
MAIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(cd "$MAIN_DIR/.." && pwd)"
source "$SCRIPT_DIR/service_helpers/distribution.sh"
load_distribution || exit 1
source "$SCRIPT_DIR/service_helpers/second_pass_accounts.sh"
account_platform_init
LOG_FILE="$MAIN_DIR/all_logs(2).txt"
prepare_review_logs "$LOG_FILE"
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"
init_logging
# Require both first-pass inventories before any account or media changes.
for report in unauth_users\(2\).txt unauth_admins\(2\).txt media_files\(2\).txt; do
    [[ -f "$SCRIPT_DIR/log/$report" && ! -L "$SCRIPT_DIR/log/$report" ]] || {
        log "FAILED missing first-pass review log: $report. Run main/run_all.sh and select usr mp3 first."
        exit 1
    }
done
log 'SECOND PASS: applying only entries remaining in log/unauth_users(2).txt, log/unauth_admins(2).txt, and log/media_files(2).txt; inventories will not be regenerated'
for task in user_management/user_management_2.sh rm_stuff/rm_mp3+_2.sh; do
    log "RUN $task"
    if bash "$SCRIPT_DIR/$task" 2>&1 | tee -a "$LOG_FILE"; then log "PASS $task"
    else status=$?; log "FAILED $task (exit $status); remaining second-pass tasks stopped"; exit "$status"; fi
done
log 'SECOND PASS complete'
