-- pdxreader.lua : the game's statement reader (CReader::ReadSimpleStatement in CPersistent::Read)
-- of every Stellaris version, in plain Lua on pdxlexer: what the game reads from script text as
-- statements, keys, operators and values, with its scripted variables (@x = 5, @x) and inline
-- math (@[ ... ], through pdxmath when it is there), and the messages it logs.
--
--   local pdxreader = require("pdxreader")
--   local profile = pdxreader.profile("3.8.4")
--   local tree = pdxreader.read(text, profile [, options])
--   tree[i] = { key = tok, op = tok | nil, value = tok | nil, next = tok | nil, block = { ... } | nil }
--   tok = { id = n | nil, text = "...", quoted = true | nil }   (id nil: a word the static lexer
--          decides, see pdxlexer; with options.lookup the static lexer's ids)
--   tree.variables = { "@x", ... }   tree.log = { "message", ... }   tree.inline_scripts = n
--   tree.bugs = { { kind, line, message } }: where the game does what it was not meant to (below)
--
-- It reads every block as statements, as an object's members are read (a member that is a list
-- reads its block with other readers, which this is not about). A statement whose value is `{`
-- (or that has no operator and is followed by `{`) holds the statements of that block.
--
-- This is a literal model of the game's code: it reproduces what the game does, also where that
-- is not what the script meant, so that it can be checked against the game itself
-- (tools/oracle_check_reader.lua compares it with what every build's own reader did:
-- oracle/README.md). The places where the game does what nobody meant are reported in
-- tree.bugs, so that tooling can warn about them:
--   variable_value_eats   (2.x on) a variable defined from another variable or inline math
--                         (`@a = @b`, `@a = @[ 1 + 2 ]`) makes the reader skip the token after it
--   math_at_end           (2.x on) inline math as the last value of a file: the game reads past
--                         the end of the file for a ']' (it hangs); here the read stops
--   stale_key             a statement read where only a variable definition or the end of the file
--                         was: the game hands its object the previous statement's key again

local pdxlexer = require("pdxlexer")
local ok_math, pdxmath = pcall(require, "pdxmath")
if not ok_math then
    pdxmath = nil
end

local pdxreader = {}

local byte, sub, lower = string.byte, string.sub, string.lower

-- The profiles: how each version's reader reads, from the first version measured to read so.
--   operators   the token ids ReadSimpleStatement takes for an operator after a key: = < > in
--               1.x; from 2.x CToken::MatchComparisons (< > <= >= and, from 3.x, !=)
--   variables   "v1": RegisterVariable (1.x: any name; a name taken is logged and the definition
--               is left to be read as statements; a definition without '=' reads no further; a
--               value starting with '@' is first read as a definition of that name, then resolved);
--               "list": RegisterVariableInList (2.x on: names of letters, digits and '_' that
--               start with a letter; a name taken is logged and its '=' and value are skipped;
--               a definition without '=' skips one more token; a value starting with '@' is
--               resolved and the token after it is skipped)
--   located     the reader's messages end in " file: <name> line: <n>" (2.x on)
--   math        inline math is read (2.x on): see pdxmath
--   inline_script  `inline_script = ...` is read from the game's files (3.x on: here counted, and
--               read as nothing, or by options.inline_script)
--   close_value "number": a '}' where a value should be is CToken(4), a NUMBER "4" (1.x); "close":
--               a '}' token
pdxreader.PROFILES = {
    { version = "1.0.0", operators = { [1] = true, [467] = true, [468] = true }, variables = "v1",
        located = false, math = false, inline_script = false, close_value = "number" },
    { version = "2.3.0", operators = { [1] = true, [467] = true, [468] = true, [971] = true,
        [972] = true }, variables = "list", located = true, math = true, inline_script = false },
    { version = "3.12.5", operators = { [1] = true, [467] = true, [468] = true, [971] = true,
        [972] = true, [1063] = true }, variables = "list", located = true, math = true,
        inline_script = true },
}

