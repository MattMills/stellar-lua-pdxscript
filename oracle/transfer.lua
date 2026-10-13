-- oracle/transfer.lua : symbols for a Windows build that has neither a PDB nor labels (the 32-bit
-- Steam builds 1.3 to 2.2), carried over from a build of the same architecture that has a PDB.
--
--   require("oracle.transfer").apply(image, reference_image)
--   image:symbol("?GetTok@CTextLexer@@MAEHXZ")      -- found from the reference's
--
-- Code that did not change between two builds is the same bytes, except the absolute addresses
-- (the base relocations of each image say where they are) and the targets of calls and jumps
-- (rel32 after E8/E9). With those masked, a window of the reference's code is looked for in the
-- other build's code; where it is found once, what it calls or refers to at the same offset is the
-- same function or data there. A function is found from windows around the places that call it
-- and from its own first bytes; data (a vtable, the initializer tables) from windows around the
-- places that refer to it; a virtual function from its slot in its vtable. Each window that is
-- found once is a vote; the address with the most votes is taken.

local ffi = require("ffi")
local msvc = require("oracle.msvc")

local transfer = {}

local BEFORE, AFTER = 24, 24   -- the window around a call or a reference

-- the code of an image: .text, its relocations as a set, and (built when needed) where each
-- function is called from and where each address is referred to
local function code(image)
    if image.transfer_code then return image.transfer_code end
    local sec = image.sections[".text"]
    local data = image.data:sub(sec.offset + 1, sec.offset + math.min(sec.rawsize, sec.vsize))
    local relocs = {}
    for _, r in ipairs(image.base_relocs or {}) do
        if r >= sec.addr and r < sec.addr + #data then relocs[r] = true end
    end
    local c = { addr = sec.addr, data = data, relocs = relocs, w = image.bits / 8 }
    image.transfer_code = c
    return c
end

-- the bytes of [rva, rva + n) and which of them to compare
local function window(image, rva, n)
    local c = code(image)
    local o = rva - c.addr
    if o < 0 or o + n > #c.data then return nil end
    local bytes = c.data:sub(o + 1, o + n)
    local keep = {}
    for i = 1, n do keep[i] = true end
    for i = 1, n do
        if c.relocs[rva + i - 1] then
            for k = 0, c.w - 1 do keep[i + k] = false end
        end
    end
    for i = 1, n - 4 do
        local b = bytes:byte(i)
        if keep[i] and (b == 0xe8 or b == 0xe9) then
            for k = 1, 4 do keep[i + k] = false end
        end
    end
    for i = n + 1, #keep do keep[i] = nil end
    return bytes, keep
end

-- the places of the other image's code where a window is found (at most a few)
local function find(target, bytes, keep)
    local n = #bytes
    local best_s, best_l, s = 1, 0, nil
    for i = 1, n do
        if keep[i] then
            s = s or i
            if i - s + 1 > best_l then best_s, best_l = s, i - s + 1 end
        else
            s = nil
        end
    end
    if best_l < 8 then return {} end
    local key = bytes:sub(best_s, best_s + best_l - 1)
    local c = code(target)
    local hits = {}
    local from = 1
    while #hits <= 4 do
        local k = c.data:find(key, from, true)
        if not k then break end
        from = k + 1
        local start = k - (best_s - 1)
        if start >= 1 and start + n - 1 <= #c.data then
            local rva = c.addr + start - 1
            local tb, tkeep = window(target, rva, n)
            local ok = tb ~= nil
            for i = 1, n do
                if not ok then break end
                if keep[i] ~= tkeep[i] or (keep[i] and tb:byte(i) ~= bytes:byte(i)) then ok = false end
            end
            if ok then hits[#hits + 1] = rva end
        end
    end
    return hits
end

local function word(image, rva)
    local w = image.bits / 8
    local s = image:read_rva(rva, w)
    if not s or #s < w then return nil end
    local v = 0
    for k = w, 1, -1 do v = v * 256 + s:byte(k) end
    return v
end

local function rel32_target(image, rva)
    local s = image:read_rva(rva + 1, 4)
    local v = s:byte(1) + s:byte(2) * 256 + s:byte(3) * 65536 + s:byte(4) * 16777216
    if v >= 2 ^ 31 then v = v - 2 ^ 32 end
    return rva + 5 + v
end

-- the reference's calls (callee RVA -> the RVAs of the E8/E9 that call it) and references (absolute
-- address -> the RVAs of the relocations in the code that hold it)
local function index(ref)
    local c = code(ref)
    if c.calls then return c end
    local calls, refs = {}, {}
    local p = ffi.cast("const uint8_t *", c.data)
    local n = #c.data
    for i = 0, n - 5 do
        local b = p[i]
        if b == 0xe8 or b == 0xe9 then
            local v = p[i + 1] + p[i + 2] * 256 + p[i + 3] * 65536 + p[i + 4] * 16777216
            if v >= 2 ^ 31 then v = v - 2 ^ 32 end
            local t = c.addr + i + 5 + v
            if t >= c.addr and t < c.addr + n then
                local l = calls[t]
                if not l then l = {}; calls[t] = l end
                if #l < 24 then l[#l + 1] = c.addr + i end
            end
        end
    end
    for r in pairs(c.relocs) do
        local v = word(ref, r)
        if v then
            local l = refs[v]
            if not l then l = {}; refs[v] = l end
            if #l < 24 then l[#l + 1] = r end
        end
    end
    c.calls, c.refs = calls, refs
    return c
