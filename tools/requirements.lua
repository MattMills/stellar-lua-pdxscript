-- tools/requirements.lua : the versions of the game that know every built-in keyword the script of
-- a mod (or any directory of script, or one file) uses, and the keywords that narrow them.
--
--   luajit tools/requirements.lua <file or directory> [--version <v>]
--
-- --version reads the files with that version's lexer (pdxast; the latest by default). Only the
-- primary corpus' kind of files are read (*.txt).

local here = arg[0]:match("^(.*)[/\\]tools[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. package.path

local pdxast = require("pdxast")
local pdxversions = require("pdxversions")

local target, version = arg[1], nil
for i = 2, #arg do
    if arg[i] == "--version" then version = arg[i + 1] end
end

local files = {}
local p = io.popen('find "' .. target .. '" -type f -name "*.txt" 2>/dev/null | sort')
for path in p:lines() do
    if not path:find("HOW_TO_MAKE_NEW_SHIPS", 1, true) then
        files[#files + 1] = path
    end
end
p:close()

local r
for _, path in ipairs(files) do
    local f = io.open(path, "rb")
    local text = f:read("*a")
    f:close()
    local ast = pdxast.parse(text, { name = path:sub(#target + 2), version = version, semantic = false })
    r = pdxversions.requirements(ast, r)
end
if not r then
    print("no script files")
    os.exit(1)
end
print(string.format("%d files, %d words that are keywords of a measured version; the versions that know the most of them: %s",
    #files, r.used, table.concat(r.best, " ")))
print("  per version: known of " .. r.used)
local line = {}
for _, c in ipairs(r.coverage) do
    line[#line + 1] = string.format("%s %d (%.1f%%)", c.version, c.known, 100 * c.share)
    if #line == 4 then
        print("    " .. table.concat(line, "   "))
        line = {}
    end
end
if #line > 0 then print("    " .. table.concat(line, "   ")) end
