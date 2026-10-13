-- pdxversions.lua : which versions of the game know the keywords a script uses. Every trigger,
-- effect, scope link and member the game reads is a keyword compiled into its static lexer; the
-- oracle read that table from every build measured (data/keywords.tsv, made by
-- tools/oracle_keywordreport.lua). A script that uses a keyword a version does not have cannot be
-- read as meant by that version.
--
--   local pdxversions = require("pdxversions")
--   pdxversions.keyword("every_owned_pop")       -- { "1.0.0", ..., "3.14.1592653" }: the measured
--                                                 -- versions that have it, or nil (not a keyword)
--   local r = pdxversions.requirements(pdxast.parse(text))
--   r.best         -- the measured versions that know the most of the keywords it uses
--   r.coverage     -- per measured version: how many of them it knows
--   r.constraints  -- { { keyword = "every_owned_pop", versions = {...}, line = n }, ... }: the
--                  -- keywords not known to every version, each with where it is first used
--
-- Only built-in keywords count: a scripted trigger or effect, an event, a technology is defined in
-- script and is no keyword. The versions are those measured (data/keywords.tsv's header); a version
-- between two measured ones is unknown: it may have a keyword first measured after it.

local pdxversions = {}

local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."

local loaded
local function load()
    if loaded then
        return loaded
    end
    local path = pdxversions.data_path or (here .. "/data/keywords.tsv")
    local f = assert(io.open(path, "rb"), "pdxversions: no " .. path)
    local versions, index, words = {}, {}, {}
    for line in f:lines() do
        local measured = line:match("^# measured: (.*)$")
        if measured then
            for v in measured:gmatch("%S+") do
                versions[#versions + 1] = v
                index[v] = #versions
            end
        elseif line:sub(1, 1) ~= "#" then
            local word, ranges = line:match("^([^\t]+)\t(.*)$")
            if word then
                words[word] = ranges
            end
        end
    end
    f:close()
    loaded = { versions = versions, index = index, words = words, cache = {} }
    return loaded
end

-- pdxversions.measured() -> the versions measured, in order
function pdxversions.measured()
    return load().versions
end

-- the set (index -> true) of the measured versions a keyword is in
local function present(word)
    local d = load()
    local ranges = d.words[word]
    if not ranges then
        return nil
    end
    local set = d.cache[word]
    if set then
        return set
    end
    set = {}
    for range in ranges:gmatch("[^,]+") do
        local a, b = range:match("^(.-)%.%.(.*)$")
        a, b = a or range, b or range
        for i = d.index[a], d.index[b] do
            set[i] = true
        end
    end
    d.cache[word] = set
    return set
end

-- pdxversions.keyword(word) -> list of the measured versions that have it, or nil
function pdxversions.keyword(word)
    local set = present(word:lower())
    if not set then
        return nil
    end
    local d = load()
    local list = {}
    for i, v in ipairs(d.versions) do
        if set[i] then list[#list + 1] = v end
    end
    return list
end

-- the words a pdxast tree uses as keywords: statement keys, and the links of scope chains (keys
-- and values)
local function used_words(ast, fn)
    local function walk(entries)
        for _, e in ipairs(entries) do
            if e.kind == "statement" then
                local key = e.key
                if key.type == "word" or key.type == "bool" then
                    fn(key.token.text, key.token.line)
                elseif key.type == "scope" then
                    for _, link in ipairs(key.links) do
                        fn(link.prefix or link.name, key.token.line)
                    end
                end
                local v = e.value
                if v and v.kind == "value" and v.type == "scope" then
                    for _, link in ipairs(v.links) do
                        if link.prefix then fn(link.prefix, v.token.line) end
                    end
                end
                if v and v.kind == "block" then
                    walk(v.entries)
                end
            elseif e.kind == "block" or e.kind == "condition" then
                walk(e.entries)
            end
        end
    end
    walk(ast.entries)
end

-- pdxversions.requirements(ast [, r]) -> r: which measured versions know the keywords a script (a
-- pdxast tree) uses; pass the r of other files to add them to it.
--   r.used        the words it uses that are a keyword of at least one measured version
--   r.coverage    { { version, known, share }, ... } per measured version: how many of r.used it
--                 has compiled in
--   r.best        the measured versions that know the most (the likely versions the script is for)
--   r.constraints every used keyword not in every measured version: { keyword, versions, first,
--                 last, file, line }
-- This is evidence, not a bound: a word that is a keyword of some versions can be a name the script
-- defines in others (`shroud`), and from 2.3 the list iterators (`any_*`, `every_*`, ...) are made
-- at startup, not compiled in. The versions that know the most of what a script uses are where it
-- reads best.
function pdxversions.requirements(ast, r)
    local d = load()
    r = r or { constraints = {}, seen = {}, used = 0, known = {} }
    local all = #d.versions
    used_words(ast, function(word, line)
        word = word:lower()
        if r.seen[word] then
            return
        end
        r.seen[word] = true
        local set = present(word)
        if not set then
            return
        end
        r.used = r.used + 1
        local first, last, n = nil, nil, 0
        for i = 1, all do
            if set[i] then
                first = first or i
                last = i
                n = n + 1
                r.known[i] = (r.known[i] or 0) + 1
            end
        end
        if n < all then
            local versions = {}
            for i = 1, all do
                if set[i] then versions[#versions + 1] = d.versions[i] end
            end
            r.constraints[#r.constraints + 1] = { keyword = word, first = first, last = last,
                versions = versions, file = ast.name, line = line }
        end
    end)
    r.coverage, r.best = {}, {}
    local top = 0
    for i, v in ipairs(d.versions) do
        local known = r.known[i] or 0
        r.coverage[i] = { version = v, known = known, share = r.used > 0 and known / r.used or 1 }
        if known > top then top = known end
    end
    for i, v in ipairs(d.versions) do
        if (r.known[i] or 0) == top then r.best[#r.best + 1] = v end
    end
    return r
end

return pdxversions
