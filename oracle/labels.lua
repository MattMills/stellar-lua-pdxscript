-- oracle/labels.lua : symbols for a Windows build without a PDB, from the labels of stellar-fnmatch
-- (a CSV per build: rva, end, size, score, second, round, evidence, label; a label is a qualified
-- name without parameters, "A | B" when the linker folded identical functions into one).
--
--   local labels = require("oracle.labels")
--   local csv, reference = labels.find(exe_path)      -- from PDXORACLE_LABELS and PDXORACLE_CORPUS
--   labels.apply(image, csv, { reference = reference })
--   image:symbol("?GetTok@CTextLexer@@MEAAHXZ")        -- resolved through its label
--
-- The oracle asks for functions by their MSVC decorated names. A decorated name is reduced to its
-- qualified name (oracle/msvc.lua); when one function has that label, that is it. When several do
-- (overloads: CToken has six constructors), the reference decides: a build of a nearby version
-- with a PDB, where the decorated name is known. Among the functions of that qualified name, sorted
-- by address, it is the k-th; if the build has as many, its k-th is taken, else the one whose size
-- is closest to the reference's. A vtable (??_7) is found from the reference's too: the functions
-- of its slots, resolved here, are looked for in the read-only data, and the place most of them
-- agree on is its first slot.

local msvc = require("oracle.msvc")

local labels = {}

