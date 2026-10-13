-- tools/ast_diff.lua : one file read by pdxast and by pdxscript: the diagnostics of each, and
-- where pdxast.tree's tree first differs from pdxscript.parse's, with the text of both trees
-- around it (tools/ast_check.lua finds the files that differ).
--
--   luajit tools/ast_diff.lua <file> [version]

local here = arg[0]:match("^(.*)[/\\]tools[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. package.path

local pdxast = require("pdxast")
local pdxscript = require("pdxscript")

local f = assert(io.open(assert(arg[1], "usage: luajit tools/ast_diff.lua <file> [version]"), "rb"))
local text = f:read("*a")
f:close()
local ast = pdxast.parse(text, { name = arg[1], version = arg[2], semantic = false })
local parsed = pdxscript.parse(text)
for _, d in ipairs(ast.diagnostics) do print("pdxast", d.code, d.line, d.col, d.message) end
for _, w in ipairs(parsed.warnings or {}) do print("pdxscript", w.kind, w.line, w.col, w.message) end

-- a tree as one line of text
local function show(t)
    local out = {}
    for _, e in ipairs(t) do
        if e.op then
            out[#out + 1] = e.key.text .. e.op .. (e.value.text or ("{" .. show(e.value) .. "}"))
        elseif e.param then
            out[#out + 1] = "[[" .. (e.negated and "!" or "") .. e.param .. "]" .. show(e) .. "]"
        elseif e.text then
            out[#out + 1] = e.text
        else
            out[#out + 1] = "{" .. show(e) .. "}"
        end
    end
    return table.concat(out, " ")
end
local a, b = show(pdxast.tree(ast)), show(parsed)
if a == b then
    print("the trees are the same")
    return
end
local i = 1
while i <= #a and a:sub(i, i) == b:sub(i, i) do i = i + 1 end
print("the trees differ from character " .. i)
print("pdxast:    " .. a:sub(math.max(1, i - 150), i + 120))
print("pdxscript: " .. b:sub(math.max(1, i - 150), i + 120))