-- pdxreader.profile(version) -> profile: the reader's profile and the lexer's (profile.lexer)
-- and the math's (profile.math_profile) of that version; uncertain as in pdxlexer
function pdxreader.profile(version)
    local chosen = pdxreader.PROFILES[1]
    for _, p in ipairs(pdxreader.PROFILES) do
        if not version or pdxlexer.compare_versions(p.version, version) <= 0 then
            chosen = p
        end
    end
    local profile = {}
    for k, v in pairs(chosen) do
        profile[k] = v
    end
    profile.for_version = version
    profile.lexer = pdxlexer.profile(version)
    profile.uncertain = profile.lexer.uncertain
    if pdxmath and profile.math then
        profile.math_profile = pdxmath.profile(version)
    end
    return profile
end

local Reader = {}
Reader.__index = Reader

local function token_of(lex)
    local t = { id = lex.type, text = lex.text }
    if lex.quoted then
        t.quoted = true
    end
    return t
end

local function starts_with_at(t)
    return t and byte(t.text, 1) == 64
end

function Reader:log(message)
    if self.profile.located then
        message = message .. "  file: " .. (self.name or "") .. " line: " .. self.lex.line
    end
    self.messages[#self.messages + 1] = message
end

function Reader:bug(kind, message)
    self.bugs[#self.bugs + 1] = { kind = kind, line = self.lex.line, message = message }
end

-- the value of a variable: the reader's own (this text's), then options.globals
function Reader:variable(name)
    local v = self.locals[name]
    if v then
        return v
    end
    local g = self.globals and self.globals[name]
    if g then
        return type(g) == "table" and g or { id = nil, text = tostring(g) }
    end
end

-- CReader::ParseAdvancedStatementWithVariables: the value of a token starting with '@', which the
-- lexer has just read: a variable's value, or inline math (2.x on) evaluated
function Reader:advanced(t)
    local text = t.text
    local math_open = sub(text, 1, 2) == "@[" or sub(text, 1, 3) == "@\\["
    if math_open and self.profile.math then
        local expr = text
        if sub(text, -1) ~= "]" then
            -- the rest of the math, raw, to its ']' (CTextLexer::ReadUntilCharacter)
            local rest = self.lex:read_until("]")
            if rest == nil then
                self:bug("math_at_end", "inline math is not closed before the end of the file: the game reads past it")
                self.stop = true
                return { id = 12, text = "0" }
            end
            expr = expr .. rest .. "]"
        end
        local inner = expr:match("^@\\?%[(.*)%]$") or ""
        if pdxmath and self.profile.math_profile then
            local result, _, messages = pdxmath.evaluate(inner, self.profile.math_profile, function(name)
                local v = self:variable(name)
                return v and v.text
            end)
            for _, msg in ipairs(messages or {}) do
                self:log(msg)
            end
            if result then
                return { id = 13, text = result }
            end
            return { id = 12, text = "0" }
        end
        return { id = 13, text = "@[" .. inner .. "]", unevaluated = true }
    end
    local v = self:variable(sub(text, 2))
    if v then
        return { id = v.id, text = v.text, quoted = v.quoted }
    end
    return t
end

local function valid_name(name)
    if not name:find("^[A-Za-z]") then
        return false
    end
    return name:find("^[A-Za-z][A-Za-z0-9_]*$") ~= nil
end

-- a variable definition, the lexer at its name (`@x`)
function Reader:register()
    local lex = self.lex
    local name = sub(lex.text, 2)
    self.variables[#self.variables + 1] = lex.text
    if self.profile.variables == "v1" then
        -- 1.x: CReader::RegisterVariable
        if self.locals[name] then
            self:log("Variable name " .. name .. " is already taken. ")
            return
        end
        if lex:next() == 0 or lex.type ~= 1 then
            return
        end
        if lex:next() == 0 then
            return
        end
        local value = token_of(lex)
        if starts_with_at(value) then
            -- RegisterVariable again, on the value (`@y = @x`: x is "already taken"; `@y = @z`
            -- reads on for z's '='), then the value resolved
            self:register()
            value = self:advanced(value)
        end
        self.locals[name] = value
        return
    end
    -- 2.x on: CReader::RegisterVariableInList
    if not valid_name(name) then
        self:log("Invalid variable name [" .. name .. "]. Variable names must start with a letter and only contain letters, numbers, or under scores.")
        return
    end
    if self.locals[name] then
        self:log("Variable name " .. name .. " is already taken.")
        lex:next()
        lex:next()
        return
    end
    if lex:next() == 0 or lex.type ~= 1 then
        lex:next()
        return
    end
    lex:peek()
    local peeked = token_of(lex)
    lex:next()
    local value
    if starts_with_at(peeked) then
        value = self:advanced(token_of(lex))
        self:bug("variable_value_eats", "@" .. name .. " is defined from an @ value: the game skips the token after it")
        lex:next()
    else
        value = token_of(lex)
    end
    self.locals[name] = value
end

-- CReader::ReadSimpleStatement: the next statement (the caller has peeked: it is not '}' and not
-- the end); returns the statement, or nil when there was nothing more to read
function Reader:simple()
    local lex = self.lex
    local stmt = {}
    if lex:next() == 0 then
        return nil
    end
    while byte(lex.text, 1) == 64 do
        self:register()
        if self.stop then
            return nil
        end
        if lex:next() == 0 then
            -- the statement is the previous one's key, again
            -- the statement is the previous one's key again (or, if there was none, the reader's
            -- first, empty token): the game hands it to the object once more
            self:bug("stale_key", "a variable definition at the end: the game reads the previous key again")
            stmt.key = self.key or { id = 0, text = "" }
            stmt.next = token_of(lex)
            return stmt
        end
    end
    self.key = token_of(lex)
    stmt.key = self.key
    if lex:next() == 0 then
        stmt.next = token_of(lex)
        return stmt
    end
    if self.profile.operators[lex.type] and not lex.quoted then
        stmt.op = token_of(lex)
        local id = lex:peek()
        if id == 4 and not lex.quoted then
            -- '}': the value is a '}' token (1.x: CToken(4), a NUMBER "4"), and the '}' is left
            -- for the block
            if self.profile.close_value == "number" then
                stmt.value = { id = 12, text = "4" }
            else
                stmt.value = { id = 4, text = "}" }
            end
        else
            lex:next()
            local value = token_of(lex)
            if starts_with_at(value) then
                value = self:advanced(value)
            end
            stmt.value = value
        end
    else
        stmt.next = token_of(lex)
    end
    return stmt
end

-- CPersistent::Read: the statements to a '}' or the end, read into block
function Reader:block(block)
    local lex = self.lex
    while not self.stop do
        local id = lex:peek()
        if id == 19 or (id == 4 and not lex.quoted) then
            break
        end
        local stmt = self:simple()
        if not stmt or self.stop then
            break
        end
        local key = stmt.key
        if self.profile.inline_script and key and not key.quoted and lower(key.text) == "inline_script" and stmt.op then
            self.inline_scripts = self.inline_scripts + 1
            if self.inline_script then
                self.inline_script(stmt, self)
            end
        else
            block[#block + 1] = stmt
            local open = (stmt.value and stmt.value.id == 3 and not stmt.value.quoted) or
                (not stmt.op and stmt.next and stmt.next.id == 3 and not stmt.next.quoted)
            if open then
                stmt.block = {}
                self:block(stmt.block)
            end
        end
    end
    if self.stop then
        return
    end
    -- the '}' (or the end); a token left starting with '@' is read as more math (2.x on): the
    -- math_at_end bug
    lex:next()
    if self.profile.math and (sub(lex.text, 1, 2) == "@[" or sub(lex.text, 1, 3) == "@\\[") and sub(lex.text, -1) ~= "]" then
        self:bug("math_at_end", "inline math is the last value of the file: the game reads past its end for a ']'")
        self.stop = true
    end
end

-- pdxreader.read(text [, profile [, options]]) -> tree. options: name (for messages), lookup (the
-- static lexer, see pdxlexer), globals (name -> value text or token: scripted variables of other
-- files), inline_script (function(statement, reader)).
function pdxreader.read(text, profile, options)
    profile = profile or pdxreader.profile()
    options = options or {}
    local lex = pdxlexer.new(text, profile.lexer, options.lookup)
    local r = setmetatable({ lex = lex, profile = profile, name = options.name, globals = options.globals,
        inline_script = options.inline_script, locals = {}, variables = {}, messages = {}, bugs = {},
        inline_scripts = 0 }, Reader)
    local tree = {}
    r:block(tree)
    tree.variables, tree.log, tree.bugs, tree.inline_scripts = r.variables, r.messages, r.bugs, r.inline_scripts
    return tree
end

return pdxreader
