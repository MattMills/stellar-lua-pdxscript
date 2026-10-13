-- tools/oracle_lexrun.lua : runs the cases of oracle/cases.lua through one build's own lexer and
-- writes what it gave, one line per case:
--
--   <case name> TAB <calls>        a call: rc,id,quoted,line,pos,last,unget,text (text %q-quoted),
--                                  calls separated by " | "
--   #build TAB <path> TAB <layout>  first line
--   #error TAB <message>            when the lexer could not be made
--
--   luajit tools/oracle_lexrun.lua <executable> <out file>

local here = arg[0]:match("^(.*)[/\\]tools[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. here .. "/?/init.lua;" .. package.path

local loader = require("oracle.image")  -- an ELF or a PE executable
local machine = require("oracle.machine")
local gamelexer = require("oracle.gamelexer")
local cases = require("oracle.cases")

local exe, out_path = arg[1], arg[2]
local out = assert(io.open(out_path, "wb"))

local function fail(message)
    out:write("#error\t", (tostring(message):gsub("[\r\n\t]", " ")), "\n")
    out:close()
    os.exit(1)
end

local ok, image = pcall(loader.load, exe)
if not ok then fail(image) end
local m
ok, m = pcall(machine.new, image)
if not ok then fail(m) end
local gl
ok, gl = pcall(gamelexer.new, m)
if not ok then fail(gl) end
out:write("#build\t", exe, "\t", gl:describe(), "\n")

local function serialize(calls)
    local parts = {}
    -- %q writes a line feed as a backslash and a line feed: kept on one line as \n
    local function q(s)
        return (string.format("%q", s):gsub("\n", "n"))
    end
    for i, c in ipairs(calls) do
        local s = string.format("%d,%d,%s,%s,%s,%s,%s,%s", c.rc, c.id, c.quoted and 1 or 0,
            tostring(c.line), tostring(c.pos), tostring(c.last), c.unget and 1 or 0, q(c.text))
        for _, t in ipairs(c.log or {}) do
            s = s .. " log=" .. q(t)
        end
        parts[i] = s
    end
    if calls.error then
        parts[#parts + 1] = "ERROR " .. calls.error:gsub("[\r\n\t]", " ")
    end
    return table.concat(parts, " | ")
end

for _, case in ipairs(cases) do
    local calls = gl:tokenize(case.text)
    out:write(case.name, "\t", serialize(calls), "\n")
end
out:close()
