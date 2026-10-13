# tools/measure_ctype.py : oracle/hle_msvc_ctype.lua, measured on the Windows it runs on: every
# UTF-16 unit's GetStringTypeW(CT_CTYPE1) and LCMapStringW(0x409, LCMAP_LOWERCASE / UPPERCASE),
# and every byte's MultiByteToWideChar(1252), from kernel32. Writes the whole module.
#
#   py -3 -I tools/measure_ctype.py oracle/hle_msvc_ctype.lua
#
# Only on Windows (ctypes over kernel32). The module in the repository was measured on Windows 11.

import ctypes
import sys

HEADER = """\
-- oracle/hle_msvc_ctype.lua : Windows' character data, measured on Windows 11 (kernel32), for the
-- Windows API of oracle/hle_msvc.lua:
--   ctype1(u)   GetStringTypeW(CT_CTYPE1) of a UTF-16 unit: C1_UPPER 0x1, LOWER 0x2, DIGIT 0x4,
--               SPACE 0x8, PUNCT 0x10, CNTRL 0x20, BLANK 0x40, XDIGIT 0x80, ALPHA 0x100, DEFINED 0x200
--               (65536 calls, kept as runs of equal types: first unit:type, hexadecimal)
--   lower[u], upper[u]   LCMapStringW(0x409, LCMAP_LOWERCASE / LCMAP_UPPERCASE) of a unit, where it
--               is not the unit itself (unit:mapped)
--   cp1252[b]   MultiByteToWideChar(1252) of a byte (the bytes 0x80..0x9f that are not U+0080..U+009F;
--               0x81 0x8d 0x8f 0x90 0x9d map to themselves)
-- Written by tools/measure_ctype.py.
"""

CODE = """\
local first, value = {}, {}
for s, v in RUNS:gmatch("(%x+):(%x+)") do
    first[#first + 1] = tonumber(s, 16)
    value[#value + 1] = tonumber(v, 16)
end

local function pairs_of(text)
    local t = {}
    for a, b in text:gmatch("(%x+):(%x+)") do
        t[tonumber(a, 16)] = tonumber(b, 16)
    end
    return t
end

local data = { lower = pairs_of(LOWER), upper = pairs_of(UPPER), cp1252 = pairs_of(CP1252) }

function data.ctype1(u)
    local lo, hi = 1, #first
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if first[mid] <= u then lo = mid else hi = mid - 1 end
    end
    return value[lo]
end

return data
"""

LCMAP_LOWERCASE, LCMAP_UPPERCASE = 0x100, 0x200


def measure():
    k = ctypes.WinDLL("kernel32")
    get_type = k.GetStringTypeW
    get_type.argtypes = [ctypes.c_uint32, ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
    lcmap = k.LCMapStringW
    lcmap.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p,
                      ctypes.c_int]
    to_wide = k.MultiByteToWideChar
    to_wide.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p,
                        ctypes.c_int]
    unit = (ctypes.c_uint16 * 1)()
    out = (ctypes.c_uint16 * 4)()
    byte = (ctypes.c_uint8 * 1)()

    runs, previous = [], None
    lower, upper = [], []
    for u in range(65536):
        unit[0] = u
        t = out[0] if get_type(1, ctypes.addressof(unit), 1, ctypes.addressof(out)) else -1
        if t != previous:
            runs.append((u, t))
            previous = t
        for flag, mapped in ((LCMAP_LOWERCASE, lower), (LCMAP_UPPERCASE, upper)):
            n = lcmap(0x409, flag, ctypes.addressof(unit), 1, ctypes.addressof(out), 4)
            if n == 1 and out[0] != u:
                mapped.append((u, out[0]))
    cp1252 = []
    for b in range(256):
        byte[0] = b
        n = to_wide(1252, 0, ctypes.addressof(byte), 1, ctypes.addressof(out), 4)
        if n == 1 and out[0] != b:
            cp1252.append((b, out[0]))
    return runs, lower, upper, cp1252


# "a:b" pairs, hexadecimal, as many on a line as fit in 98 columns
def block(name, pairs):
    lines, line = [], ""
    for a, b in pairs:
        item = "%x:%x" % (a, b)
        if line and len(line) + 1 + len(item) > 98:
            lines.append(line)
            line = item
        else:
            line = line + " " + item if line else item
    if line:
        lines.append(line)
    return "local %s = [[\n%s\n]]\n" % (name, "\n".join(lines))


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: py -3 -I tools/measure_ctype.py <out file (oracle/hle_msvc_ctype.lua)>")
    runs, lower, upper, cp1252 = measure()
    text = "\n".join([HEADER, block("RUNS", runs), block("LOWER", lower), block("UPPER", upper),
                      block("CP1252", cp1252), CODE])
    with open(sys.argv[1], "w", newline="\n") as f:
        f.write(text)


main()
