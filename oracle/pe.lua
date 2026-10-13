-- oracle/pe.lua : a Windows executable (PE32 for i386, PE32+ for x86-64) as the oracle needs it,
-- with the interface of oracle/elf.lua's image: the sections to map, the symbols, what it imports.
-- Its symbols come from its program database (stellaris.pdb next to it, the public symbols: MSVC
-- decorated names) or, for a build without one, from labels (oracle/labels.lua).
--
--   local pe = require("oracle.pe")
--   local image = pe.load("/path/to/stellaris.exe")       -- the .pdb next to it, if there is one
--   image.bits, image.abi ("win64" | "win32"), image.base (ImageBase), image.segments
--   image:symbol("?GetTok@CTextLexer@@MEAAHXZ")            -- its RVA, or nil
--   image.imports[i] = { dll = "KERNEL32.dll", name = "HeapAlloc" | nil, ordinal = n | nil, iat = rva }
--   image.tls = { start, stop, index, callbacks, zero_fill } (virtual addresses), image.pdata
--
-- Addresses of symbols are RVAs: the machine maps the image at image.base (its preferred base),
-- so that nothing needs to be relocated.

local ffi = require("ffi")
local bit = require("bit")
local msvc = require("oracle.msvc")

local pe = {}

local STT_OBJECT, STT_FUNC = 1, 2

local Image = {}
Image.__index = Image

-- pe.is_pe(data) -> true for an MZ file with a PE header
function pe.is_pe(data)
    if #data < 0x40 or data:sub(1, 2) ~= "MZ" then
        return false
    end
    local a, b, c, d = data:byte(0x3d, 0x40)
    local o = a + b * 256 + c * 65536 + d * 16777216
    return #data > o + 4 and data:sub(o + 1, o + 4) == "PE\0\0"
end

-- pe.load(path [, options]) -> image. options: pdb (a path; default: the .pdb next to the
-- executable with the same name), labels (a labels CSV, see oracle/labels.lua), no_symbols
function pe.load(path, options)
    local f = assert(io.open(path, "rb"))
    local data = f:read("*a")
    f:close()
    return pe.parse(data, path, options)
end

