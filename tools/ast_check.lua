-- tools/ast_check.lua : pdxast over every script file of a Stellaris directory: printing each tree
-- gives its text back (byte for byte), pdxast.tree gives the tree pdxscript.parse gives, and the
-- diagnostics counted by kind.
--
--   luajit tools/ast_check.lua <Stellaris dir> [version] [--semantic] [--all]
--
-- By default the primary corpus (common, events, map/setup_scenarios, prescripted_countries,
-- flags: *.txt); --all adds interface and gfx (*.gui, *.gfx, *.asset), where pdxast keeps `,`
-- `(` `)` `;` as the game's lexer does and pdxscript reads them as parts of words, so their trees
-- may differ. --semantic also reads every file with pdxreader (the game's reading, slower).

local here = arg[0]:match("^(.*)[/\\]tools[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. package.path

local pdxast = require("pdxast")
local pdxscript = require("pdxscript")

local dir, version = arg[1], nil
local semantic, all = false, false
for i = 2, #arg do
    if arg[i] == "--semantic" then semantic = true
    elseif arg[i] == "--all" then all = true
    else version = arg[i] end
end

local function files()
    local list = {}
    local dirs = { "common", "events", "map/setup_scenarios", "prescripted_countries", "flags" }
    for _, d in ipairs(dirs) do
        local p = io.popen('find "' .. dir .. "/" .. d .. '" -type f -name "*.txt" 2>/dev/null | sort')
        for path in p:lines() do
            if not path:find("HOW_TO_MAKE_NEW_SHIPS", 1, true) then
                list[#list + 1] = path
            end
        end
        p:close()
    end
    if all then
        for _, d in ipairs({ "interface", "gfx" }) do
            local p = io.popen('find "' .. dir .. "/" .. d .. '" -type f \\( -name "*.gui" -o -name "*.gfx" -o -name "*.asset" \\) 2>/dev/null | sort')
            for path in p:lines() do
                list[#list + 1] = path
            end
            p:close()
        end
    end
    return list
end

-- the same tree: every field pdxscript sets (but warnings and name)
local function same(a, b, path)
    if type(a) ~= type(b) then
        return false, path .. ": " .. type(a) .. " / " .. type(b)
    end
    if type(a) ~= "table" then
        if a == b then return true end
        return false, path .. ": " .. tostring(a) .. " / " .. tostring(b)
    end
    for k, v in pairs(a) do
        if k ~= "warnings" and k ~= "name" then
            local ok, why = same(v, b[k], path .. "." .. tostring(k))
            if not ok then return false, why end
        end
    end
    for k, v in pairs(b) do
        if k ~= "warnings" and k ~= "name" and a[k] == nil then
            return false, path .. "." .. tostring(k) .. ": nil / " .. tostring(v)
        end
    end
    return true
end

local list = files()
local t0 = os.clock()
local bytes, printed_bad, tree_bad, parse_errors, split_files = 0, 0, 0, 0, 0
local punct_examples = {}
local codes, examples = {}, {}
for _, path in ipairs(list) do
    local f = io.open(path, "rb")
    local text = f:read("*a")
    f:close()
    bytes = bytes + #text
    local name = path:sub(#dir + 2)
    local ast = pdxast.parse(text, { name = name, version = version, semantic = semantic })
    if pdxast.print(ast) ~= text then
        printed_bad = printed_bad + 1
        if printed_bad <= 5 then print("PRINT DIFFERS: " .. name) end
    end
    for _, d in ipairs(ast.diagnostics) do
        codes[d.code] = (codes[d.code] or 0) + 1
        if not examples[d.code] then
            examples[d.code] = name .. ":" .. tostring(d.line) .. ": " .. d.message
        end
    end
    -- where the game's lexer splits what pdxscript reads as one word (`( ) ,`) or reads a comment
    -- (`;`) the trees differ by design: counted apart
    local split = false
    for _, t in ipairs(ast.tokens) do
        if t.type == pdxast.PUNCT then
            split = true
            punct_examples[#punct_examples + 1] = name .. ":" .. t.line .. ": " .. t.text
            break
        end
    end
    for _, d in ipairs(ast.diagnostics) do
        if d.code == "semicolon_comment" then
            split = true
        end
    end
    local tree = pdxscript.parse(text, name)
    if not tree then
        parse_errors = parse_errors + 1
    elseif split then
        split_files = split_files + 1
    else
        local ok, why = same(tree, pdxast.tree(ast), "tree")
        if not ok then
            tree_bad = tree_bad + 1
            if tree_bad <= 8 then print("TREE DIFFERS: " .. name .. "  " .. why) end
        end
    end
end
print(string.format("%d files, %.1f MB in %.2fs: %d print back differently, %d trees differ from pdxscript's (%d pdxscript errors, %d files with ( ) , ; not compared)",
    #list, bytes / 1e6, os.clock() - t0, printed_bad, tree_bad, parse_errors, split_files))
local keys = {}
for k in pairs(codes) do keys[#keys + 1] = k end
table.sort(keys, function(a, b) return codes[a] > codes[b] end)
for _, k in ipairs(keys) do
    print(string.format("  %-24s %7d   e.g. %s", k, codes[k], examples[k]:sub(1, 150)))
end
for i = 1, math.min(6, #punct_examples) do
    print("  ( ) , in " .. punct_examples[i])
end
os.exit((printed_bad == 0 and tree_bad == 0) and 0 or 1)
