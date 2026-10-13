-- tools/pe_calls.lua : the calls a function of a Windows executable makes, each target named
-- (symbols as oracle/image.lua finds them; the code disassembled by objdump).
--
--   luajit tools/pe_calls.lua <stellaris.exe> <decorated name or RVA> [bytes] [--all]
--
-- The function's size is its symbol's, else [bytes] (default 0x800). --all prints every
-- instruction, not only the calls.

local here = arg[0]:match("^(.*)[/\\]tools[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. package.path

local exe = assert(arg[1], "usage: luajit tools/pe_calls.lua <exe> <name or RVA> [bytes] [--all]")
local all = false
for i = 3, #arg do
    if arg[i] == "--all" then all = true end
end
local img = require("oracle.image").load(exe)
local rva = img:symbol(arg[2]) or tonumber(arg[2])
assert(rva, "no " .. tostring(arg[2]))
local size = img:function_size(rva) or tonumber(arg[3]) or 0x800
local a = img.base + rva
local p = io.popen(string.format('objdump -d --no-show-raw-insn --start-address=0x%x --stop-address=0x%x "%s"',
    a, a + size, exe))
for line in p:lines() do
    local at, ins, target = line:match("^%s*(%x+):%s+(call%S*)%s+(.*)$")
    if at then
        local t = target:match("^(%x+)")
        local name = t and img:name_at(tonumber(t, 16) - img.base) or ""
        print(at, ins, target, name)
    elseif all then
        print(line)
    end
end
p:close()
