#!/usr/bin/env bash
# Preserve unrelated INI sections and keys, including comments.
set_login_ini() {
    local file="$1" section="$2" key="$3" value="$4" temp
    temp=$(mktemp) || return 1
    if ! awk -v section="$section" -v key="$key" -v value="$value" '
        function finish() { if (inside && !written) { print key "=" value; written=1 } }
        /^[[:space:]]*\[/ {
            finish(); name=$0; sub(/^[[:space:]]*\[/,"",name); sub(/\].*$/,"",name)
            inside=(name==section); if (inside) { found=1; written=0 }
        }
        { line=$0; sub(/^[[:space:]]*/,"",line)
          if (inside && line ~ "^" key "[[:space:]]*=") {
              if (!written) print key "=" value; written=1; next
          }
          print
        }
        END { finish(); if (!found) print "[" section "]\n" key "=" value }
    ' "$file" > "$temp"; then rm -f "$temp"; return 1; fi
    cat "$temp" > "$file" || { rm -f "$temp"; return 1; }
    rm -f "$temp"
}

configure_other_login_manager() {
    local manager="$1" config
    case "$manager" in
        gdm3|gdm)
            # Debian packages use daemon.conf; Ubuntu uses custom.conf.
            if [[ "$CP_BASE" == debian ]]; then config=/etc/gdm3/daemon.conf
            else config=/etc/gdm3/custom.conf; fi
            [[ -f "$config" && ! -L "$config" && ! -L /etc/gdm3 ]] || {
                log "FAILED: expected regular GDM configuration $config"; return 1;
            }
            audit_file_change "$config" set_login_ini "$config" daemon AutomaticLoginEnable false || return 1
            audit_file_change "$config" set_login_ini "$config" daemon TimedLoginEnable false || return 1
            ;;
        sddm)
            # Main configuration overrides packaged drop-ins. Preserve all other keys.
            config=/etc/sddm.conf
            [[ ! -L "$config" && ( ! -e "$config" || -f "$config" ) ]] || return 1
            backup_system_paths "$config" || return 1
            if [[ ! -e "$config" ]]; then install -o root -g root -m 644 /dev/null "$config" || return 1; fi
            audit_file_change "$config" set_login_ini "$config" Autologin User '' || return 1
            audit_file_change "$config" set_login_ini "$config" Autologin Relogin false || return 1
            ;;
        *) log "PENDING: unsupported login manager $manager; configuration unchanged"; return 1 ;;
    esac
    log "Saved $manager policy disabling automatic login for $CP_DISTRO; active desktop retained"
}
