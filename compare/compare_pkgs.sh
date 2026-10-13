#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
OUTPUT_FILE="$SCRIPT_DIR/compare_pkgs.txt"

usage() { echo "Usage: $0 <trusted-package-list> <current-inventory-file>" >&2; }
error() { echo "compare_pkgs: $*" >&2; exit 1; }

(( $# == 2 )) || { usage; exit 2; }
REFERENCE_FILE=$1
INVENTORY_FILE=$2

# Resolve target paths through their physical parent directories without
# following the target itself. Comparison inputs and outputs may not be links.
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

# Use the shared detector so Mint and FreeBSD follow the project's platform
# selection rules. References are plain package names, one per line.
source "$ROOT_DIR/service_helpers/distribution.sh"
load_distribution || error "could not identify a supported distribution"
case "$CP_DISTRO" in
    ubuntu|debian|mint)
        command -v dpkg-query >/dev/null 2>&1 || error "dpkg-query is required on $CP_DISTRO"
        ;;
    freebsd)
        command -v pkg >/dev/null 2>&1 || error "FreeBSD pkg is required"
        ;;
    *) error "unsupported distribution: $CP_DISTRO" ;;
esac

inventory_dir=$(dirname -- "$INVENTORY_FILE")
output_dir=$(dirname -- "$OUTPUT_FILE")
inventory_tmp=$(mktemp "$inventory_dir/.compare-pkgs-inventory.XXXXXX") || error "cannot create inventory beside $INVENTORY_FILE"
output_tmp=$(mktemp "$output_dir/.compare-pkgs-output.XXXXXX") || { rm -f -- "$inventory_tmp"; error "cannot create findings beside $OUTPUT_FILE"; }
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/compare-pkgs.XXXXXX") || { rm -f -- "$inventory_tmp" "$output_tmp"; error "cannot create temporary comparison files"; }
cleanup() { rm -f -- "$inventory_tmp" "$output_tmp"; rm -rf -- "$work_dir"; }
trap cleanup EXIT

raw_inventory="$work_dir/packages.raw"
case "$CP_DISTRO" in
    ubuntu|debian|mint)
        dpkg-query -W -f='${db:Status-Status}\t${binary:Package}\n' > "$raw_inventory" || error "dpkg-query could not collect the installed package inventory"
        awk -F '\t' 'NF == 2 && $1 == "installed" { print $2 }' "$raw_inventory" > "$work_dir/packages.names"
        mv -- "$work_dir/packages.names" "$raw_inventory"
        ;;
    freebsd)
        pkg query -a '%n' > "$raw_inventory" || error "pkg could not collect the installed package inventory"
        ;;
esac

normalize_name() {
    local name=$1
    # Linux's binary:Package field may include an architecture qualifier.
    if [[ "$CP_DISTRO" != freebsd ]]; then name=${name%:*}; fi
    [[ "$name" =~ ^[[:alnum:]][[:alnum:].+_-]*$ ]] || return 1
    printf '%s\n' "$name"
}

while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%%#*}
    read -r line extra <<< "$line"
    [[ -z "${line:-}" ]] && continue
    [[ -z "${extra:-}" ]] || error "trusted reference must contain package names only (invalid line: $line $extra)"
    normalized=$(normalize_name "$line") || error "invalid package name in trusted reference: $line"
    printf '%s\n' "$normalized"
done < "$REFERENCE_FILE" | LC_ALL=C sort -u > "$work_dir/reference.txt"

while IFS= read -r package || [[ -n "$package" ]]; do
    [[ -z "$package" ]] && continue
    normalized=$(normalize_name "$package") || error "package manager returned an invalid package name"
    printf '%s\n' "$normalized"
done < "$raw_inventory" | LC_ALL=C sort -u > "$inventory_tmp"

# The second argument is always the freshly collected, normalized inventory.
# Publish it only after collection and validation have succeeded.
chmod 0644 "$inventory_tmp" || error "cannot set readable permissions on current inventory"
mv -f -- "$inventory_tmp" "$INVENTORY_FILE" || error "cannot write current inventory: $INVENTORY_FILE"
inventory_tmp=''

LC_ALL=C comm -13 "$work_dir/reference.txt" "$INVENTORY_FILE" | awk '{print "[extra] " $0}' > "$work_dir/extra.txt"
LC_ALL=C comm -23 "$work_dir/reference.txt" "$INVENTORY_FILE" | awk '{print "[missing] " $0}' > "$work_dir/missing.txt"
cat "$work_dir/extra.txt" "$work_dir/missing.txt" | LC_ALL=C sort > "$output_tmp"
chmod 0644 "$output_tmp" || error "cannot set readable permissions on comparison findings"
mv -f -- "$output_tmp" "$OUTPUT_FILE" || error "cannot write comparison findings: $OUTPUT_FILE"
output_tmp=''

printf 'Package comparison complete for %s. Findings: %s\n' "$CP_DISTRO" "$OUTPUT_FILE"
