-- pdxscript.lua : the syntax of Paradox script ("pdxscript", the Clausewitz/Jomini text format) as
-- Stellaris 4.5 writes it: source text -> a tree that keeps everything the text says, in order.
--
--   local pdxscript = require("pdxscript")
--   local tree, message = pdxscript.parse(text, "common/edicts/00_edicts.txt")
--   if tree == nil then error(message) end   -- "common/edicts/00_edicts.txt:12:9: expected a value after '='"
--   for _, w in ipairs(tree.warnings) do ... end     -- what was malformed but accepted
--   print(pdxscript.write(tree))                     -- back to text (without the comments)
--
-- The tree. A block is a Lua array of entries, in source order, duplicates kept:
--
--   block      { [1..n] = entry, line = n, type = "hsv" | nil }
--                line is the line of the '{'; type is the tag of a typed block (`hsv { ... }`).
--                The tree itself is the block of the file, with line = 1, name = the name given
--                to parse, and warnings = a list (see below).
--   entry      one of:
--     statement  { key = token, op = "=", value = token | block, line = n }
--                op is one of = == != < > <= >= ?= ; line is the line of the key.
--     token      a bare value in a list block: `{ a b "c" 1 }`.
--     block      a block in a list block: `{ { 1 2 } { 3 4 } }`, `{ rgb { 1 2 3 } }`.
--     condition  { param = "NAME", negated = true | nil, line = n, [1..n] = entry }
--                `[[NAME] ... ]` (negated: `[[!NAME] ... ]`), the parameter blocks of scripted
--                triggers, effects and values; the entries are those inside it.
--   An entry is a statement if it has .op, a token if it has .text, a condition if it has
--   .param, and a block otherwise. Blocks may mix statements and bare values (vanilla does:
--   `optimize_memory` in scripted effects, `prerequisites = { tech_a OR = { ... } }`).
--   token      { text = "...", quoted = true | nil, line = n }
--                text is the text as written: numbers, dates and booleans stay text ("-1.5",
--                "2200.01.01", "yes"); a quoted string is the text between the quotes with its
--                escapes as written (`"\\[Root.GetName]"` -> `\\[Root.GetName]`, see
--                pdxscript.unescape); inline math is one token with its brackets, `@[ a * 2 ]` or
--                `@\[ $P$ + 1 ]`. Scripted variables (`@my_var`), parameters (`$PARAM$`,
--                `$PARAM|default$`) and scope chains (`event_target:x`, `root.owner?`,
--                `value:v|P|5|`) are ordinary words: they mean something only to the interpreter.
--
-- Lexical rules (found in the 4.5.2 corpus: see README.md):
--   * UTF-8 with or without a BOM; lines end with LF (a CR is blank). Line numbers count LFs,
--     columns count bytes from 1.
--   * `#` starts a comment to the end of the line, except inside a quoted string.
--   * A quoted string runs to the next `"` that is not escaped by `\`; it may span lines (vanilla
--     passes script to inline scripts that way: `TRIGGER = "owner? = { ... }"`). `\"` and `\\`
--     are escapes; the only one vanilla uses is `\\`.
--   * Operators: = == != < > <= >= and ?= (a `?` that starts a token and is followed by `=`).
--     Stellaris writes "if it exists" scopes as `owner? = { }`, so a `?` inside a word is part
--     of the word: `owner?=` is `owner?` `=`, `owner ?= ` is `owner` `?=`.
--   * Braces { }, and the parameter brackets `[[NAME]`, `[[!NAME]` and `]`.
--   * `@[` or `@\[` starts inline math, which runs to the matching `]` (it may contain spaces,
--     `|abs|` bars, parameters and scripted variables).
--   * Anything else is a word: a run of bytes other than blanks and { } = < > ! " # [ ]. Words
--     hold letters, digits, non-ASCII bytes and _ . : @ $ % - + ' / | ? , ; ( ) * and so on.
--   * A word directly followed by a block is a typed block: `color = hsv { 0.5 0.2 0.8 }`, and,
--     in a list, `rgb { 1 2 3 }` (rgb, hsv, hsv360 and hex only; see the tolerances).
--
-- Tolerances. The game loads some malformed text; parse accepts these, does what the game does,
-- and adds { kind = "...", line = n, col = n, message = "..." } to tree.warnings:
--   missing_operator  `key { ... }` where the key is not a colour tag: read as `key = { ... }`.
--                     Vanilla: common/named_colors/01_trait_colors.txt (`trait_bg_active_glow {`),
--                     and .gui/.gfx/.asset files (`spriteType {`, `position {`, `rotation {0 0 0}`).
--   missing_close     the file ends inside blocks: they are closed there. Vanilla:
--                     gfx/models/effects/nomads.gfx, gfx/models/ui/nomads_frontend.gfx.
--   extra_close       a `}` with no block to close, at the top level: skipped. Not in vanilla
--                     4.5.2; the most common mistake in mods (that the game reads on after it
--                     is an assumption, not checked against the game).
-- Everything else that does not fit the grammar is an error: parse returns nil and
-- "name:line:col: message".

