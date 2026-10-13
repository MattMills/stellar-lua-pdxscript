#!/bin/bash
# tools/native/assemble.sh : oracle/hle.lua's native imports (hle.native) from their source, with GNU
# as: for 64 and 32 bits, n<bits>.s (memcpy, memmove, memset, memcmp, strlen, strcmp, tolower,
# toupper) then m<bits>.s (ceilf, ceil, floorf, floor, sqrtf, sqrt). Prints each one's code in
# hexadecimal and the offset of every function in it, as hle.native has them; with --check, also
# hle.native's own, and whether they are the same.
#
#   tools/native/assemble.sh [--check]

here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

assembled() {
    local bits=$1 code="" entries="" base=0 part value type name
    for part in n m; do
        as --"$bits" -o "$tmp/$part$bits.o" "$here/$part$bits.s" || exit 1
        objcopy -O binary -j .text "$tmp/$part$bits.o" "$tmp/$part$bits.bin" || exit 1
        code="$code$(xxd -p "$tmp/$part$bits.bin" | tr -d '\n')"
        while read -r value type name; do
            [ "$name" = f_end ] && continue
            entries="$entries ${name#f_}=$(printf '0x%x' $((base + 0x$value)))"
        done < <(nm -n "$tmp/$part$bits.o" | grep ' f_')
        base=$((base + $(stat -c %s "$tmp/$part$bits.bin")))
    done
    echo "$bits code $code"
    echo "$bits entries$entries"
}

{ assembled 64; assembled 32; } > "$tmp/assembled"
cat "$tmp/assembled"
if [ "$1" = --check ]; then
    . "$here/../oracle_env.sh"
    luajit - "$PDXORACLE_REPO" > "$tmp/hle" <<'EOF'
package.path = arg[1] .. "/?.lua;" .. package.path
local native = require("oracle.hle").native
for _, bits in ipairs({ 64, 32 }) do
    local n = native[bits]
    local list = {}
    for name, offset in pairs(n.entries) do list[#list + 1] = { name, offset } end
    table.sort(list, function(a, b) return a[2] < b[2] end)
    local entries = {}
    for _, e in ipairs(list) do entries[#entries + 1] = string.format("%s=0x%x", e[1], e[2]) end
    print(bits .. " code " .. n.code)
    print(bits .. " entries " .. table.concat(entries, " "))
end
EOF
    if cmp -s "$tmp/assembled" "$tmp/hle"; then
        echo "the same as oracle/hle.lua's"
    else
        echo "oracle/hle.lua has:"
        cat "$tmp/hle"
        exit 1
    fi
fi
