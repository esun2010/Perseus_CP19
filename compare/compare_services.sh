#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
OUTPUT_FILE="$ROOT_DIR/log/services_log.txt"
REFERENCE_FILE="$SCRIPT_DIR/services/safe_services.txt"
INVENTORY_FILE="$SCRIPT_DIR/services/unsafe_services.txt"

usage() { echo "Usage: $0 (no arguments; uses safe_services, unsafe_services, services_log.txt)" >&2; }
error() { echo "compare_services: $*" >&2; exit 1; }

(( $# == 0 )) || { usage; exit 2; }

target_path() {
    local supplied=$1 parent base
    [[ ! -L "$supplied" ]] || return 1
    parent=$(cd -P -- "$(dirname -- "$supplied")" 2>/dev/null && pwd) || return 1
    base=$(basename -- "$supplied")
    [[ "$base" != . && "$base" != / ]] || return 1
    printf '%s/%s\n' "$parent" "$base"
}

[[ -f "$REFERENCE_FILE" && -r "$REFERENCE_FILE" && ! -L "$REFERENCE_FILE" ]] || error "trusted reference must be an existing readable regular file: $REFERENCE_FILE"
for candidate in "$REFERENCE_FILE" "$INVENTORY_FILE" "$OUTPUT_FILE"; do
    [[ ! -e "$candidate" || ( -f "$candidate" && ! -L "$candidate" ) ]] || error "path must be a regular file, not a symlink or special file: $candidate"
done
reference_path=$(target_path "$REFERENCE_FILE") || error "cannot resolve reference path"
inventory_path=$(target_path "$INVENTORY_FILE") || error "inventory parent directory must exist and target must not be a symlink"
output_path=$(target_path "$OUTPUT_FILE") || error "cannot resolve output path"
[[ "$reference_path" != "$inventory_path" && "$reference_path" != "$output_path" && "$inventory_path" != "$output_path" ]] || error "reference, inventory, and findings output must be three different files"
if [[ -e "$INVENTORY_FILE" && "$INVENTORY_FILE" -ef "$REFERENCE_FILE" ]] ||
   [[ -e "$OUTPUT_FILE" && "$OUTPUT_FILE" -ef "$REFERENCE_FILE" ]] ||
   [[ -e "$INVENTORY_FILE" && -e "$OUTPUT_FILE" && "$INVENTORY_FILE" -ef "$OUTPUT_FILE" ]]; then
    error "reference, inventory, and findings output must not refer to the same file"
fi

source "$ROOT_DIR/service_helpers/distribution.sh"
load_distribution || error "could not identify a supported distribution"
case "$CP_DISTRO" in
    ubuntu|debian|mint) command -v systemctl >/dev/null 2>&1 || error "systemctl is required on $CP_DISTRO" ;;
    freebsd)
        command -v service >/dev/null 2>&1 || error "FreeBSD service command is required"
        ;;
    *) error "unsupported distribution: $CP_DISTRO" ;;
esac

inventory_dir=$(dirname -- "$INVENTORY_FILE")
output_dir=$(dirname -- "$OUTPUT_FILE")
inventory_tmp=$(mktemp "$inventory_dir/.compare-services-inventory.XXXXXX") || error "cannot create inventory beside $INVENTORY_FILE"
output_tmp=$(mktemp "$output_dir/.compare-services-output.XXXXXX") || { rm -f -- "$inventory_tmp"; error "cannot create findings beside $OUTPUT_FILE"; }
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/compare-services.XXXXXX") || { rm -f -- "$inventory_tmp" "$output_tmp"; error "cannot create temporary comparison files"; }
cleanup() { rm -f -- "$inventory_tmp" "$output_tmp"; rm -rf -- "$work_dir"; }
trap cleanup EXIT

