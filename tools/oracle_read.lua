-- tools/oracle_read.lua : the statements a game build's own reader reads from a text, run in the
-- emulator (oracle/gamereader.lua).
--
--   luajit tools/oracle_read.lua <executable> -e 'a = { b >= 1 } @x = 2 c = @x'
--   luajit tools/oracle_read.lua <executable> <file>

local here = arg[0]:match("^(.*)[/\\]tools[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. here .. "/?/init.lua;" .. package.path

local loader = require("oracle.image")  -- an ELF or a PE executable
local machine = require("oracle.machine")
local gamelexer = require("oracle.gamelexer")
local gamereader = require("oracle.gamereader")

local exe, a2, a3 = arg[1], arg[2], arg[3]
if not exe or not a2 then
    io.stderr:write("usage: luajit tools/oracle_read.lua <executable> (-e <text> | <file>)\n")
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

local m = machine.new(loader.load(exe))
local gl = gamelexer.new(m)
local gr = gamereader.new(gl)
io.stderr:write(string.format("reader: key +0x%x, operator +0x%x, value +0x%x; ReadMember is slot %d\n",
    gr.layout.key, gr.layout.op, gr.layout.value, gr.member_slot))

local tree = gr:read(text)
local function tok(t)
    if not t then return "-" end
    return string.format("%s%q(%d)", t.quoted and "Q" or "", t.text, t.id)
end
local function dump(block, indent)
    for _, e in ipairs(block) do
        print(string.format("%s%-4s key %s  op %s  value %s%s", indent, tostring(e.line), tok(e.key),
            tok(e.op), tok(e.value), e.op and "" or ("  next " .. tok(e.next))))
        if e.block then
            dump(e.block, indent .. "    ")
        end
    end
end
dump(tree, "")
print("show: " .. gamereader.show(tree))
if #tree.variables > 0 then print("variables: " .. table.concat(tree.variables, " ")) end
for _, l in ipairs(tree.log) do print("log: " .. (l:gsub("\n$", ""))) end
if tree.error then print("error: " .. tree.error) end
