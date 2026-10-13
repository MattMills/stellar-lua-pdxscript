-- tools/oracle_keywords.lua : the keywords compiled into a build (oracle/gamekeywords.lua), one per
-- line: id TAB name.
--
--   luajit tools/oracle_keywords.lua <executable> <out file>

local here = arg[0]:match("^(.*)[/\\]tools[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. here .. "/?/init.lua;" .. package.path

local elf = require("oracle.elf")
local machine = require("oracle.machine")
local gamelexer = require("oracle.gamelexer")
local gamekeywords = require("oracle.gamekeywords")

local exe, out_path = arg[1], arg[2]
local out = assert(io.open(out_path, "wb"))
local ok, err = pcall(function()
    local m = machine.new(elf.load(exe))
    local gl = gamelexer.new(m)
    local list = gamekeywords.read(gl)
    out:write("#build\t", exe, "\t", #list, " keywords\n")
    for _, k in ipairs(list) do
        out:write(k.id, "\t", k.name or "?", "\n")
    end
end)
if not ok then
    out:write("#error\t", (tostring(err):gsub("[\r\n\t]", " ")), "\n")
end
out:close()
