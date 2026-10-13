-- pdxlexer.lua : the game's script tokenizer (CTextLexer::GetTok) of every Stellaris version, in
-- plain Lua (5.1 to 5.4, LuaJIT): the tokens the game reads for any text, with the same ids, text,
-- quoted flag and line counter, and the same state of the file behind them.
--
--   local pdxlexer = require("pdxlexer")
--   local profile = pdxlexer.profile("2.8.1")        -- how that version's lexer reads
--   for _, c in ipairs(pdxlexer.tokenize(text, profile, lookup)) do ... end
--   c = { rc = 1, type = 15, text = "a", quoted = false, size = 2, line = 1, pos = 2, last = 32,
--         ungot = false, at = 1 }
--   local lex = pdxlexer.new(text, profile, lookup)  -- one call at a time: lex:next(), lex:peek()
--
-- lookup(word) -> id or nil is the static lexer (CStaticLexer), asked with the word in lower case:
-- the game's keywords. Without it a word the static lexer decides has type nil, key (the word in
-- lower case) and fallback (the id it gets when the static lexer has no token of that name).
--
-- Every rule here was measured: each version's own GetTok was run on the cases of
-- oracle/cases.lua in an emulator (oracle/README.md) and this lexer gives the same calls, field
-- for field (tools/oracle_check_lexer.lua). The profiles say where the versions differ.

local byte, char, sub, find, lower = string.byte, string.char, string.sub, string.find, string.lower

local pdxlexer = {}

-- token ids (_CurrTok._LexerToken): bytes and operators have fixed ids in every version; a word
-- gets the static lexer's id for its name, or NUMBER or STRING
pdxlexer.EQUALS = 1        -- =
pdxlexer.QUOTE = 2         -- only while a quoted string is read; it ends as STRING
pdxlexer.OPEN = 3          -- {
pdxlexer.CLOSE = 4         -- }
pdxlexer.LPAREN = 5        -- (
pdxlexer.RPAREN = 6        -- )
pdxlexer.COMMA = 8         -- ,
pdxlexer.COMMENT = 9       -- # or ; (and ! before 3.x) to the end of the line: skipped
pdxlexer.NUMBER = 12       -- a word of digits, '.' and '-', or any word starting with a digit or '-'
pdxlexer.STRING = 15       -- a quoted string, or a word the static lexer does not know
pdxlexer.EOF = 19          -- what the readers set when GetTok returns 0
pdxlexer.GREATER = 467     -- >
pdxlexer.LESS = 468        -- <
pdxlexer.GREATER_EQ = 971  -- >= (from 2.x)
pdxlexer.LESS_EQ = 972     -- <= (from 2.x)
pdxlexer.NOT = 1062        -- ! (from 3.x; also the id of the word NOT)
pdxlexer.NOT_EQ = 1063     -- != (from 3.x)

-- The profiles: how each version's lexer reads, from the first version measured to read so.
--   comparisons  `>=` and `<=` are one token, and after `<` or `>` the next byte is read (and put
--                back unless it is `=`); before, `<` and `>` are tokens of one byte, alone
--   bang         "comment": `!` starts a comment like `#`; "token": `!` is NOT, `!=` is NOT_EQ
--   nul          "ends": a NUL byte ends a token's text (the text is a C string) and an empty
--                word is a token of id 0; "kept": the text keeps NUL bytes, an empty word is a
--                NUMBER
--   read_math    the readers read the rest of an inline math token (`@[ ... ]`) with
--                ReadUntilCharacter (lex:read_until), which the lexer has
--   long_token   "overflow": a token longer than 256 bytes overruns the token's buffer (1.0.x, a
--                bug: not imitated, but lex.long_tokens counts them)
--   keywords     words whose id is that of punctuation (3.x: NOT is `!`, 1062), known without a
--                lookup
pdxlexer.PROFILES = {
    { version = "1.0.0", comparisons = false, bang = "comment", nul = "ends", read_math = false,
        long_token = "overflow" },
    { version = "1.1.0", comparisons = false, bang = "comment", nul = "ends", read_math = false },
    { version = "2.3.0", comparisons = true, bang = "comment", nul = "kept", read_math = true },
    { version = "3.12.5", comparisons = true, bang = "token", nul = "kept", read_math = true,
        keywords = { ["not"] = 1062 } },
}

