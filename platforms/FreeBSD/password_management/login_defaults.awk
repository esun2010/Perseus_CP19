# Preserve all login classes and rewrite only the default class capabilities.
function flush_record(    clean,n,field,i,names,aliases,j,isdefault,result) {
    clean = record
    gsub(/\\\n[ \t]*/, "", clean)
    gsub(/\n/, "", clean)
    n = split(clean, field, ":")
    names = split(field[1], aliases, "[|]")
    isdefault = 0
    for (j=1; j<=names; j++) if (aliases[j] == "default") isdefault=1
    if (!isdefault) { printf "%s", record; record=""; return }
    defaults++
    result=field[1] ":passwordtime=90d:warnpassword=7d:"
    for (i=2; i<=n; i++) {
        if (field[i] ~ /^[ \t]*$/) continue
        if (field[i] ~ /^[ \t]*(passwordtime|warnpassword)([=#@]|$)/) continue
        result=result field[i] ":"
    }
    print result
    record=""
}
/^[ \t]*#/ || /^[ \t]*$/ { print; next }
{
    record=record $0 "\n"
    if ($0 !~ /\\$/) flush_record()
}
END { if (record != "" || defaults != 1) exit 2 }
