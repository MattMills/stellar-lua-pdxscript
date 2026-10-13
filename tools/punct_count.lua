-- tools/punct_count.lua : over a game directory (or a mod), the places where the game's lexer and
-- pdxscript's words part: the `(` `)` `,` and `!` tokens pdxlexer makes (with the version's profile;
-- `!` is a comment before 3.x) and the `;` comments it skips, counted per area of the files
-- (common, events, interface, gfx, other) with the first place each is seen.
--
--   luajit tools/punct_count.lua <directory> [version, default 4.5.2]

local here = arg[0]:match("^(.*)[/\\]tools[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. package.path

local pdxlexer = require("pdxlexer")

local dir = assert(arg[1], "usage: luajit tools/punct_count.lua <directory> [version]")
local profile = pdxlexer.profile(arg[2] or "4.5.2")
local counts, examples = {}, {}

local function count(key, path, line)
    counts[key] = (counts[key] or 0) + 1
    if not examples[key] then
        examples[key] = path:sub(#dir + 2) .. ":" .. line
    end
end

local p = io.popen('find "' .. dir .. '" -type f \\( -name "*.txt" -o -name "*.gui" -o -name "*.gfx" -o -name "*.asset" \\)')
for path in p:lines() do
    local f = io.open(path, "rb")
    local text = f:read("*a")
    f:close()
    local area = path:find("/common/") and "common" or path:find("/events/") and "events" or
        path:find("/interface/") and "interface" or path:find("/gfx/") and "gfx" or "other"
    local lex = pdxlexer.new(text, profile)
    while true do
        local rc = lex:next()
        local t = lex.type
        if t == 5 or t == 6 or t == 8 then
            count(area .. " " .. lex.text, path, lex.line)
        end
        if rc == 0 then break end
    end
    -- the `;` comments (the lexer skips them): the text outside strings and `#` comments
    local in_string, i, n = false, 1, #text
    while i <= n do
        local c = text:byte(i)
        if c == 34 then
            in_string = not in_string
        elseif not in_string and (c == 35 or c == 59) then
            if c == 59 then
                count(area .. " ;", path, select(2, text:sub(1, i):gsub("\n", "")) + 1)
            end
            i = text:find("\n", i, true) or n
        end
        i = i + 1
    end
end
p:close()

local keys = {}
for k in pairs(counts) do keys[#keys + 1] = k end
table.sort(keys)
for _, k in ipairs(keys) do
    print(string.format("%-16s %7d   e.g. %s", k, counts[k], examples[k]))
end