-- the versions whose lexers were measured; between two ranges the profile is the earlier one's,
-- marked uncertain (the change is somewhere in the gap)
pdxlexer.MEASURED = {
    { "1.0.0", "1.2.5" }, { "2.3.0", "2.5.0" }, { "3.12.5", "4.5.2" },
}

local function version_parts(v)
    local t = {}
    for n in tostring(v):gmatch("%d+") do
        t[#t + 1] = tonumber(n)
    end
    return t
end

-- pdxlexer.compare_versions(a, b) -> -1, 0, 1 (by numbers: "3.12.5" > "3.9.1")
function pdxlexer.compare_versions(a, b)
    local x, y = version_parts(a), version_parts(b)
    for i = 1, math.max(#x, #y) do
        local p, q = x[i] or 0, y[i] or 0
        if p ~= q then
            return p < q and -1 or 1
        end
    end
    return 0
end
local cmpv = pdxlexer.compare_versions

-- pdxlexer.profile(version) -> profile: the lexer of that version (the latest profile at or
-- before it); uncertain = true when the version was not measured and a profile changes in the
-- gap it is in. pdxlexer.profile() is the latest.
function pdxlexer.profile(version)
    local chosen = pdxlexer.PROFILES[#pdxlexer.PROFILES]
    if version then
        chosen = pdxlexer.PROFILES[1]
        for _, p in ipairs(pdxlexer.PROFILES) do
            if cmpv(p.version, version) <= 0 then
                chosen = p
            end
        end
    end
    local profile = {}
    for k, v in pairs(chosen) do
        profile[k] = v
    end
    profile.for_version = version
    if version then
        local inside = false
        for _, r in ipairs(pdxlexer.MEASURED) do
            if cmpv(r[1], version) <= 0 and cmpv(version, r[2]) <= 0 then
                inside = true
            end
        end
        if not inside then
            -- uncertain only if a profile starts between the last measured version before it and
            -- the first one after it
            local before, after
            for _, r in ipairs(pdxlexer.MEASURED) do
                if cmpv(r[2], version) < 0 then before = r[2] end
                if not after and cmpv(r[1], version) > 0 then after = r[1] end
            end
            for _, p in ipairs(pdxlexer.PROFILES) do
                if (not before or cmpv(p.version, before) > 0) and (not after or cmpv(p.version, after) <= 0) then
                    profile.uncertain = true
                end
            end
        end
    end
    return profile
end

-- the tables a profile reads with: the id of each byte that is a token of its own (it also ends a
-- word), blanks, and the bytes that end a word
local SPACE = {}
for b = 0, 255 do
    SPACE[b] = false
end
-- iswspace of the byte as a signed char: HT, LF, VT, FF, CR and space (a byte >= 0x80 is negative
-- and in no class)
for _, b in ipairs({ 9, 10, 11, 12, 13, 32 }) do
    SPACE[b] = true
end

local tables = setmetatable({}, { __mode = "k" })
local function tables_of(profile)
    local t = tables[profile]
    if t then
        return t
    end
    t = { single = {}, stop = {}, with_equals = {} }
    for b = 0, 255 do
        t.single[b] = false
    end
    local single = { [34] = 2, [35] = 9, [40] = 5, [41] = 6, [44] = 8, [59] = 9, [60] = 468,
        [61] = 1, [62] = 467, [123] = 3, [125] = 4 }
    single[33] = profile.bang == "token" and 1062 or 9
    for b, id in pairs(single) do
        t.single[b] = id
    end
    for b = 0, 255 do
        t.stop[b] = SPACE[b] or t.single[b] ~= false
    end
    if profile.comparisons then
        t.with_equals[467], t.with_equals[468] = 971, 972
    end
    if profile.bang == "token" then
        t.with_equals[1062] = 1063
    end
    tables[profile] = t
    return t
end

local Lexer = {}
Lexer.__index = Lexer

-- pdxlexer.new(text, profile [, lookup]) -> lex: a CTextLexer over a CMemoryFile holding text (a
-- BOM included: only name lists have it removed), as the game makes them: line 1, nothing read.
--   lex.type, lex.text, lex.quoted, lex.size  the token: its id, text, quoted flag, and the size
--                                             of its buffer (the text and a NUL; 2 for "")
--   lex.line, lex.last, lex.ungot, lex.pos    the file: the line counter, the last byte read
--                                             (0..255), the put-back flag, the read position
--   lex.at                                    where the token starts in text (its first byte)
--   lex.key, lex.fallback                     a word the static lexer was asked about: its key
--                                             and the id it gets if the static lexer has none
--   lex.end_word                              the last next() returned 0 after a word, which the
--                                             token holds (the readers never see it)
--   lex.warnings                              the line of each backslash the game warns about
--   lex.long_tokens                           tokens longer than 256 bytes (profile long_token)
function pdxlexer.new(text, profile, lookup)
    profile = profile or pdxlexer.profile()
    return setmetatable({ src = text, length = #text, profile = profile, lookup = lookup,
        t = tables_of(profile), type = 0, text = "", quoted = false, size = 1, at = 0,
        line = 1, last = 0, ungot = false, pos = 0, peeked = false, peek_rc = 0,
        end_word = false, warnings = {}, long_tokens = 0 }, Lexer)
end

-- CMemoryFile::Get: the line counts the line feed read before; a byte put back is given again;
-- otherwise the next byte, or 255 past the end (where the position still advances)
function Lexer:get()
    if self.last == 10 then
        self.line = self.line + 1
    end
    if self.ungot then
        self.ungot = false
        return self.last
    end
    local c = 255
    if self.pos < self.length then
        c = byte(self.src, self.pos + 1)
    end
    self.last = c
    self.pos = self.pos + 1
    return c
end

-- CFile::UnGet: the next Get gives the last byte again; a line feed put back lowers the line until
-- it is read again
function Lexer:unget()
    self.ungot = true
    if self.last == 10 then
        self.line = self.line - 1
    end
end

-- the bytes of the file the token covers, as its text: with profile nul "ends", up to a NUL
local function token_text(self, s)
    if self.profile.nul == "ends" then
        local z = find(s, "\0", 1, true)
        if z then
            s = sub(s, 1, z - 1)
        end
    end
    if #s > 256 then
        self.long_tokens = self.long_tokens + 1
    end
    return s
end

-- GetTok without the peek and the static lexer: 1 (a token) or 0 (the end of the file), and
-- whether it read a word (its id is decided after)
local function gettok(self)
    local t = self.t
    while true do
        -- blanks
        local c = self:get()
        if self.pos <= self.length then
            while SPACE[c] do
                c = self:get()
                if self.pos > self.length then
                    break
                end
            end
        end
        if self.pos > self.length and c == 255 then
            return 0, false
        end
        local at = self.pos
        local id = t.single[c]
        self.at, self.quoted = at, false
        if not id then
            -- a word: to a blank (read) or a byte that is a token of its own (put back), or the
            -- end of the file
            c = self:get()
            if self.pos <= self.length then
                while not t.stop[c] do
                    c = self:get()
                    if self.pos > self.length then
                        break
                    end
                end
            end
            if t.single[c] then
                self:unget()
            end
            local raw = sub(self.src, at, self.pos - 1)
            self.text = token_text(self, raw)
            self.size = #raw + 1
            if c == 255 and self.pos > self.length then
                return 0, true  -- the token holds the word, but GetTok says the file ended
            end
            return 1, true
        elseif id == 9 then
            -- a comment: to a line feed (read), then the next token
            self.type, self.text, self.size = 9, char(c), 2
            c = self:get()
            if self.pos <= self.length then
                while c ~= 10 do
                    c = self:get()
                    if self.pos > self.length then
                        break
                    end
                end
            end
        elseif id == 2 then
            -- a quoted string: to the next quote with no backslash before it; \" and \\ lose
            -- their backslash, any other backslash stays (and the game warns)
            -- (the byte just read is at self.pos in text; the pieces between the cut backslashes
            -- are joined)
            local parts, from, prev = {}, at + 1, 0
            c = self:get()
            if self.pos <= self.length then
                while true do
                    if c == 34 and prev ~= 92 then
                        break
                    end
                    if prev == 92 and (c == 34 or c == 92) then
                        parts[#parts + 1] = sub(self.src, from, self.pos - 2)
                        from = self.pos
                        prev = 0
                    else
                        if prev == 92 then
                            self.warnings[#self.warnings + 1] = self.line
                        end
                        prev = c
                    end
                    c = self:get()
                    if self.pos > self.length then
                        break
                    end
                end
            end
            -- to the closing quote (at self.pos, left out), or to the end of the file
            parts[#parts + 1] = sub(self.src, from, self.pos - 1)
            local text = table.concat(parts)
            self.type, self.quoted = 15, true
            self.text = token_text(self, text)
            self.size = #text + 1 < 2 and 2 or #text + 1
            return 1, false
        else
            local combined = t.with_equals[id]
            if combined then
                if self:get() == 61 then
                    self.type, self.text, self.size = combined, char(c) .. "=", 3
                else
                    self:unget()
                    self.type, self.text, self.size = id, char(c), 2
                end
            else
                self.type, self.text, self.size = id, char(c), 2
            end
            return 1, false
        end
    end
end

-- the id of a word: NUMBER if it starts with a digit or '-', else the static lexer's token
-- (unless that is NUMBER), else NUMBER if it has only digits, '.' and '-', else STRING. The game
-- reads the word as a C string: a NUL ends it for these checks. Returns the id, or nil, the key
-- (the word in lower case) and the fallback.
local function word_class(self, text)
    local word = text
    local z = find(word, "\0", 1, true)
    if z then
        word = sub(word, 1, z - 1)
    end
    local c = byte(word, 1)
    if c == nil and self.profile.nul == "ends" then
        return 0
    end
    if c and (c >= 48 and c <= 57 or c == 45) then
        return 12
    end
    return nil, lower(word), find(word, "^[%d%.%-]*$") and 12 or 15
end

-- lex:next() -> 1 or 0: GetTok. While a peek is pending it only returns its result.
function Lexer:next()
    if self.peeked then
        self.peeked = false
        return self.peek_rc
    end
    local rc, word = gettok(self)
    self.key, self.fallback = nil, nil
    if word then
        local id, key, fallback = word_class(self, self.text)
        if id == nil then
            local found = self.lookup and self.lookup(key)
            if not found and self.profile.keywords then
                found = self.profile.keywords[key]
            end
            id = found and found ~= 12 and found or nil
            self.key, self.fallback = key, fallback
            if id == nil and (self.lookup or fallback == 12) then
                id = fallback
            end
        end
        self.type = id
    end
    self.end_word = rc == 0 and word
    return rc
end

-- lex:peek() -> id: CLexer::Peek: GetTok once, its result kept for the next GetTok; EOF (19) at
-- the end
function Lexer:peek()
    if not self.peeked then
        self.peek_rc = self:next()
        if self.peek_rc == 0 then
            self.type = 19
        end
        self.peeked = true
    end
    return self.type
end

-- lex:read_until(byte or char) -> text: CTextLexer::ReadUntilCharacter (2.x on): the raw bytes up
-- to that byte, which is read and left out; nil and "end of file" when the file ends first (the
-- game reads on past the end)
function Lexer:read_until(stop)
    if type(stop) == "string" then
        stop = byte(stop)
    end
    local c = self:get()
    local from = self.pos
    while c ~= stop do
        if self.pos > self.length and c == 255 then
            return nil, "end of file"
        end
        c = self:get()
    end
    return sub(self.src, from, self.pos - 1)
end

-- whether the readers read the rest of this token's inline math with ReadUntilCharacter: an
-- unquoted token "@[..." that does not end in ']' (profile read_math)
function pdxlexer.reads_math(profile, text, quoted)
    return profile.read_math and not quoted and sub(text, 1, 2) == "@[" and sub(text, -1) ~= "]"
end

-- pdxlexer.tokenize(text [, profile [, lookup [, read_math]]]) -> calls: every GetTok call to the
-- first that returns 0 (included), each { rc, type, quoted, text, size, line, pos, last, ungot,
-- at } and, for a word the static lexer decides without a lookup, key and fallback (type is then
-- the fallback if it is NUMBER, else nil). With read_math, inline math is read after its token as
-- the readers do (math, math_line). calls.warnings: the lines of the backslashes warned about.
function pdxlexer.tokenize(text, profile, lookup, read_math)
    profile = profile or pdxlexer.profile()
    local lex = pdxlexer.new(text, profile, lookup)
    local calls = {}
    repeat
        local rc = lex:next()
        local call = { rc = rc, type = lex.type, quoted = lex.quoted, text = lex.text, size = lex.size,
            line = lex.line, pos = lex.pos, last = lex.last, ungot = lex.ungot, at = lex.at,
            key = lex.key, fallback = lex.fallback }
        calls[#calls + 1] = call
        if rc == 1 and read_math and pdxlexer.reads_math(profile, lex.text, lex.quoted) then
            local math, message = lex:read_until(93)
            if math == nil then
                calls.error = "line " .. lex.line .. ": inline math without ']': " .. message
                break
            end
            call.math, call.math_line = math, lex.line
        end
    until rc == 0
    calls.warnings, calls.long_tokens = lex.warnings, lex.long_tokens
    return calls
end

return pdxlexer