local pdxscript = {}

local byte, sub, find, format = string.byte, string.sub, string.find, string.format
local concat = table.concat

-- token kinds
local WORD, STRING, MATH, OPEN, CLOSE, OP, PARAM, PCLOSE, EOF = 1, 2, 3, 4, 5, 6, 7, 8, 9

-- the bytes of a word: all but blanks and the bytes that start another token
local IN_WORD = {}
for c = 0, 255 do
    IN_WORD[c] = true
end
for c in ("{}=<>!\"#[] \t\r\n\v\f"):gmatch(".") do
    IN_WORD[c:byte()] = false
end

-- the tags of a typed block that may stand alone in a list (colours, `colors = { rgb { ... } }`);
-- any other word followed by a block there is a key that lacks its `=`
local COLOUR = { rgb = true, hsv = true, hsv360 = true, hex = true }

local function token(text, quoted, line)
    if quoted then
        return { text = text, quoted = true, line = line }
    end
    return { text = text, line = line }
end

-- pdxscript.parse(text [, name]) -> tree | nil, message
function pdxscript.parse(text, name)
    name = name or "<text>"
    local s, n = text, #text
    local pos, line, line_start = 1, 1, 1
    if sub(s, 1, 3) == "\239\187\191" then
        pos, line_start = 4, 4
    end
    local warnings = {}
    local tree = { line = 1, name = name, warnings = warnings }

    -- the current token: its kind, text (word, string, math, operator, parameter name), line,
    -- position and the position its line starts at; tneg for `[[!NAME]`
    local tk, tv, tl, tp, tls, tneg

    -- an error at the current token (raised as a table, which parse returns as its message)
    local function fail(message)
        error({ format("%s:%d:%d: %s", name, tl, tp - tls + 1, message) }, 0)
    end

    local function warn(kind, message, l, p, ls)
        warnings[#warnings + 1] = { kind = kind, line = l, col = p - ls + 1, message = message }
    end

    local function lex()
        -- blanks and comments
        local c = byte(s, pos)
        while true do
            if c == 10 then
                line = line + 1
                pos = pos + 1
                line_start = pos
            elseif c == 32 or c == 9 or c == 13 or c == 11 or c == 12 then
                pos = pos + 1
            elseif c == 35 then
                pos = find(s, "\n", pos + 1, true) or n + 1
            else
                break
            end
            c = byte(s, pos)
        end
        tl, tp, tls = line, pos, line_start
        if c == nil then
            tk = EOF
            return
        end

        if IN_WORD[c] then
            if c == 64 then
                -- inline math: @[ ... ] or @\[ ... ], to the matching ]
                local d = byte(s, pos + 1)
                if d == 91 or (d == 92 and byte(s, pos + 2) == 91) then
                    local e, depth = pos + (d == 91 and 2 or 3), 1
                    while true do
                        local x = byte(s, e)
                        if x == 93 then
                            depth = depth - 1
                            if depth == 0 then
                                break
                            end
                        elseif x == 91 then
                            depth = depth + 1
                        elseif x == 10 then
                            line = line + 1
                            line_start = e + 1
                        elseif x == nil then
                            fail("inline math is not closed (no ']')")
                        end
                        e = e + 1
                    end
                    tk, tv = MATH, sub(s, pos, e)
                    pos = e + 1
                    return
                end
            elseif c == 63 and byte(s, pos + 1) == 61 then
                tk, tv = OP, "?="
                pos = pos + 2
                return
            end
            local e = pos + 1
            while IN_WORD[byte(s, e)] do
                e = e + 1
            end
            tk, tv = WORD, sub(s, pos, e - 1)
            pos = e
            return
        end

        if c == 34 then
            local e = pos + 1
            while true do
                local x = byte(s, e)
                if x == 34 then
                    break
                elseif x == 92 then
                    if byte(s, e + 1) == 10 then
                        line = line + 1
                        line_start = e + 2
                    end
                    e = e + 2
                elseif x == 10 then
                    line = line + 1
                    line_start = e + 1
                    e = e + 1
                elseif x == nil then
                    fail("the string is not closed (no '\"')")
                else
                    e = e + 1
                end
            end
            tk, tv = STRING, sub(s, pos + 1, e - 1)
            pos = e + 1
        elseif c == 123 then
            tk = OPEN
            pos = pos + 1
        elseif c == 125 then
            tk = CLOSE
            pos = pos + 1
        elseif c == 61 then
            if byte(s, pos + 1) == 61 then
                tk, tv = OP, "=="
                pos = pos + 2
            else
                tk, tv = OP, "="
                pos = pos + 1
            end
        elseif c == 60 or c == 62 then
            if byte(s, pos + 1) == 61 then
                tk, tv = OP, c == 60 and "<=" or ">="
                pos = pos + 2
            else
                tk, tv = OP, c == 60 and "<" or ">"
                pos = pos + 1
            end
        elseif c == 33 then
            if byte(s, pos + 1) ~= 61 then
                fail("'!' that is not part of '!=' or '[[!'")
            end
            tk, tv = OP, "!="
            pos = pos + 2
        elseif c == 91 then
            local _, e, negated, param = find(s, "^%[%[(!?)([^%]%s]+)%]", pos)
            if e == nil then
                fail("'[' that does not start '[[NAME]' or '@['")
            end
            tk, tv, tneg = PARAM, param, negated == "!"
            pos = e + 1
        else -- 93
            tk = PCLOSE
            pos = pos + 1
        end
    end

    -- the open blocks: stack[2d - 1] is the block that holds the one at depth d, stack[2d] how
    -- many entries it has
    local stack, depth = {}, 0
    local cur, count = tree, 0

    local function body()
        lex()
        while true do
            local k = tk
            if k == WORD or k == STRING or k == MATH then
                local ktext, kline, kp, kls = tv, tl, tp, tls
                lex()
                if tk == OP then
                    local op = tv
                    local key = token(ktext, k == STRING, kline)
                    lex()
                    local v = tk
                    if v == WORD or v == STRING or v == MATH then
                        local vtext, vline = tv, tl
                        lex()
                        if tk == OPEN and v == WORD then
                            -- key = hsv { ... }
                            local block = { type = vtext, line = tl }
                            count = count + 1
                            cur[count] = { key = key, op = op, value = block, line = kline }
                            depth = depth + 1
                            stack[2 * depth - 1], stack[2 * depth] = cur, count
                            cur, count = block, 0
                            lex()
                        else
                            count = count + 1
                            cur[count] = { key = key, op = op, value = token(vtext, v == STRING, vline), line = kline }
                        end
                    elseif v == OPEN then
                        local block = { line = tl }
                        count = count + 1
                        cur[count] = { key = key, op = op, value = block, line = kline }
                        depth = depth + 1
                        stack[2 * depth - 1], stack[2 * depth] = cur, count
                        cur, count = block, 0
                        lex()
                    elseif v == EOF then
                        fail("the file ends after '" .. op .. "' (no value)")
                    else
                        fail("expected a value after '" .. op .. "'")
                    end
                elseif tk == OPEN then
                    local block = { line = tl }
                    if k == WORD and COLOUR[ktext] then
                        -- rgb { ... } in a list
                        block.type = ktext
                        count = count + 1
                        cur[count] = block
                    else
                        warn("missing_operator", "'" .. ktext .. " {' read as '" .. ktext .. " = {'", kline, kp, kls)
                        count = count + 1
                        cur[count] = { key = token(ktext, k == STRING, kline), op = "=", value = block, line = kline }
                    end
                    depth = depth + 1
                    stack[2 * depth - 1], stack[2 * depth] = cur, count
                    cur, count = block, 0
                    lex()
                else
                    -- a bare value; the token after it is the next entry
                    count = count + 1
                    cur[count] = token(ktext, k == STRING, kline)
                end
            elseif k == OPEN then
                local block = { line = tl }
                count = count + 1
                cur[count] = block
                depth = depth + 1
                stack[2 * depth - 1], stack[2 * depth] = cur, count
                cur, count = block, 0
                lex()
            elseif k == CLOSE then
                if depth == 0 then
                    warn("extra_close", "'}' with no block to close, skipped", tl, tp, tls)
                elseif cur.param then
                    fail(format("'}' inside [[%s%s] (line %d), which ']' closes", cur.negated and "!" or "", cur.param, cur.line))
                else
                    cur, count = stack[2 * depth - 1], stack[2 * depth]
                    depth = depth - 1
                end
                lex()
            elseif k == PARAM then
                local condition = { param = tv, negated = tneg or nil, line = tl }
                count = count + 1
                cur[count] = condition
                depth = depth + 1
                stack[2 * depth - 1], stack[2 * depth] = cur, count
                cur, count = condition, 0
                lex()
            elseif k == PCLOSE then
                if not cur.param then
                    fail("']' with no '[[NAME]' to close")
                end
                cur, count = stack[2 * depth - 1], stack[2 * depth]
                depth = depth - 1
                lex()
            elseif k == OP then
                fail("'" .. tv .. "' with no key before it")
            else -- EOF
                while depth > 0 do
                    if cur.param then
                        fail(format("the file ends inside [[%s%s] (line %d)", cur.negated and "!" or "", cur.param, cur.line))
                    end
                    warn("missing_close", format("the file ends inside the block opened on line %d, closed there", cur.line), tl, tp, tls)
                    cur = stack[2 * depth - 1]
                    depth = depth - 1
                end
                return
            end
        end
    end

    local ok, err = pcall(body)
    if not ok then
        if type(err) == "table" then
            return nil, err[1]
        end
        error(err, 0)
    end
    return tree
