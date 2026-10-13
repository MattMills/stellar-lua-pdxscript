-- tools/oracle_tokens.lua : the tokens a game build's own lexer gives for a text, run in the
-- emulator.
--
--   luajit tools/oracle_tokens.lua <executable> -e 'a = { b "c" }'
--   luajit tools/oracle_tokens.lua <executable> <file>
--
-- Needs PDXORACLE_UNICORN (the path of libunicorn) unless unicorn is on the library path.

local here = arg[0]:match("^(.*)[/\\]tools[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. here .. "/?/init.lua;" .. package.path

local elf = require("oracle.elf")
local machine = require("oracle.machine")
local gamelexer = require("oracle.gamelexer")

local exe, a2, a3 = arg[1], arg[2], arg[3]
if not exe or not a2 then
    io.stderr:write("usage: luajit tools/oracle_tokens.lua <executable> (-e <text> | <file>)\n")
    os.exit(2)
end
local text
if a2 == "-e" then
    text = a3
else
    local f = assert(io.open(a2, "rb"))
    text = f:read("*a")
    f:close()
end

local t0 = os.clock()
local image = elf.load(exe)
local t1 = os.clock()
local m = machine.new(image)
local gl = gamelexer.new(m)
local t2 = os.clock()
io.stderr:write(string.format("%s: %d-bit%s, loaded in %.2fs, lexer ready in %.2fs\n", exe, image.bits,
    image.pie and " PIE" or "", t1 - t0, t2 - t1))
io.stderr:write(gl:describe() .. "\n")

local calls = gl:tokenize(text)
for i, c in ipairs(calls) do
    print(string.format("%4d rc=%d id=%-6d %-8s line=%-3s pos=%-4s last=%-3s unget=%s  %q", i, c.rc, c.id,
        c.quoted and "quoted" or "", tostring(c.line), tostring(c.pos), tostring(c.last),
        tostring(c.unget), c.text))
end
if calls.error then
    print("error: " .. calls.error)
end
io.stderr:write(string.format("%d calls in %.3fs\n", #calls, os.clock() - t2))