local function version_key(v)
    local key = {}
    for n in tostring(v or ""):gmatch("%d+") do
        key[#key + 1] = tonumber(n)
    end
    return key
end

-- a number that orders versions: major, minor, patch
local function version_number(v)
    local k = version_key(v)
    return (k[1] or 0) * 1e6 + (k[2] or 0) * 1e3 + (k[3] or 0)
end

local function realpath(path)
    local p = io.popen('readlink -f "' .. path:gsub('"', '\\"') .. '" 2>/dev/null')
    if not p then return path end
    local r = p:read("*l")
    p:close()
    return r ~= "" and r or path
end

-- the builds of a corpus.json: { id, version, exe, pdb, platform }
local function read_corpus(path)
    local f = io.open(path, "rb")
    if not f then return {} end
    local text = f:read("*a")
    f:close()
    local builds = {}
    for obj in text:gmatch("{[^{}]*}") do
        local id = obj:match('"id"%s*:%s*"([^"]*)"')
        local exe = obj:match('"exe_path"%s*:%s*"([^"]*)"')
        if id and exe then
            builds[#builds + 1] = { id = id, exe = exe, version = obj:match('"version"%s*:%s*"([^"]*)"'),
                source = obj:match('"source"%s*:%s*"([^"]*)"'), pdb = obj:match('"pdb_path"%s*:%s*"([^"]*)"') }
        end
    end
    return builds
end

-- labels.find(exe) -> the labels CSV of the executable and the executable of the nearest build with
-- a PDB (by version), or nil. PDXORACLE_LABELS: a CSV file, or the directory of <build id>.csv;
-- PDXORACLE_CORPUS: the corpus.json that gives each build id's executable and version;
-- PDXORACLE_REFERENCE: a reference executable (with its PDB) to use instead.
function labels.find(exe)
    local where = os.getenv("PDXORACLE_LABELS")
    if not where then
        return nil
    end
    local reference = os.getenv("PDXORACLE_REFERENCE")
    if where:match("%.csv$") then
        return where, reference
    end
    local corpus = os.getenv("PDXORACLE_CORPUS")
    if not corpus then
        return nil
    end
    local builds = read_corpus(corpus)
    local real = realpath(exe)
    local me
    for _, b in ipairs(builds) do
        if b.exe == exe or b.exe == real then
            me = b
            break
        end
    end
    if not me then
        return nil
    end
    local csv = where .. "/" .. me.id .. ".csv"
    local f = io.open(csv, "rb")
    if not f then
        return nil
    end
    f:close()
    if reference then
        return csv, { reference }
    end
    -- the builds with a PDB, nearest first: by how many versions of the corpus are between
    -- (2.8.1 is next to 3.0.1, though 2.3.3 is nearer in number), then later first
    local v = (me.version and me.version ~= "?" and me.version) or exe:match("/v(%d+%.%d+%.%d+)") or me.source
    local versions, seen = {}, {}
    for _, b in ipairs(builds) do
        if b.version and b.version ~= "?" and not seen[b.version] then
            seen[b.version] = true
            versions[#versions + 1] = b.version
        end
    end
    if not seen[v] then versions[#versions + 1] = v end
    table.sort(versions, function(a, b) return version_number(a) < version_number(b) end)
    local position = {}
    for i, x in ipairs(versions) do position[x] = i end
    local refs = {}
    for _, b in ipairs(builds) do
        if b.pdb and b.version and b.version ~= "?" then
            refs[#refs + 1] = { exe = b.exe, d = math.abs(position[b.version] - position[v]),
                later = version_number(b.version) >= version_number(v), version = b.version }
        end
    end
    table.sort(refs, function(a, b)
        if a.d ~= b.d then return a.d < b.d end
        if a.later ~= b.later then return a.later end
        return a.exe < b.exe
    end)
    -- one build per version, the four nearest versions (so both sides of a gap)
    reference = {}
    local taken = {}
    for _, r in ipairs(refs) do
        if not taken[r.version] and #reference < 4 then
            taken[r.version] = true
            reference[#reference + 1] = r.exe
        end
    end
    return csv, reference
end

-- the rows of a labels CSV: { rva, size, names = { ... } } (unwind funclets and the like left out)
local function read_csv(path)
    local rows = {}
    local f = assert(io.open(path, "rb"))
    local header = true
    for line in f:lines() do
        if header then
            header = false
        else
            local rva, size, label = line:match("^(0x%x+),[^,]*,(%d+),[^,]*,[^,]*,[^,]*,[^,]*,(.*)$")
            if rva then
                if label:sub(1, 1) == '"' then
                    label = label:sub(2, -2):gsub('""', '"')
                end
                local names = {}
                for name in (label .. " | "):gmatch("(.-) | ") do
                    if name ~= "" and not name:find(" %[") and not name:find("%$fin%$") and not name:find("%$filt%$") then
                        names[#names + 1] = name
                    end
                end
                if #names > 0 then
                    rows[#rows + 1] = { rva = tonumber(rva), size = tonumber(size), names = names }
                end
            end
        end
    end
    f:close()
    return rows
end

-- the functions of a PDB build with a given qualified name: { rva, size, name } sorted by address
local function reference_functions(ref, q)
    ref.by_qualified = ref.by_qualified or {}
    local list = ref.by_qualified[q]
    if list then return list end
    list = {}
    local last = q:match("([^:]+)$")
    local scope = q:match("^(.*)::[^:]+$")
    local inner = scope and scope:match("([^:]+)$") or last
    local seen = {}
    for name, s in pairs(ref.symbols) do
        if s.type == 2 and name:find(inner, 1, true) and msvc.qualified(name) == q and not seen[s.value] then
            seen[s.value] = true
            list[#list + 1] = { rva = s.value, size = s.size, name = name }
        end
    end
    table.sort(list, function(a, b) return a.rva < b.rva end)
    ref.by_qualified[q] = list
    return list
end

-- labels.apply(image, csv [, options]): the labels as the image's symbols, and its resolver of
-- decorated names. options.reference: the executable of a build with a PDB (or its image)
function labels.apply(image, csv, options)
    options = options or {}
    local rows = read_csv(csv)
    local by_name = {}
    for _, r in ipairs(rows) do
        for _, n in ipairs(r.names) do
            local list = by_name[n]
            if not list then
                list = {}
                by_name[n] = list
            end
            list[#list + 1] = r
            -- (overloads: the second and later functions of a name are "name#2" ...)
            image:add_symbol(#list == 1 and n or (n .. "#" .. #list), r.rva, true, r.size)
        end
    end
    for _, list in pairs(by_name) do
        table.sort(list, function(a, b) return a.rva < b.rva end)
    end
    image.label_rows, image.labels_by_name, image.labels_path = rows, by_name, csv
    -- the references, nearest first, each loaded when first needed; a name is resolved with the
    -- first that resolves it
    local references = options.reference
    if type(references) ~= "table" or references.symbols then
        references = { references }
    end
    image.references = references
    image.resolutions = {}
    image.resolve = function(self, name)
        local r = self.resolutions[name]
        if r == nil then
            r = false
            for i = 1, #references do
                local function ref()
                    if type(references[i]) == "string" then
                        local ok, loaded = pcall(require("oracle.pe").load, references[i])
                        references[i] = ok and loaded or false
                    end
                    return references[i] or nil
                end
                local ok, v = pcall(labels.resolve, self, name, ref)
                if not ok then
                    self.resolve_errors = self.resolve_errors or {}
                    self.resolve_errors[name] = v
                elseif v then
                    r = v
                    self.resolved_with = self.resolved_with or {}
                    self.resolved_with[name] = references[i] and references[i].path
                    break
                end
            end
            self.resolutions[name] = r
        end
        return r or nil
    end
    return image
end

-- labels.resolve(image, decorated, ref) -> RVA or nil
function labels.resolve(image, name, ref)
    local by_name = image.labels_by_name
    if name:sub(1, 4) == "??_7" then
        return labels.resolve_vtable(image, name, ref)
    end
    local q = msvc.qualified(name)
    if not q then
        -- a C name: its label is itself
        local list = by_name[name]
        return list and #list == 1 and list[1].rva or nil
    end
    local sig = msvc.signature(name, image.bits)
    if sig and sig.kind ~= "function" then
        return nil
    end
    local cands = by_name[q]
    if not cands then
        return nil
    end
    -- one function of that name is that function, unless the reference has several (then it may
    -- be another overload, the one asked for having no label)
    local reference = ref()
    local rrva = reference and reference:symbol(name)
    if not rrva then
        return #cands == 1 and cands[1].rva or nil
    end
    local rlist = reference_functions(reference, q)
    if #cands == 1 and #rlist <= 1 then
        return cands[1].rva
    end
    local rank, rsize
    for i, f in ipairs(rlist) do
        if f.rva == rrva then
            rank, rsize = i, f.size
        end
    end
    if not rank then
        return nil
    end
    -- several candidates, or a candidate that may be another overload. The overloads of a name are
    -- the labelled functions, and the functions without a label next to them (within three) that
    -- call what one of them or the reference's function calls (an overload with no label). If there
    -- are as many as in the reference, the one of the same rank (by address) is taken; else the one
    -- most like the reference's: what it calls, its size
    local want = labels.calls(reference, rrva, rsize, true)
    local function similarity(a, b)
        local common, total, seen = 0, 0, {}
        for name, n in pairs(a) do
            common = common + math.min(n, b[name] or 0)
            total = total + math.max(n, b[name] or 0)
            seen[name] = true
        end
        for name, n in pairs(b) do
            if not seen[name] then total = total + n end
        end
        return total > 0 and common / total or 1
    end
    local taken = {}
    for _, c in ipairs(cands) do taken[c.rva] = true end
    local pool = {}
    for _, c in ipairs(cands) do
        local calls = labels.calls(image, c.rva, c.size, false)
        pool[#pool + 1] = { rva = c.rva, size = c.size, calls = calls, labelled = true }
    end
    for _, c in ipairs(cands) do
        local ci = image:function_index(c.rva)
        for d = -3, 3 do
            local rva, size = image:function_at_index((ci or -100) + d)
            local n = rva and image:name_at(rva)
            if rva and not taken[rva] and (not n or n:find("+0x", 1, true)) then
                taken[rva] = true
                local calls = labels.calls(image, rva, size, false)
                local like = similarity(calls, want) >= 0.5
                for _, l in ipairs(cands) do
                    if similarity(calls, labels.calls(image, l.rva, l.size, false)) == 1 then like = true end
                end
                if like and next(calls) then
                    pool[#pool + 1] = { rva = rva, size = size, calls = calls }
                end
            end
        end
    end
    table.sort(pool, function(x, y) return x.rva < y.rva end)
    if #pool == #rlist then
        return pool[rank].rva
    end
    local best, best_score
    for _, c in ipairs(pool) do
        local size = 1 - math.min(1, math.abs(c.size - rsize) / math.max(rsize, 1))
        local score = 2 * similarity(c.calls, want) + size + (c.labelled and 0.2 or 0)
        if not best_score or score > best_score then
            best, best_score = c, score
        end
    end
    return best and best.rva or nil
end

-- labels.calls(image, rva, size, decorated) -> { name = count }: the functions a function calls
-- (call and jmp rel32 to the start of a function), by qualified name (decorated: the image's
-- names are MSVC decorated names, else labels)
function labels.calls(image, rva, size, decorated)
    image.calls_cache = image.calls_cache or {}
    local cached = image.calls_cache[rva]
    if cached then return cached end
    local out = {}
    local code = image:read_rva(rva, size or 0) or ""
    for i = 1, #code - 4 do
        local op = code:byte(i)
        if op == 0xe8 or op == 0xe9 then
            local v = code:byte(i + 1) + code:byte(i + 2) * 256 + code:byte(i + 3) * 65536 + code:byte(i + 4) * 16777216
            if v >= 2 ^ 31 then v = v - 2 ^ 32 end
            local target = rva + i - 1 + 5 + v
            if image:function_index(target) then
                local name = image:name_at(target)
                if name and not name:find("+0x", 1, true) then
                    if decorated then
                        name = msvc.qualified(name) or name
                    else
                        name = name:gsub("#%d+$", "")
                    end
                    name = name:gsub("%b<>", "<>")
                    out[name] = (out[name] or 0) + 1
                end
            end
        end
    end
    image.calls_cache[rva] = out
    return out
end

local function word_at(image, rva)
    local w = image.bits / 8
    local s = image:read_rva(rva, w)
    if not s or #s < w then return nil end
    local v = 0
    for k = w, 1, -1 do
        v = v * 256 + s:byte(k)
    end
    return v
end

-- a vtable: the reference's slots resolved here and looked for in the read-only data
function labels.resolve_vtable(image, name, ref)
    local reference = ref()
    if not reference then return nil end
    local start = reference:symbol(name)
    if not start then return nil end
    local w = image.bits / 8
    -- the reference's vtable: to the next vtable symbol, at most 64 slots of code pointers
    local next_start
    for vname, s in pairs(reference.symbols) do
        if vname:sub(1, 4) == "??_7" and s.value > start and (not next_start or s.value < next_start) then
            next_start = s.value
        end
    end
    local text = reference.sections[".text"]
    local itext = image.sections[".text"]
    local votes = {}
    local rdata = {}
    for _, sec in ipairs(image.section_list) do
        if sec.name == ".rdata" then
            rdata[#rdata + 1] = { sec = sec, data = image.data:sub(sec.offset + 1, sec.offset + sec.rawsize) }
        end
    end
    local function pack(v)
        local t = {}
        for k = 1, w do
            t[k] = string.char(v % 256)
            v = math.floor(v / 256)
        end
        return table.concat(t)
    end
    for i = 0, 63 do
        local at = start + i * w
        if next_start and at >= next_start then break end
        local fn = word_at(reference, at)
        if not fn or fn < reference.base + text.addr or fn >= reference.base + text.addr + text.size then
            break
        end
        local fname = reference:name_at(fn - reference.base)
        if fname and not fname:find("+0x", 1, true) and fname:sub(1, 1) == "?" then
            local t = image:symbol(fname)
            if t and t ~= 0 then
                local needle = pack(image.base + t)
                for _, r in ipairs(rdata) do
                    local from = 1
                    while true do
                        local k = r.data:find(needle, from, true)
                        if not k then break end
                        from = k + 1
                        if (k - 1) % w == 0 then
                            local s0 = r.sec.addr + (k - 1) - i * w
                            votes[s0] = (votes[s0] or 0) + 1
                        end
                    end
                end
            end
        end
    end
    local best, best_n
    for s0, n in pairs(votes) do
        if not best_n or n > best_n then
            best, best_n = s0, n
        end
    end
    return best
end

return labels