end

-- pdxscript.unescape(text) -> text: the value of a quoted string, `\"` -> `"` and `\\` -> `\`.
-- (parse keeps the escapes: what `\\[` means is up to the reader, see README.md.)
function pdxscript.unescape(text)
    if find(text, "\\", 1, true) == nil then
        return text
    end
    return (text:gsub("\\([\\\"])", "%1"))
end

local function token_text(t)
    if t.quoted then
        return '"' .. t.text .. '"'
    end
    return t.text
end

-- pdxscript.write(block) -> text: a block (a tree, or any block in it) as script, one entry per
-- line, indented with tabs. Parsing the text gives the same tree (but for the lines, the
-- comments and the warnings).
function pdxscript.write(block)
    local out, n = {}, 0
    local entries

    local function value(v, indent)
        if v.text then
            n = n + 1
            out[n] = token_text(v)
            return
        end
        if v.type then
            n = n + 1
            out[n] = v.type .. " "
        end
        local flat = true
        for i = 1, #v do
            if not v[i].text then
                flat = false
                break
            end
        end
        if flat then
            n = n + 1
            out[n] = "{"
            for i = 1, #v do
                n = n + 1
                out[n] = " " .. token_text(v[i])
            end
            n = n + 1
            out[n] = " }"
        else
            n = n + 1
            out[n] = "{\n"
            entries(v, indent .. "\t")
            n = n + 1
            out[n] = indent .. "}"
        end
    end

    function entries(b, indent)
        for i = 1, #b do
            local e = b[i]
            n = n + 1
            out[n] = indent
            if e.op then
                n = n + 1
                out[n] = token_text(e.key) .. " " .. e.op .. " "
                value(e.value, indent)
            elseif e.param then
                n = n + 1
                out[n] = "[[" .. (e.negated and "!" or "") .. e.param .. "]\n"
                entries(e, indent .. "\t")
                n = n + 1
                out[n] = indent .. "]"
            else
                value(e, indent)
            end
            n = n + 1
            out[n] = "\n"
        end
    end

    entries(block, "")
    return concat(out)
end

return pdxscript
