# Rewrite only a conventional local passwd password stack. Unknown stacks fail.
/^[[:space:]]*password[[:space:]]/ {
    if ($3 ~ /(^|\/)pam_passwdqc\.so$/) next
    if ($3 !~ /(^|\/)pam_unix\.so$/ || $2 !~ /^(required|requisite)$/) {
        unsupported = 1
        next
    }
    unix_count++
    print "password requisite pam_passwdqc.so min=12,12,12,12,12 max=128 random=0 similar=deny retry=3 enforce=everyone"
    print "password required pam_unix.so no_warn try_first_pass"
    next
}
{ print }
END { if (unsupported || unix_count != 1) exit 2 }