end

-- the extent of a function of the reference (i386 has no .pdata: to the next public symbol)
local function extent(ref, rva)
    local size = ref:function_size(rva)
    if size then return size end
    if not ref.transfer_starts then
        local starts = {}
        for _, s in pairs(ref.symbols) do
            if s.type == 2 then starts[#starts + 1] = s.value end
        end
        table.sort(starts)
        ref.transfer_starts = starts
    end
    local starts = ref.transfer_starts
    local lo, hi = 1, #starts
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if starts[mid] <= rva then lo = mid + 1 else hi = mid end
    end
    local nxt = starts[lo]
    if nxt and nxt > rva then return math.min(nxt - rva, 4096) end
    return 64
end

local function vote(votes, v, n)
    if v then votes[v] = (votes[v] or 0) + (n or 1) end
end

local function winner(votes)
    local best, best_n, second = nil, 0, 0
    for v, n in pairs(votes) do
        if n > best_n then
            best, second, best_n = v, best_n, n
        elseif n > second then
            second = n
        end
    end
    if best and best_n > second then return best end
    return nil
end

-- data of the reference (an absolute address) in the image: from windows around the code that
-- refers to it
function transfer.data(image, ref, va)
    local c = index(ref)
    local votes = {}
    for _, r in ipairs(c.refs[va] or {}) do
        local bytes, keep = window(ref, r - BEFORE, BEFORE + c.w + AFTER)
        if bytes then
            local hits = find(image, bytes, keep)
            if #hits == 1 then
                vote(votes, word(image, hits[1] + BEFORE))
            end
        end
    end
    local v = winner(votes)
    return v and v - image.base or nil
end

-- a function of the reference (RVA) in the image
function transfer.func(image, ref, rva)
    local c = index(ref)
    local votes = {}
    -- its own first bytes
    local size = extent(ref, rva)
    local bytes, keep = window(ref, rva, math.min(size, 96))
    if bytes and #bytes >= 16 then
        local hits = find(image, bytes, keep)
        if #hits == 1 then vote(votes, hits[1], 3) end
    end
    -- the places that call it
    for _, site in ipairs(c.calls[rva] or {}) do
        local b2, k2 = window(ref, site - BEFORE, BEFORE + 5 + AFTER)
        if b2 then
            local hits = find(image, b2, k2)
            if #hits == 1 then
                vote(votes, rel32_target(image, hits[1] + BEFORE))
            end
        end
    end
    -- the vtables it is in: the same slot of the same vtable here
    for _, r in ipairs(c.refs[ref.base + rva] or {}) do
        local _ = r  -- (references from code: a function pointer stored by code)
    end
    local v = winner(votes)
    if v then return v end
    if ref.vtable_slots == nil then
        -- the vtables of the reference, by the functions in them
        local slots = {}
        local w = ref.bits / 8
        for name, s in pairs(ref.symbols) do
            if name:sub(1, 4) == "??_7" then
                for i = 0, 63 do
                    local f = word(ref, s.value + i * w)
                    if not f then break end
                    local frva = f - ref.base
                    local t = ref.sections[".text"]
                    if frva < t.addr or frva >= t.addr + t.size then break end
                    local l = slots[frva]
                    if not l then l = {}; slots[frva] = l end
                    if #l < 8 then l[#l + 1] = { vtable = s.value, slot = i, name = name } end
                end
            end
        end
        ref.vtable_slots = slots
    end
    for _, e in ipairs(ref.vtable_slots[rva] or {}) do
        local vt = image:symbol(e.name)
        if vt then
            local f = word(image, vt + e.slot * (image.bits / 8))
            if f then vote(votes, f - image.base) end
        end
    end
    return winner(votes)
end

-- transfer.apply(image, references): the image's symbols are the references' names, found as
-- above when they are asked for. references: a build with a PDB, or a list of builds, nearest
-- first, each with a PDB or with symbols carried over itself (a chain); a name is taken from the
-- first that gives it
function transfer.apply(image, references)
    if references.symbols then
        references = { references }
    end
    image.transfer_reference = references[#references]
    image.transfer_references = references
    image.resolutions = {}
    image.resolve = function(self, name)
        local r = self.resolutions[name]
        if r == nil then
            r = false
            for _, reference in ipairs(references) do
                local s = reference:symbol(name) and reference.symbols[name]
                if s then
                    local ok, v
                    if s.type == 2 then
                        ok, v = pcall(transfer.func, self, reference, s.value)
                    else
                        ok, v = pcall(transfer.data, self, reference, reference.base + s.value)
                    end
                    if ok and v then
                        r = v
                        -- named here too, for messages and conventions
                        self:add_symbol(name, v, s.type == 2)
                        self.by_address = nil
                        break
                    elseif not ok then
                        self.resolve_errors = self.resolve_errors or {}
                        self.resolve_errors[name] = v
                    end
                end
            end
            self.resolutions[name] = r
        end
        return r or nil
    end
    return image
end

return transfer
