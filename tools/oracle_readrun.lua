-- tools/oracle_readrun.lua : runs the cases of oracle/reader_cases.lua through one build's own
-- statement reader (oracle/gamereader.lua) and writes what it read, one line per case:
--
--   <case name> TAB <tree> [TAB vars=...] [TAB log=...] [TAB error=...]
--       a statement: key,op,value as id:"text" (a quoted token Q:id:"text"), - when absent; a
--       statement without an operator has the next token after "~"; a block follows in { }
--   #build TAB <path> TAB <layouts>  first line;  #error TAB <message>  when the reader could not be made
--
--   luajit tools/oracle_readrun.lua <executable> <out file>

local here = arg[0]:match("^(.*)[/\\]tools[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. here .. "/?/init.lua;" .. package.path

local elf = require("oracle.elf")
local machine = require("oracle.machine")
local gamelexer = require("oracle.gamelexer")
local gamereader = require("oracle.gamereader")
local cases = require("oracle.reader_cases")

local exe, out_path = arg[1], arg[2]
local out = assert(io.open(out_path, "wb"))

local function fail(message)
    out:write("#error\t", (tostring(message):gsub("[\r\n\t]", " ")), "\n")
    out:close()
    os.exit(1)
end

-- a machine with the reader ready. After a case where the game's code failed the next case gets a
-- new one: a read stopped half way can leave the game's globals in any state.
local ok, image = pcall(elf.load, exe)
if not ok then fail(image) end
local function make()
    local m = machine.new(image)
    local gl = gamelexer.new(m)
    local gr = gamereader.new(gl)
    -- a case the game never finishes (it reads past the end of the text) stops after 5 seconds
    m.timeout = 5
    return m, gl, gr
end
local m, gl, gr
ok, m, gl, gr = pcall(make)
if not ok then fail(m) end
out:write("#build\t", exe, "\t", gl:describe(), string.format("; reader key +0x%x op +0x%x value +0x%x",
    gr.layout.key, gr.layout.op, gr.layout.value), "\n")

local function q(s)
    return (string.format("%q", s):gsub("\n", "n"))
end

local function tok(t)
    if not t then return "-" end
    return (t.quoted and "Q:" or "") .. t.id .. ":" .. q(t.text)
end

local function serialize(block)
    local parts = {}
    for _, e in ipairs(block) do
        local s = tok(e.key) .. "," .. tok(e.op) .. "," .. tok(e.value)
        if not e.op then
            s = s .. "~" .. tok(e.next)
        end
        if e.block then
            s = s .. "{" .. serialize(e.block) .. "}"
        end
        parts[#parts + 1] = s
    end
    return table.concat(parts, " ")
end

for _, case in ipairs(cases) do
    local tree = gr:read(case.text)
    if tree.error then
        m:close()
        m, gl, gr = make()
    end
    local line = case.name .. "\t" .. serialize(tree)
    if #tree.variables > 0 then
        line = line .. "\tvars=" .. table.concat(tree.variables, ",")
    end
    if tree.inline_scripts and tree.inline_scripts > 0 then
        line = line .. "\tinline=" .. tree.inline_scripts
    end
    for _, l in ipairs(tree.log) do
        line = line .. "\tlog=" .. q((l:gsub("\n$", "")))
    end
    if tree.error then
        line = line .. "\terror=" .. tree.error:gsub("[\r\n\t]", " ")
    end
    out:write(line, "\n")
end
out:close()
