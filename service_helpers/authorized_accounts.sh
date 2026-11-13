#!/usr/bin/env bash
# Parse input/authorized_accounts.txt. Admin passwords are validated as input
# fields but deliberately never stored, logged, or used by existing workflows.
parse_authorized_accounts() {
    local file="$1" line section='' pending_admin='' line_number=0 saw_admins=0 saw_users=0 password_value username
    declare -gA AUTHORIZED_USERS=() AUTHORIZED_ADMINS=()
    [[ -f "$file" && ! -L "$file" && -r "$file" ]] || { echo "Cannot read authorized accounts file: $file" >&2; return 1; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_number += 1))
        line=${line//$'\r'/}
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -n "$line" ]] || continue
        case "$line" in
            'Authorized Administrators:')
                [[ -z "$pending_admin" ]] || { echo "Missing administrator password before line $line_number." >&2; return 1; }
                section=admins; saw_admins=1; continue ;;
            'Authorized Users:')
                [[ -z "$pending_admin" ]] || { echo "Missing administrator password before line $line_number." >&2; return 1; }
                section=users; saw_users=1; continue ;;
            \#*) continue ;;
        esac
        case "$section" in
            admins)
                if [[ "$line" == password:* ]]; then
                    [[ -n "$pending_admin" ]] || { echo "Unexpected password field on line $line_number." >&2; return 1; }
                    password_value=${line#password:}
                    password_value="${password_value#"${password_value%%[![:space:]]*}"}"
                    [[ -n "$password_value" ]] || { echo "Empty administrator password on line $line_number." >&2; return 1; }
                    AUTHORIZED_ADMINS["$pending_admin"]=1
                    AUTHORIZED_USERS["$pending_admin"]=1
                    pending_admin=''
                else
                    [[ -z "$pending_admin" ]] || { echo "Missing administrator password before line $line_number." >&2; return 1; }
                    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_.-]*\$?)([[:space:]]+\(you\))?$ ]]; then
                        pending_admin=${BASH_REMATCH[1]}
                    else
                        echo "Invalid administrator entry on line $line_number." >&2; return 1
                    fi
                fi ;;
            users)
                [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_.-]*\$?$ ]] || { echo "Invalid user entry on line $line_number." >&2; return 1; }
                AUTHORIZED_USERS["$line"]=1 ;;
            *) echo "Expected an Authorized Administrators or Authorized Users section before line $line_number." >&2; return 1 ;;
        esac
    done < "$file"
    [[ -z "$pending_admin" ]] || { echo 'The last administrator is missing a password field.' >&2; return 1; }
    ((saw_admins && saw_users)) || { echo 'The authorized accounts file must contain both required sections.' >&2; return 1; }
}
