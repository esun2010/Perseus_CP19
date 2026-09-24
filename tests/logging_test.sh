#!/bin/bash
# Safe fixture tests; never run the hardening scripts against the host.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/repo/rm_stuff"
cp "$ROOT/logging.sh" "$fixture/repo/"
cp "$ROOT/rm_stuff/rm_mp3+.sh" "$fixture/repo/rm_stuff/"
source "$fixture/repo/logging.sh"
touch "$LOG_FILE"

config="$fixture/settings.conf"
printf 'setting=1\n' > "$config"
edit_config() { printf 'setting=2\nnew_setting=yes\n' > "$config"; }
audit_file_change "$config" edit_config
grep -F -- '-setting=1' "$LOG_FILE"
grep -F -- '+setting=2' "$LOG_FILE"
grep -F -- '+new_setting=yes' "$LOG_FILE"
lines=$(wc -l < "$LOG_FILE")
audit_file_change "$config" true
[[ $(wc -l < "$LOG_FILE") == "$lines" ]]
if audit_file_change "$config" false; then
    echo 'Expected edit failure' >&2
    exit 1
fi
grep -F 'FAILED' "$LOG_FILE"
config="$fixture/new.conf"
audit_file_change "$config" edit_config
grep -F 'CREATED' "$LOG_FILE"

# Test permission logging without depending on Windows permission emulation.
mock_mode=777
stat() { printf '%s\n' "$mock_mode"; }
chmod() { mock_mode="$1"; }
audit_chmod 700 "$fixture"
grep -F '777 -> 700' "$LOG_FILE"
lines=$(wc -l < "$LOG_FILE")
audit_chmod 700 "$fixture"
[[ $(wc -l < "$LOG_FILE") == "$lines" ]]
unset -f stat chmod

# The real deletion script uses a mocked search limited to our temporary files.
export AUDIT_MEDIA="$fixture/odd name"$'\n''song.mp3'
export AUDIT_MISSING="$fixture/missing.mp4"
touch "$AUDIT_MEDIA"
id() { echo 0; }
find() { printf '%s\0' "$AUDIT_MEDIA"; }
export -f id find
(cd "$fixture" && bash "$fixture/repo/rm_stuff/rm_mp3+.sh")
[[ ! -e "$AUDIT_MEDIA" ]]
grep -F 'DELETED media file:' "$LOG_FILE"
find() { printf '%s\0' "$AUDIT_MISSING"; }
export -f find
if (cd "$fixture" && bash "$fixture/repo/rm_stuff/rm_mp3+.sh"); then
    echo 'Expected deletion failure' >&2
    exit 1
fi
grep -F 'FAILED deleting media file:' "$LOG_FILE"
grep -F 'END exit=1' "$LOG_FILE"
echo 'Logging fixture tests passed.'
