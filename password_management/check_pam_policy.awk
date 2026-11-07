# Verify mandatory checks and module order after pam-auth-update merges profiles.
# Reject overrides that would make the configuration files ineffective.
{
    sub(/#.*/, "")
    if ($0 ~ /^[[:space:]]*$/) next
    line = $0
    sub(/^[[:space:]]*/, "", line)
    gsub(/[[:space:]]+/, " ", line)
    sub(/ $/, "", line)
    if ((FILENAME ~ /common-auth$/ && $1 != "auth") ||
        (FILENAME ~ /common-account$/ && $1 != "account") ||
        (FILENAME ~ /common-password$/ && $1 != "password")) bad=1
    if ($1 == "auth") {
        auth++
        if (strict && FILENAME ~ /common-auth$/ && $0 ~ /pam_unix\.so/ && $0 ~ /(^|[[:space:]])nullok(_secure)?([[:space:]]|$)/) bad=1
        if (line == "auth required pam_faillock.so preauth" && auth == 1) preauth++
        if (line == "auth [default=die] pam_faillock.so authfail") { authfail++; failure_line=auth }
        if ($0 ~ /pam_faillock\.so/) faillock_auth++
        if (line == "auth requisite pam_deny.so" && auth == failure_line + 1) deny++
    }
    if ($1 == "account") {
        account++
        if (line == "account required pam_faillock.so" && account == 1) reset++
        if ($0 ~ /pam_faillock\.so/) faillock_account++
    }
    if ($1 == "password") {
        password++
        if ($0 ~ /pam_pwquality\.so/) {
            quality++
            if (password != 1 || line !~ /^password (requisite|required) pam_pwquality\.so( |$)/) bad=1
            if (strict && line !~ /(^| )enforce_for_root( |$)/) bad=1
            # retry affects prompting only. All policy values must come from the file.
            for (i=4; i<=NF; i++) if ($i !~ /^retry=[1-9][0-9]*$/) bad=1
        }
        if ($0 ~ /pam_pwhistory\.so/) {
            history++
            history_line=password
            if ($0 !~ /remember=5/ || $0 !~ /use_authtok/ || $0 !~ /enforce_for_root/) bad=1
        }
        if ($0 ~ /pam_unix\.so/) unix_line=password
    }
}
END {
    if (preauth != 1 || authfail != 1 || deny != 1 || reset != 1 ||
        faillock_auth != 2 || faillock_account != 1 || quality != 1 ||
        (strict && (history != 1 || !unix_line || history_line >= unix_line)) || bad) {
        print "PAM policy validation failed: custom stack order or module overrides need review" > "/dev/stderr"
        exit 1
    }
}
