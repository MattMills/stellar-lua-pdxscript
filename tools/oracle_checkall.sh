#!/bin/bash
# tools/oracle_checkall.sh : the Lua lexer or reader, with each build's profile, against every result
# of tools/oracle_runall.sh in a directory (tools/oracle_check_lexer.lua with pdxlexer.lua,
# tools/oracle_check_reader.lua). A build's version is the one its name starts with (v<version>).
#
#   tools/oracle_checkall.sh lexer|reader <dir of .tsv>
#
# One line per build, in the order of versions: name, version, the check's verdict; then each
# verdict with how many builds have it and the versions from the first to the last of them.

. "$(dirname "$0")/oracle_env.sh"
kind=$1
if [ $# -lt 2 ] || { [ "$kind" != lexer ] && [ "$kind" != reader ]; }; then
    echo "usage: tools/oracle_checkall.sh lexer|reader <dir of .tsv>" >&2
    exit 2
fi
dir=$(realpath "$2")
cd "$PDXORACLE_REPO" || exit 1

for f in "$dir"/*.tsv; do
    n=$(basename "$f" .tsv)
    v=$(echo "$n" | sed -E 's/^v([0-9.]+).*/\1/; s/\.$//')
    if [ "$kind" = lexer ]; then
        r=$(luajit tools/oracle_check_lexer.lua pdxlexer.lua "$f" "$v" 2>&1 | tail -1)
    else
        r=$(luajit tools/oracle_check_reader.lua "$f" "$v" 2>&1 | tail -1)
    fi
    printf '%s\t%s\t%s\n' "$n" "$v" "$r"
done | sort -t$'\t' -k2,2V -k1,1 | awk -F'\t' '
    { print; n[$3]++; if (!($3 in lo)) { lo[$3] = $2; order[++k] = $3 } hi[$3] = $2 }
    END { print ""; for (i = 1; i <= k; i++) printf "%5d  %s  (%s..%s)\n", n[order[i]], order[i], lo[order[i]], hi[order[i]] }'
