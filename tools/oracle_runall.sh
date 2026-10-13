#!/bin/bash
# tools/oracle_runall.sh : one of the oracle's runners on every build of a list, in parallel: any
# tool that takes <executable> <out file> (tools/oracle_lexrun.lua, tools/oracle_readrun.lua,
# tools/oracle_keywords.lua, tools/oracle_initrun.lua).
#
#   tools/oracle_runall.sh <list> <out dir> <tool> [parallel]
#
# The list is what tools/oracle_builds.lua writes: executable TAB name [TAB transfer chain], one
# build per line; a third column is that build's PDXORACLE_TRANSFER. Each build's result is
# <out dir>/<name>.tsv, its stderr <name>.tsv.err. Prints the time taken and how many builds could
# not be run (an #error line). The environment is tools/oracle_env.sh's.

. "$(dirname "$0")/oracle_env.sh"
if [ $# -lt 3 ]; then
    echo "usage: tools/oracle_runall.sh <list> <out dir> <tool> [parallel]" >&2
    exit 2
fi
list=$(realpath "$1")
OUT=$(realpath -m "$2")
TOOL=$3
par=${4:-16}
mkdir -p "$OUT"
cd "$PDXORACLE_REPO" || exit 1
export OUT TOOL

run_one() {
    local f n t
    IFS=$'\t' read -r f n t <<< "$1"
    [ -n "$f" ] || return 0
    if [ -n "$t" ]; then export PDXORACLE_TRANSFER="$t"; else unset PDXORACLE_TRANSFER; fi
    luajit "$TOOL" "$f" "$OUT/$n.tsv" > /dev/null 2> "$OUT/$n.tsv.err"
}
export -f run_one

time (grep -v '^#' "$list" | tr '\n' '\0' | xargs -0 -P "$par" -n 1 bash -c 'run_one "$1"' _)
echo "$(ls "$OUT"/*.tsv 2>/dev/null | wc -l) results, $(grep -l '^#error' "$OUT"/*.tsv 2>/dev/null | wc -l) could not be run"
