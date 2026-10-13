-- tools/pe_vtable.lua : the slots of a vtable of a Windows executable, each with the function it
-- points to, named (symbols as oracle/image.lua finds them).
--
--   luajit tools/pe_vtable.lua <stellaris.exe> <vtable's decorated name> [slots, default 16]
--
--   luajit tools/pe_vtable.lua stellaris.exe "??_7CTextLexer@@6B@"

local here = arg[0]:match("^(.*)[/\\]tools[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. package.path

local img = require("oracle.image").load(assert(arg[1], "usage: luajit tools/pe_vtable.lua <exe> <vtable> [slots]"))
local rva = assert(img:symbol(arg[2]), "no " .. tostring(arg[2]))
local w = img.bits / 8
for i = 0, (tonumber(arg[3]) or 16) - 1 do
    local s = img:read_rva(rva + i * w, w)
    local v = 0
    for k = w, 1, -1 do v = v * 256 + s:byte(k) end
    print(i, string.format("0x%x", v), img:name_at(v - img.base) or "")
end
