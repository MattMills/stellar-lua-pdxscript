#!/bin/bash
# tools/oracle_fuzzall.sh : tools/oracle_readfuzz.lua on every build of a list, in parallel: random
# texts read by each build's own reader and by pdxreader with its profile, every text read
# differently minimized. A build's version is the one its name starts with (v<version>).
#
#   tools/oracle_fuzzall.sh <list> <out dir> <count> <seed> [parallel] [--math]
#
# The list is tools/oracle_builds.lua's. <out dir>/<name>.out per build; prints the last line of
# each, in the order of versions.

. "$(dirname "$0")/oracle_env.sh"
if [ $# -lt 4 ]; then
    echo "usage: tools/oracle_fuzzall.sh <list> <out dir> <count> <seed> [parallel] [--math]" >&2
    exit 2
fi
list=$(realpath "$1")
OUT=$(realpath -m "$2")
COUNT=$3
SEED=$4
par=${5:-16}
MATH=$6
mkdir -p "$OUT"
cd "$PDXORACLE_REPO" || exit 1
export OUT COUNT SEED MATH

run_one() {
    local f n t v
    IFS=$'\t' read -r f n t <<< "$1"
    [ -n "$f" ] || return 0
    if [ -n "$t" ]; then export PDXORACLE_TRANSFER="$t"; else unset PDXORACLE_TRANSFER; fi
    v=$(echo "$n" | sed -E 's/^v([0-9.]+).*/\1/; s/\.$//')
    luajit tools/oracle_readfuzz.lua "$f" "$v" "$COUNT" "$SEED" $MATH > "$OUT/$n.out" 2>&1
}
export -f run_one

grep -v '^#' "$list" | tr '\n' '\0' | xargs -0 -P "$par" -n 1 bash -c 'run_one "$1"' _
for f in "$OUT"/*.out; do
    printf '%s\t%s\n' "$(basename "$f" .out)" "$(tail -n 1 "$f")"
done | sort -V