normalize_name() {
    local name=$1
    if [[ "$CP_DISTRO" == freebsd ]]; then
        name=${name##*/}
        name=${name%.sh}
        [[ "$name" =~ ^[[:alnum:]_.+-]+$ ]] || return 1
    else
        [[ "$name" =~ ^[[:alnum:]_.@+-]+(\.service)?$ ]] || return 1
        [[ "$name" == *.service ]] || name+='.service'
    fi
    printf '%s\n' "$name"
}

# Reference format: one service name and expected boot state (enabled or
# disabled) per line. Runtime state is deliberately not part of this check.
declare -A EXPECTED=()
line_number=0
while IFS= read -r line || [[ -n "$line" ]]; do
    ((line_number += 1))
    line=${line%%#*}
    read -r name state extra <<< "$line"
    [[ -z "${name:-}" ]] && continue
    [[ -n "${state:-}" && -z "${extra:-}" ]] || error "malformed trusted reference on line $line_number; use: service-name enabled|disabled"
    state=${state,,}
    [[ "$state" == enabled || "$state" == disabled ]] || error "invalid expected state on line $line_number (use enabled or disabled)"
    normalized=$(normalize_name "$name") || error "invalid service name on line $line_number: $name"
    if [[ -n "${EXPECTED[$normalized]+present}" && "${EXPECTED[$normalized]}" != "$state" ]]; then
        error "conflicting expected states for $normalized in trusted reference"
    fi
    EXPECTED[$normalized]=$state
done < "$REFERENCE_FILE"
for name in "${!EXPECTED[@]}"; do
    printf '%s %s\n' "$name" "${EXPECTED[$name]}"
done | LC_ALL=C sort -k1,1 > "$work_dir/reference.normalized"

raw_inventory="$work_dir/services.raw"
case "$CP_DISTRO" in
    ubuntu|debian|mint)
        systemctl list-unit-files --type=service --no-legend --no-pager > "$raw_inventory" || error "systemctl could not collect service unit-file states"
        while read -r unit unit_state _; do
            [[ "$unit" == *.service && -n "${unit_state:-}" ]] || continue
            normalized=$(normalize_name "$unit") || continue
            unit_state=${unit_state,,}
            # Preserve the native state in the inventory. Only states that
            # explicitly mean boot-enabled or boot-disabled are compared.
            printf '%s %s\n' "$normalized" "$unit_state" >> "$inventory_tmp"
        done < "$raw_inventory"
        ;;
    freebsd)
        service -r > "$work_dir/available.txt" || error "service -r could not collect ordered service scripts"
        service -e > "$work_dir/enabled.txt" || error "service -e could not collect boot-enabled services"
        while IFS= read -r service_name || [[ -n "$service_name" ]]; do
            read -r service_name _ <<< "$service_name"
            [[ -n "${service_name:-}" ]] || continue
            normalized=$(normalize_name "$service_name") || continue
            if awk -v name="$normalized" '
                { path=$0; sub(/^.*\//, "", path); sub(/\.sh$/, ""); if (path == name) found=1 }
                END { exit !found }
            ' "$work_dir/enabled.txt"; then
                printf '%s enabled\n' "$normalized" >> "$inventory_tmp"
            else
                printf '%s disabled\n' "$normalized" >> "$inventory_tmp"
            fi
        done < "$work_dir/available.txt"
        ;;
esac

LC_ALL=C sort -k1,1 -k2,2 -u "$inventory_tmp" -o "$inventory_tmp" || error "could not sort the collected service inventory"
awk 'NR > 1 && $1 == previous && $2 != previous_state { exit 1 } { previous=$1; previous_state=$2 }' "$inventory_tmp" || error "conflicting states were returned for a service"
chmod 0644 "$inventory_tmp" || error "cannot set readable permissions on current inventory"
mv -f -- "$inventory_tmp" "$INVENTORY_FILE" || error "cannot write current inventory: $INVENTORY_FILE"
inventory_tmp=''

awk -v platform="$CP_DISTRO" '
    FILENAME == ARGV[1] {
        expected[$1] = $2
        next
    }
    {
        current[$1] = $2
    }
    END {
        for (name in current) {
            if (!(name in expected)) {
                print "[extra] " name
                continue
            }
            actual = current[name]
            # systemd masked units cannot be enabled at boot. Static,
            # generated, indirect, alias and unknown states are present but
            # have no comparable enabled/disabled state.
            if (platform != "freebsd") {
                if (actual == "enabled-runtime") actual = "enabled"
                if (actual == "disabled-runtime" || actual == "masked" || actual == "masked-runtime") actual = "disabled"
                if (actual != "enabled" && actual != "disabled") actual = "other"
            }
            if (actual == "enabled" && expected[name] == "disabled") print "[enabled] " name
            else if (actual == "disabled" && expected[name] == "enabled") print "[disabled] " name
        }
        for (name in expected) if (!(name in current)) print "[missing] " name
    }
' "$work_dir/reference.normalized" "$INVENTORY_FILE" | LC_ALL=C sort > "$output_tmp"

chmod 0644 "$output_tmp" || error "cannot set readable permissions on comparison findings"
mv -f -- "$output_tmp" "$OUTPUT_FILE" || error "cannot write comparison findings: $OUTPUT_FILE"
output_tmp=''
printf 'Service comparison complete for %s. Findings: %s\n' "$CP_DISTRO" "$OUTPUT_FILE"
