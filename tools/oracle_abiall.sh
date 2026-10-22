#!/usr/bin/env bash
# tools/oracle_abiall.sh : the script ABI (tools/oracle_abi.lua, tools/oracle_abijson.lua) of every
# build of a list (tools/oracle_builds.lua), one build at a time, its classes in shards.
#
#   tools/oracle_abiall.sh <list> <out dir> [shards] [name pattern]
#
# <out dir>/<name>/: keywords.tsv, keys-<k>.tsv, log-<k>.txt; <out dir>/<name>.json when all its
# shards are done. A build whose JSON exists is skipped, so a stopped run goes on where it was.
# shards: default the number of processors. name pattern: an extended regular expression on the
# build's name (the list's second column).

set -u
. "$(dirname "${BASH_SOURCE[0]}")/oracle_env.sh"
list=$1 out=$2 shards=${3:-$(nproc)} pattern=${4:-.}
mkdir -p "$out"
cd "$PDXORACLE_REPO" || exit 1

while IFS=$'\t' read -r exe name _; do
    [ -n "$exe" ] || continue
    echo "$name" | grep -Eq -- "$pattern" || continue
    [ -s "$out/$name.json" ] && continue
    dir=$out/$name
    mkdir -p "$dir"
    start=$(date +%s)
    # (a file that ends in #done is kept: a stopped build goes on with the shards it had not done)
    grep -q '^#done' "$dir/keywords.tsv" 2>/dev/null ||
        luajit tools/oracle_abi.lua "$exe" "$dir/keywords.tsv" keywords > "$dir/log-keywords.txt" 2>&1
    for k in $(seq 1 "$shards"); do
        grep -q '^#done' "$dir/keys-$k.tsv" 2>/dev/null && continue
        luajit tools/oracle_abi.lua "$exe" "$dir/keys-$k.tsv" "$k/$shards" > "$dir/log-$k.txt" 2>&1 &
    done
    wait
    done_shards=$(grep -l '^#done' "$dir"/keys-*.tsv 2>/dev/null | wc -l)
    if [ "$done_shards" -eq "$shards" ]; then
        luajit tools/oracle_abijson.lua "$out/$name.json" "$dir/keywords.tsv" "$dir"/keys-*.tsv
    else
        echo "$name: $done_shards of $shards shards finished (logs in $dir)" >&2
    fi
    echo "$name: $(( $(date +%s) - start )) s"
done < "$list"
