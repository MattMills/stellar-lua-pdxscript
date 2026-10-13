#!/bin/bash
# tools/elf_dis.sh : the disassembly (Intel syntax, names demangled) of a function of a Linux build,
# by its mangled name. The build's symbol table is cached in ${TMPDIR:-/tmp} (nm takes a while).
#
#   tools/elf_dis.sh <stellaris> <mangled name> [bytes, default 200] [lines, default 60]
#
#   tools/elf_dis.sh ".../v2.3.0 Wolfe .../stellaris" _ZN10CTextLexer6GetTokEv

if [ $# -lt 2 ]; then
    echo "usage: tools/elf_dis.sh <stellaris> <mangled name> [bytes] [lines]" >&2
    exit 2
fi
f=$1
nm_cache="${TMPDIR:-/tmp}/$(basename "$(dirname "$f")" | tr ' ' _).nm"
[ -s "$nm_cache" ] || nm "$f" > "$nm_cache" 2>/dev/null
a=$(grep -E " [TtWw] $2$" "$nm_cache" | head -1 | cut -d' ' -f1)
if [ -z "$a" ]; then
    echo "no $2 in $f" >&2
    exit 1
fi
echo "=== $2 @ $a"
objdump -d --no-show-raw-insn -M intel -C --start-address=0x"$a" \
    --stop-address="$(printf '0x%x' $((0x$a + ${3:-200})))" "$f" 2>/dev/null | tail -n +7 | head -"${4:-60}"
