-- pdxast.lua : Paradox script as a full syntax tree: lossless (every byte of the text is in a
-- token or the trivia before one, and printing the tree gives the text back), typed (each value
-- knows what it is: a number, a date, a scope chain, a scripted variable, inline math with its
-- expression, ...), positioned (byte offsets, lines and columns), and read the way a given version
-- of the game reads it (pdxlexer's and pdxreader's profiles), with what that version does
-- differently from what the text says reported as diagnostics. It never fails: what does not fit
-- the grammar is an error node and a diagnostic, and the reading goes on.
--
--   local pdxast = require("pdxast")
--   local ast = pdxast.parse(text, { name = "common/x.txt", version = "3.8.4" })
--   pdxast.print(ast) == text                      -- always
--   for _, d in ipairs(ast.diagnostics) do print(d.severity, d.code, d.line, d.col, d.message) end
--   pdxast.walk(ast, function(node, parent) ... end)
--   pdxast.tree(ast)                                -- the same tree as pdxscript.parse
--
-- The nodes (every node: kind, from, to = byte offsets of its first and last byte, 1-based):
--   file        entries; tokens (all of them, in order); trailing (the trivia after the last);
--               diagnostics; name; profile
--   statement   key (a value), op (a token: = == != < > <= >= ?=), value (a value or a block);
--               variable = true for `@name = ...` (a scripted variable's definition)
--   value       token; type: string | number | date | bool | word | scope | variable | math |
--               parameter | punct; and by type: value (the string's text, unescaped; the
--               number); integer (true when the number has no fraction); name (variable);
--               links (scope: { { prefix = "event_target", name = "x", nullable = true }, ... });
--               expression (math: see pdxast.parse_math); params (the $NAME$ in it)
--   block       open, close (tokens; close nil when the file ends first), entries, tag (the
--               token of a typed block's word: `hsv { ... }`)
--   condition   open (the `[[NAME]` token), name, negated, entries, close
--   error       token, message
-- A token: { type = WORD | STRING | MATH | OPEN | CLOSE | OP | PARAM | PCLOSE | PUNCT, text (the
-- bytes of the text), lead (the trivia before it: blanks and comments), from, to, line, col }.
--
-- Lexing is the game's (GetTok, pdxlexer): `;` starts a comment like `#`; `(`, `)` and `,` are
-- tokens of their own (PUNCT); `!` starts a comment before 3.x and is a token after; a `?` is
-- part of a word (`?=` is the word `?` and `=`). Two departures, for what the text means rather
-- than how the game splits it: `@[ ... ]` is one MATH token to its `]` (the game reads the rest
-- with ReadUntilCharacter, to the first `]` too), and `[[NAME]`, `[[!NAME]` and their `]` are
-- tokens of their own inside scripted triggers, effects and values (the game cuts the text there
-- before reading it). Outside a parameter block `[` and `]` are bytes of words, as to the game.

local pdxast = {}

local byte, sub, find, format = string.byte, string.sub, string.find, string.format

local ok_reader, pdxreader = pcall(require, "pdxreader")
if not ok_reader then
    pdxreader = nil
end
local pdxlexer = require("pdxlexer")

local WORD, STRING, MATH, OPEN, CLOSE, OP, PARAM, PCLOSE, PUNCT, EOF =
    "WORD", "STRING", "MATH", "OPEN", "CLOSE", "OP", "PARAM", "PCLOSE", "PUNCT", "EOF"
pdxast.WORD, pdxast.STRING, pdxast.MATH, pdxast.OPEN, pdxast.CLOSE = WORD, STRING, MATH, OPEN, CLOSE
pdxast.OP, pdxast.PARAM, pdxast.PCLOSE, pdxast.PUNCT = OP, PARAM, PCLOSE, PUNCT

-- the bytes that end a word, as GetTok's: blanks and the bytes that are tokens of their own
local BLANK = {}
for _, b in ipairs({ 9, 10, 11, 12, 13, 32 }) do
    BLANK[b] = true
end
local function stop_table(bang_comment)
    local t = {}
    for b in pairs(BLANK) do
        t[b] = true
    end
    for c in ("{}=<>!\"#;(),"):gmatch(".") do
        t[c:byte()] = true
    end
    return t
end

local COLOUR = { rgb = true, hsv = true, hsv360 = true, hex = true }

-- the positions of the lines: line_at(offset) -> line, column
local function line_index(text)
    local starts = { 1 }
    local i = 0
    while true do
        i = find(text, "\n", i + 1, true)
        if not i then
            break
        end
        starts[#starts + 1] = i + 1
    end
    return function(offset)
        local lo, hi = 1, #starts
        while lo < hi do
            local mid = math.floor((lo + hi + 1) / 2)
            if starts[mid] <= offset then
                lo = mid
            else
                hi = mid - 1
            end
        end
        return lo, offset - starts[lo] + 1
    end
end

-- the scanner: the tokens of text, each with the trivia before it
local function scan(text, profile, diag)
    local lexp = profile and profile.lexer or pdxlexer.profile()
    local bang_comment = lexp.bang == "comment"
    local STOP = stop_table(bang_comment)
    local n = #text
    local tokens = {}
    local pos = 1
    if sub(text, 1, 3) == "\239\187\191" then
        pos = 4
    end
    local params = 0
    local lead_from = 1
    while true do
        -- trivia: blanks and comments
        while pos <= n do
            local c = byte(text, pos)
            if BLANK[c] then
                pos = pos + 1
            elseif c == 35 or c == 59 or (c == 33 and bang_comment) then
                if c == 59 then
                    diag("info", "semicolon_comment", pos, "';' starts a comment, as '#' does")
                elseif c == 33 then
                    diag("warning", "bang_comment", pos,
                        "'!' starts a comment before 3.x: the rest of the line is not read")
                end
                local e = find(text, "\n", pos, true)
                pos = e or n + 1
            else
                break
            end
        end
        local lead = sub(text, lead_from, pos - 1)
        if pos > n then
            return tokens, lead
        end
        local c = byte(text, pos)
        local from = pos
        local tt, value
        if c == 34 then
            -- a quoted string to the next quote with no backslash before it (the end of the file
            -- ends it: the game reads it so)
            local e, prev = pos + 1, 0
            while e <= n do
                local x = byte(text, e)
                if x == 34 and prev ~= 92 then
                    break
                end
                if prev == 92 and (x == 34 or x == 92) then
                    prev = 0
                else
                    prev = x
                end
                e = e + 1
            end
            if e > n then
                diag("error", "unclosed_string", from, "the string is not closed (no '\"'): the game reads it to the end of the file")
                e = n
                pos = n + 1
            else
                pos = e + 1
            end
            tt = STRING
        elseif c == 123 then
            tt, pos = OPEN, pos + 1
        elseif c == 125 then
            tt, pos = CLOSE, pos + 1
        elseif c == 61 then
            if byte(text, pos + 1) == 61 then
                tt, pos = OP, pos + 2
            else
                tt, pos = OP, pos + 1
            end
        elseif c == 60 or c == 62 then
            tt, pos = OP, pos + (byte(text, pos + 1) == 61 and 2 or 1)
        elseif c == 33 then
            if byte(text, pos + 1) == 61 then
                tt, pos = OP, pos + 2
            else
                tt, pos = PUNCT, pos + 1
            end
        elseif c == 40 or c == 41 or c == 44 then
            tt, pos = PUNCT, pos + 1
        elseif c == 64 and (byte(text, pos + 1) == 91 or (byte(text, pos + 1) == 92 and byte(text, pos + 2) == 91)) then
            -- inline math to its ']'
            local e = find(text, "]", pos, true)
            if not e then
                diag("error", "unclosed_math", from, "inline math is not closed (no ']'): the game reads past the end of the file")
                e = n
            end
            tt, pos = MATH, e + 1
        elseif c == 91 and byte(text, pos + 1) == 91 then
            local _, e = find(text, "^%[%[!?[^%]%s]+%]", pos)
            if e then
                tt, pos = PARAM, e + 1
                params = params + 1
            end
        elseif c == 93 and params > 0 then
            tt, pos = PCLOSE, pos + 1
            params = params - 1
        end
        if not tt then
            -- a word: to a blank or a byte that is a token of its own (a ']' that closes a
            -- parameter block too)
            local e = pos + 1
            while e <= n do
                local x = byte(text, e)
                if STOP[x] or (x == 93 and params > 0) then
                    break
                end
                e = e + 1
            end
            tt, pos = WORD, e
        end
        tokens[#tokens + 1] = { type = tt, text = sub(text, from, pos - 1), lead = lead, from = from, to = pos - 1 }
        lead_from = pos
    end
end

-- values ---------------------------------------------------------------------------------------------

local function unescape(s)
    return (s:gsub("\\([\\\"])", "%1"))
end

-- the scope chain of a word: links separated by '.', each `prefix:name` or a name, and '?' at its
-- end for "if it exists"
local function links_of(text)
    if not (find(text, ".", 1, true) or find(text, ":", 1, true)) then
        return nil
    end
    local links = {}
    for part in (text .. "."):gmatch("(.-)%.") do
        local link = {}
        if sub(part, -1) == "?" then
            link.nullable = true
            part = sub(part, 1, -2)
        end
        local prefix, name = part:match("^([%w_]+):(.*)$")
        if prefix then
            link.prefix, link.name = prefix, name
        else
            link.name = part
        end
        links[#links + 1] = link
    end
    return links
end

-- pdxast.parse_math(text) -> expression, message: the expression of inline math (what is between
-- `@[` and `]`) as a tree: { op = "+", left, right }, { op = "neg", operand }, { op = "abs",
-- operand }, { number = n, text }, { name = "x" } (a scripted variable or parameter), or nil and
-- a message. The grammar is the one the game's evaluator reads: + - * / % (from 3.x), left
-- associative, * / % before + -, unary minus, ( ), | | for the absolute value.
function pdxast.parse_math(text)
    local toks = {}
    local i, n = 1, #text
    while i <= n do
        local c = sub(text, i, i)
        if c:match("%s") then
            i = i + 1
        elseif c:match("[%d%.]") then
            local num = text:match("^[%d%.]+", i)
            toks[#toks + 1] = { kind = "number", text = num }
            i = i + #num
        elseif c == "$" then
            -- a parameter, $NAME$ or $NAME|default$, to its closing '$'
            local e = text:find("$", i + 1, true) or n
            toks[#toks + 1] = { kind = "name", text = sub(text, i, e) }
            i = e + 1
        elseif c:match("[%a_@]") then
            local name = text:match("^@?[%w_]+", i) or c
            toks[#toks + 1] = { kind = "name", text = name }
            i = i + #name
        else
            toks[#toks + 1] = { kind = c }
            i = i + 1
        end
    end
    local p = 1
    local expr, term, factor
    local function peek() return toks[p] and toks[p].kind end
    function factor()
        local t = toks[p]
        if not t then return nil, "the expression ends too soon" end
        if t.kind == "-" then
            p = p + 1
            local operand, err = factor()
            if not operand then return nil, err end
            return { op = "neg", operand = operand }
        elseif t.kind == "(" then
            p = p + 1
            local e, err = expr()
            if not e then return nil, err end
            if peek() ~= ")" then return nil, "')' expected" end
            p = p + 1
            return e
        elseif t.kind == "|" then
            p = p + 1
            local e, err = expr()
            if not e then return nil, err end
            if peek() ~= "|" then return nil, "'|' expected" end
            p = p + 1
            return { op = "abs", operand = e }
        elseif t.kind == "number" then
            p = p + 1
            return { number = tonumber(t.text), text = t.text }
        elseif t.kind == "name" then
            p = p + 1
            return { name = (t.text:gsub("^@", ""):gsub("^%$([^$|]*).-%$$", "%1")), text = t.text }
        end
        return nil, "unexpected '" .. t.kind .. "'"
    end
    function term()
        local left, err = factor()
        if not left then return nil, err end
        while peek() == "*" or peek() == "/" or peek() == "%" do
            local op = peek()
            p = p + 1
            local right
            right, err = factor()
            if not right then return nil, err end
            left = { op = op, left = left, right = right }
        end
        return left
    end
    function expr()
        local left, err = term()
        if not left then return nil, err end
        while peek() == "+" or peek() == "-" do
            local op = peek()
            p = p + 1
            local right
            right, err = term()
            if not right then return nil, err end
            left = { op = op, left = left, right = right }
        end
        return left
    end
    local e, err = expr()
    if e and p <= #toks then
        return nil, "unexpected '" .. (toks[p].text or toks[p].kind) .. "'"
    end
    return e, err
end

local function value_node(tok)
    local v = { kind = "value", token = tok, from = tok.from, to = tok.to }
    local text = tok.text
    if tok.type == STRING then
        v.type = "string"
        local inner = sub(text, 2, sub(text, -1) == "\"" and #text > 1 and -2 or -1)
        v.value = unescape(inner)
    elseif tok.type == MATH then
        v.type = "math"
        local inner = text:match("^@\\?%[(.*)%]$") or text:match("^@\\?%[(.*)$") or ""
        v.source = inner
        v.expression, v.math_error = pdxast.parse_math(inner)
    elseif tok.type == PUNCT then
        v.type = "punct"
    elseif find(text, "$", 1, true) then
        v.type = "parameter"
        v.params = {}
        for name in text:gmatch("%$([^$|]+)[^$]*%$") do
            v.params[#v.params + 1] = name
        end
    elseif byte(text, 1) == 64 then
        v.type = "variable"
        v.name = sub(text, 2)
    elseif text == "yes" or text == "no" then
        v.type = "bool"
        v.value = text == "yes"
    elseif text:match("^%-?%d+%.%d+%.%d+$") then
        v.type = "date"
    elseif text:match("^[%+%-]?%d+$") then
        v.type, v.value, v.integer = "number", tonumber(text), true
    elseif text:match("^[%+%-]?%d*%.%d+$") or text:match("^[%+%-]?%d+%.%d*$") then
        v.type, v.value = "number", tonumber(text)
    else
        v.links = links_of(text)
        v.type = v.links and "scope" or "word"
    end
    return v
end

-- the parser ------------------------------------------------------------------------------------------

-- pdxast.parse(text [, options]) -> ast. options: name, version (the profile; the latest without
-- one), lookup (the static lexer, for pdxreader), semantic (default true: the game's reading
-- with pdxreader, whose bugs and messages become diagnostics)
function pdxast.parse(text, options)
    options = options or {}
    local profile = pdxreader and pdxreader.profile(options.version) or { lexer = pdxlexer.profile(options.version) }
    local where = line_index(text)
    local diagnostics = {}
    local function diag(severity, code, offset, message)
        local line, col = where(offset)
        diagnostics[#diagnostics + 1] = { severity = severity, code = code, offset = offset, line = line,
            col = col, message = message }
    end
    local tokens, trailing = scan(text, profile, diag)
    for _, t in ipairs(tokens) do
        t.line, t.col = where(t.from)
    end

    local i = 1
    local function peek(k) return tokens[i + (k or 0)] end

    local block_entries
    -- a value where one is expected after an operator: a token, a block, a typed block
    local function value_after(op)
        local t = peek()
        if not t then
            diag("error", "no_value", op.to, "the file ends after '" .. op.text .. "' (no value)")
            return nil
        end
        if t.type == OPEN then
            i = i + 1
            local b = { kind = "block", open = t, from = t.from }
            b.entries = block_entries(b)
            return b
        end
        if t.type == WORD or t.type == STRING or t.type == MATH or t.type == PUNCT then
            i = i + 1
            local nxt = peek()
            if t.type == WORD and nxt and nxt.type == OPEN then
                i = i + 1
                local b = { kind = "block", tag = t, open = nxt, from = t.from }
                b.entries = block_entries(b)
                return b
            end
            return value_node(t)
        end
        diag("error", "no_value", t.from, "expected a value after '" .. op.text .. "'")
        return nil
    end

    -- the entries of a block, to its '}' (consumed: b.close), or of the file (b nil)
    function block_entries(b)
        local entries = {}
        while true do
            local t = peek()
            if not t then
                if b and b.kind == "block" then
                    diag("warning", "missing_close", b.open.from, "the file ends inside this block: the game closes it there")
                    b.to = tokens[#tokens].to
                elseif b then
                    diag("error", "unclosed_param", b.open.from, "the file ends inside this parameter block")
                    b.to = tokens[#tokens].to
                end
                return entries
            end
            if t.type == CLOSE then
                i = i + 1
                if b and b.kind == "block" then
                    b.close, b.to = t, t.to
                    return entries
                elseif b then
                    diag("error", "close_in_param", t.from, "'}' inside a parameter block, which ']' closes")
                    entries[#entries + 1] = { kind = "error", token = t, message = "'}' inside a parameter block", from = t.from, to = t.to }
                else
                    diag("warning", "extra_close", t.from, "'}' with no block to close: skipped (the game reads on)")
                    entries[#entries + 1] = { kind = "error", token = t, message = "'}' with no block to close", from = t.from, to = t.to }
                end
            elseif t.type == PCLOSE then
                i = i + 1
                if b and b.kind == "condition" then
                    b.close, b.to = t, t.to
                    return entries
                end
                entries[#entries + 1] = { kind = "error", token = t, message = "']' with no '[[NAME]' to close", from = t.from, to = t.to }
                diag("error", "stray_bracket", t.from, "']' with no '[[NAME]' to close")
            elseif t.type == PARAM then
                i = i + 1
                local negated, name = t.text:match("^%[%[(!?)([^%]]+)%]$")
                local c = { kind = "condition", open = t, name = name, negated = negated == "!" or nil, from = t.from }
                c.entries = block_entries(c)
                entries[#entries + 1] = c
            elseif t.type == OPEN then
                i = i + 1
                local nb = { kind = "block", open = t, from = t.from }
                nb.entries = block_entries(nb)
                entries[#entries + 1] = nb
            elseif t.type == OP then
                -- the game reads it as a key and the token after it as its operator: a '}' there
                -- does not close the block
                i = i + 1
                diag("warning", "stray_operator", t.from, "'" .. t.text .. "' with no key before it: the game reads it as a key")
                entries[#entries + 1] = { kind = "error", token = t, message = "operator with no key", from = t.from, to = t.to }
                local nxt = peek()
                if nxt and nxt.type == CLOSE then
                    i = i + 1
                    diag("warning", "stray_operator", nxt.from, "'}' after '" .. t.text .. "' is read with it: the block stays open")
                    entries[#entries + 1] = { kind = "error", token = nxt, message = "'}' read with a stray operator", from = nxt.from, to = nxt.to }
                end
            else
                -- a key, or a bare value
                i = i + 1
                local key = value_node(t)
                local nxt = peek()
                if nxt and nxt.type == OP then
                    i = i + 1
                    local st = { kind = "statement", key = key, op = nxt, from = t.from }
                    if t.type == WORD and t.text == "?" then
                        diag("warning", "question_operator", t.from, "'?=' is not an operator in Stellaris: the game reads the key '?' (and a word before it as a value)")
                    end
                    if nxt.text == "==" then
                        diag("warning", "double_equals", nxt.from, "'==' is two '=' to the game: the value is '='")
                    end
                    local v = value_after(nxt)
                    st.value = v
                    st.to = v and v.to or nxt.to
                    if key.type == "variable" then
                        st.variable = true
                    end
                    entries[#entries + 1] = st
                elseif nxt and nxt.type == OPEN and not (t.type == WORD and COLOUR[t.text]) and t.type ~= PUNCT then
                    i = i + 1
                    diag("warning", "missing_operator", t.from, "'" .. t.text .. " {' read as '" .. t.text .. " = {'")
                    local b2 = { kind = "block", open = nxt, from = nxt.from }
                    b2.entries = block_entries(b2)
                    entries[#entries + 1] = { kind = "statement", key = key, op = nil, value = b2, from = t.from,
                        to = b2.to, missing_operator = true }
                elseif nxt and nxt.type == OPEN and t.type == WORD then
                    i = i + 1
                    local b2 = { kind = "block", tag = t, open = nxt, from = t.from }
                    b2.entries = block_entries(b2)
                    entries[#entries + 1] = b2
                else
                    entries[#entries + 1] = key
                end
            end
        end
    end

    local ast = { kind = "file", name = options.name, tokens = tokens, trailing = trailing,
        diagnostics = diagnostics, profile = profile, source = text, from = 1, to = #text,
        eof_line = (where(#text + 1)) }
    ast.entries = block_entries(nil)

    -- what this version reads differently from what the text says
    local lexp = profile.lexer
    for _, t in ipairs(tokens) do
        if t.type == OP and (t.text == ">=" or t.text == "<=") and lexp.comparisons == false then
            diag("warning", "two_token_comparison", t.from,
                "'" .. t.text .. "' is two tokens before 2.3: the game reads '" .. sub(t.text, 1, 1) .. "' with the value '='")
        elseif t.type == OP and t.text == "!=" and lexp.bang ~= "token" then
            diag("warning", "bang_comment", t.from, "'!' starts a comment before 3.x: the rest of the line is not read")
        elseif t.type == MATH and profile.math == false then
            diag("warning", "no_inline_math", t.from, "inline math is read from 2.3 on: this version reads '@[' as a word")
        elseif t.type == WORD and #t.text > 256 and lexp.long_token == "overflow" then
            diag("error", "long_token", t.from, "a token longer than 256 bytes overruns the game's buffer in 1.0.x")
        end
    end
    if lexp.uncertain then
        diag("info", "uncertain_version", 1, "the lexer of version " .. tostring(options.version) ..
            " was not measured: the profile is that of the version before it")
    end

    -- the game's reading: its messages and bugs (pdxreader)
    if pdxreader and options.semantic ~= false then
        local ok, read = pcall(pdxreader.read, text, profile, { name = options.name, lookup = options.lookup })
        if ok then
            ast.reading = read
            for _, bug in ipairs(read.bugs) do
                diagnostics[#diagnostics + 1] = { severity = "warning", code = bug.kind, line = bug.line, col = 1,
                    message = bug.message }
            end
            for _, msg in ipairs(read.log) do
                diagnostics[#diagnostics + 1] = { severity = "warning", code = "game_message", line = nil, col = nil,
                    message = msg }
            end
        end
    end
    table.sort(diagnostics, function(a, b)
        return (a.line or math.huge) < (b.line or math.huge) or
            ((a.line or math.huge) == (b.line or math.huge) and (a.col or 0) < (b.col or 0))
    end)
    return ast
end

-- pdxast.print(ast) -> text: the tokens with their trivia, in order (the text, if nothing was
-- changed; a token's text can be changed, and its lead)
function pdxast.print(ast)
    local out = {}
    -- (a BOM is the start of the first token's lead, or of the trailing trivia)
    for _, t in ipairs(ast.tokens) do
        out[#out + 1] = t.lead
        out[#out + 1] = t.text
    end
    out[#out + 1] = ast.trailing or ""
    return table.concat(out)
end

-- pdxast.walk(node, fn): fn(node, parent) for node and every node in it, in source order
function pdxast.walk(node, fn, parent)
    fn(node, parent)
    if node.kind == "statement" then
        if node.key then pdxast.walk(node.key, fn, node) end
        if node.value then pdxast.walk(node.value, fn, node) end
    elseif node.entries then
        for _, e in ipairs(node.entries) do
            pdxast.walk(e, fn, node)
        end
    end
end

-- pdxast.tree(ast) -> tree: the tree pdxscript.parse gives (statements, tokens, blocks,
-- conditions), for code written for it. PUNCT tokens, which pdxscript reads as parts of words,
-- and error nodes are left out.
function pdxast.tree(ast)
    local function tok(t, as_value)
        local text = t.text
        if t.type == STRING then
            local quoted = { text = sub(text, 2, sub(text, -1) == "\"" and #text > 1 and -2 or -1), quoted = true, line = t.line }
            return quoted
        end
        return { text = text, line = t.line }
    end
    local function block(b, out)
        out.line = b.open and b.open.line or 1
        if b.tag then
            out.type = b.tag.text
        end
        if b.close then
            out.last = b.close.line
        elseif b.open then
            -- a block the file ends inside: its last line is the end of the file
            out.last = ast.eof_line
        end
        for _, e in ipairs(b.entries) do
            if e.kind == "statement" then
                local value
                if e.value and e.value.kind == "block" then
                    value = block(e.value, {})
                elseif e.value then
                    value = tok(e.value.token)
                end
                out[#out + 1] = { key = tok(e.key.token), op = e.op and e.op.text or "=", value = value, line = e.key.token.line }
            elseif e.kind == "value" then
                if e.type ~= "punct" then
                    out[#out + 1] = tok(e.token)
                end
            elseif e.kind == "block" then
                out[#out + 1] = block(e, {})
            elseif e.kind == "condition" then
                local c = { param = e.name, negated = e.negated, line = e.open.line,
                    last = e.close and e.close.line or ast.eof_line }
                for _, x in ipairs(block({ entries = e.entries }, {})) do
                    c[#c + 1] = x
                end
                out[#out + 1] = c
            end
        end
        return out
    end
    local tree = block({ entries = ast.entries }, {})
    tree.line, tree.name = 1, ast.name
    return tree
end

return pdxast