function pe.parse(data, path, options)
    options = options or {}
    assert(pe.is_pe(data), (path or "?") .. ": not a PE file")
    local p = ffi.cast("const uint8_t *", data)
    local function u16(o) return ffi.cast("const uint16_t *", p + o)[0] end
    local function u32(o) return ffi.cast("const uint32_t *", p + o)[0] end
    local function u64(o) return tonumber(ffi.cast("const uint64_t *", p + o)[0]) end
    local function cstr(o)
        local e = o
        while p[e] ~= 0 do e = e + 1 end
        return ffi.string(p + o, e - o)
    end

    local nt = u32(0x3c)
    local machine = u16(nt + 4)
    local nsections = u16(nt + 6)
    local opt_size = u16(nt + 20)
    local opt = nt + 24
    local magic = u16(opt)
    local bits = magic == 0x20b and 64 or 32
    assert(machine == (bits == 64 and 0x8664 or 0x14c), (path or "?") .. ": not an x86 PE")
    local image = setmetatable({ path = path, data = data, bits = bits, format = "pe",
        abi = bits == 64 and "win64" or "win32", segments = {}, sections = {}, symbols = {},
        imports = {}, relocs = {}, exports = {}, conventions = {} }, Image)
    image.machine = machine
    local dirs, ndirs
    if bits == 64 then
        image.entry = u32(opt + 16)
        image.base = u64(opt + 24)
        ndirs, dirs = u32(opt + 108), opt + 112
    else
        image.entry = u32(opt + 16)
        image.base = u32(opt + 28)
        ndirs, dirs = u32(opt + 92), opt + 96
    end
    image.size = u32(opt + 56)
    image.headers_size = u32(opt + 60)
    local function dir(i)
        if i >= ndirs then return 0, 0 end
        return u32(dirs + 8 * i), u32(dirs + 8 * i + 4)
    end

    -- the sections, mapped at their RVAs; the headers too (the first page)
    image.segments[1] = { vaddr = 0, memsz = image.headers_size, offset = 0, filesz = image.headers_size }
    local secs = {}
    local sh = opt + opt_size
    for i = 0, nsections - 1 do
        local o = sh + 40 * i
        local name = ffi.string(p + o, 8):gsub("%z.*$", "")
        local s = { name = name, vsize = u32(o + 8), addr = u32(o + 12), rawsize = u32(o + 16),
            offset = u32(o + 20), flags = u32(o + 36) }
        s.size = math.max(s.vsize, 0)
        secs[i + 1] = s
        image.sections[name] = image.sections[name] or s
        image.segments[#image.segments + 1] = { vaddr = s.addr, memsz = math.max(s.vsize, s.rawsize),
            offset = s.offset, filesz = math.min(s.rawsize, math.max(s.vsize, s.rawsize)), name = name,
            exec = bit.band(s.flags, 0x20000000) ~= 0 }
    end
    image.section_list = secs
    local function offset_of(rva)
        for _, s in ipairs(secs) do
            if rva >= s.addr and rva < s.addr + math.max(s.vsize, s.rawsize) then
                local o = rva - s.addr
                if o < s.rawsize then
                    return s.offset + o
                end
                return nil
            end
        end
        if rva < image.headers_size then return rva end
        return nil
    end
    image.offset_of = offset_of

    -- imports: the import directory, a descriptor per DLL, a thunk per function (a name or an
    -- ordinal); the IAT slot is filled by the machine
    local irva = dir(1)
    if irva ~= 0 then
        local o = offset_of(irva)
        while true do
            local ilt, name_rva, iat = u32(o), u32(o + 12), u32(o + 16)
            if name_rva == 0 and iat == 0 then break end
            local dll = cstr(offset_of(name_rva))
            local t = offset_of(ilt ~= 0 and ilt or iat)
            local slot = iat
            local w = bits / 8
            while true do
                local v = bits == 64 and ffi.cast("const uint64_t *", p + t)[0] or u32(t)
                if v == 0 then break end
                local imp = { dll = dll, iat = slot }
                local high = bits == 64 and (v >= 0x8000000000000000ULL) or (v >= 0x80000000)
                if high then
                    imp.ordinal = tonumber(bits == 64 and v % 65536ULL or v % 65536)
                else
                    imp.name = cstr(offset_of(tonumber(v) % 2 ^ 31) + 2)
                end
                image.imports[#image.imports + 1] = imp
                t = t + w
                slot = slot + w
            end
            o = o + 20
        end
    end

    -- exports (none in the game, kept for completeness): symbols too
    local erva = dir(0)
    if erva ~= 0 and offset_of(erva) then
        local o = offset_of(erva)
        local nnames, funcs, names, ords = u32(o + 24), u32(o + 28), u32(o + 32), u32(o + 36)
        local fo, no, oo = offset_of(funcs), offset_of(names), offset_of(ords)
        if fo and no and oo then
            for i = 0, nnames - 1 do
                local name = cstr(offset_of(u32(no + 4 * i)))
                local rva = u32(fo + 4 * u16(oo + 2 * i))
                image.exports[name] = rva
            end
        end
    end

    -- the TLS directory (virtual addresses)
    local trva = dir(9)
    if trva ~= 0 then
        local o = offset_of(trva)
        if bits == 64 then
            image.tls = { start = u64(o), stop = u64(o + 8), index = u64(o + 16), callbacks = u64(o + 24),
                zero_fill = u32(o + 32) }
        else
            image.tls = { start = u32(o), stop = u32(o + 4), index = u32(o + 8), callbacks = u32(o + 12),
                zero_fill = u32(o + 16) }
        end
    end

    -- the exception directory (x86-64): every function's extent, for sizes
    local prva, psize = dir(3)
    if prva ~= 0 and bits == 64 then
        local o = offset_of(prva)
        local n = math.floor(psize / 12)
        local begins = ffi.new("uint32_t[?]", n)
        local ends = ffi.new("uint32_t[?]", n)
        local chained = ffi.new("uint8_t[?]", n)
        for i = 0, n - 1 do
            begins[i] = u32(o + 12 * i)
            ends[i] = u32(o + 12 * i + 4)
            -- a part of a function (UNW_FLAG_CHAININFO in its unwind information) is not a function
            local uo = offset_of(u32(o + 12 * i + 8))
            if uo and bit.band(bit.rshift(p[uo], 3), 4) ~= 0 then
                chained[i] = 1
            end
        end
        image.pdata = { n = n, begins = begins, ends = ends, chained = chained }
    end

    -- the CodeView record of the debug directory: the PDB's GUID and age
    local drva, dsize = dir(6)
    if drva ~= 0 then
        local o = offset_of(drva)
        for i = 0, math.floor(dsize / 28) - 1 do
            local e = o + 28 * i
            if u32(e + 12) == 2 then
                local ro = u32(e + 24)
                if ffi.string(p + ro, 4) == "RSDS" then
                    image.pdb_guid = ffi.string(p + ro + 4, 16)
                    image.pdb_age = u32(ro + 20)
                    image.pdb_name = cstr(ro + 24)
                end
            end
        end
    end

    if not options.no_symbols then
        image:load_symbols(options)
    end
    return image
end

-- the extent of the function that starts at rva (x86-64: from .pdata), or nil
function Image:function_size(rva)
    local pd = self.pdata
    if not pd then return nil end
    local lo, hi = 0, pd.n - 1
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local b = pd.begins[mid]
        if b == rva then
            return pd.ends[mid] - b
        elseif b < rva then
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return nil
end

-- the index of the function that starts at rva in the order of .pdata, and the function at an index
function Image:function_index(rva)
    local pd = self.pdata
    if not pd then return nil end
    local lo, hi = 0, pd.n - 1
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local b = pd.begins[mid]
        if b == rva then
            return mid
        elseif b < rva then
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return nil
end

function Image:function_at_index(i)
    local pd = self.pdata
    if not pd or i < 0 or i >= pd.n or pd.chained[i] ~= 0 then return nil end
    return pd.begins[i], pd.ends[i] - pd.begins[i]
end

function Image:add_symbol(name, rva, func, size)
    local s = self.symbols[name]
    if s then return s end
    s = { name = name, value = rva, size = size or (func and self:function_size(rva)) or 0,
        type = func and STT_FUNC or STT_OBJECT, defined = true }
    self.symbols[name] = s
    return s
end

-- the symbols: the PDB's publics (segment:offset -> RVA through the section headers), else labels
function Image:load_symbols(options)
    options = options or {}
    local pdb_path = options.pdb
    if not pdb_path and self.path then
        local candidate = self.path:gsub("%.[eE][xX][eE]$", "") .. ".pdb"
        local f = io.open(candidate, "rb")
        if f then
            f:close()
            pdb_path = candidate
        end
    end
    local publics
    if pdb_path then
        local ok, list = pcall(require("oracle.pdb").publics, pdb_path)
        if ok then
            publics = list
        else
            self.pdb_error = tostring(list)
        end
    end
    if publics then
        local secs = self.section_list
        for _, s in ipairs(publics) do
            local sec = secs[s.segment]
            if sec then
                self:add_symbol(s.name, sec.addr + s.offset, s.func)
            end
        end
        self.symbol_source = "pdb"
        self.pdb_path = pdb_path
    elseif options.labels then
        require("oracle.labels").apply(self, options.labels, options)
        self.symbol_source = "labels"
    end
    for name, rva in pairs(self.exports) do
        self:add_symbol(name, rva, true)
    end
end

-- image:symbol(name) -> RVA or nil
function Image:symbol(name)
    local s = self.symbols[name]
    if s then
        return s.value
    end
    if self.resolve then
        return self:resolve(name)
    end
    return nil
end

-- image:convention(rva) -> the MSVC signature of the function there ({ convention, pops, ... }),
-- from its decorated name, or nil
function Image:convention(rva)
    local c = self.conventions[rva]
    if c == nil then
        c = false
        local name = self:name_at(rva)
        if name and not name:find("+0x", 1, true) then
            c = msvc.signature(name, self.bits) or false
        end
        self.conventions[rva] = c
    end
    return c or nil
end

function Image:find(pattern)
    local out = {}
    for name, s in pairs(self.symbols) do
        if name:find(pattern) then
            out[#out + 1] = s
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- image:name_at(rva) -> "name+0xoff" of the function containing it, or nil; where several names
-- share an address (identical functions folded by the linker), the function's own (a C++ name
-- before a C one, then the shortest)
function Image:name_at(address)
    if not self.by_address then
        local at = {}
        local function better(s, prev)
            if (s.type == STT_FUNC) ~= (prev.type == STT_FUNC) then
                return s.type == STT_FUNC
            end
            local sc, pc = s.name:sub(1, 1) == "?", prev.name:sub(1, 1) == "?"
            if sc ~= pc then
                return sc
            end
            if #s.name ~= #prev.name then
                return #s.name < #prev.name
            end
            return s.name < prev.name
        end
        for _, s in pairs(self.symbols) do
            if s.value ~= 0 then
                local prev = at[s.value]
                if not prev or better(s, prev) then
                    at[s.value] = s
                end
            end
        end
        local list = {}
        for _, s in pairs(at) do
            list[#list + 1] = s
        end
        table.sort(list, function(a, b) return a.value < b.value end)
        self.by_address = list
    end
    local list = self.by_address
    local lo, hi = 1, #list
    if hi == 0 or address < list[1].value then
        return nil
    end
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if list[mid].value <= address then
            lo = mid
        else
            hi = mid - 1
        end
    end
    local s = list[lo]
    local off = address - s.value
    if s.size > 0 and off >= s.size + 16 then
        return nil
    end
    if s.size == 0 and off >= 0x10000 then
        return nil
    end
    return off == 0 and s.name or string.format("%s+0x%x", s.name, off)
end

function Image:object_at(address)
    if not self.by_extent then
        local list = {}
        for _, s in pairs(self.symbols) do
            if s.size > 0 and s.value ~= 0 then
                list[#list + 1] = s
            end
        end
        table.sort(list, function(a, b) return a.value < b.value end)
        self.by_extent = list
    end
    local list = self.by_extent
    local lo, hi = 1, #list
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local s = list[mid]
        if address < s.value then
            hi = mid - 1
        elseif address >= s.value + s.size then
            lo = mid + 1
        else
            return s, address - s.value
        end
    end
    return nil
end

-- image:read_rva(rva, n) -> the bytes of the file at an RVA (from the file, before any change)
function Image:read_rva(rva, n)
    local o = self.offset_of(rva)
    if not o then return nil end
    return self.data:sub(o + 1, o + n)
end

return pe
