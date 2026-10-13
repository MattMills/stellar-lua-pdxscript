-- oracle/elf.lua : the parts of an ELF executable (x86 and x86-64) the oracle needs to run its
-- code in an emulator: the loaded segments, the symbols, and the relocations that name the
-- shared libraries' functions.
--
--   local elf = require("oracle.elf")
--   local image = elf.load("/path/to/stellaris")
--   image.bits, image.pie, image.segments, image.relocs
--   image:symbol("_ZN10CTextLexer6GetTokEv")       -- its address (before the load base), or nil
--   image:find("^_ZN10CTextLexerC[12]")            -- every defined symbol whose name matches
--   image:name_at(address)                          -- "CTextLexer::GetTok+0x1c" (mangled), or nil

local ffi = require("ffi")
pcall(ffi.cdef, "size_t strlen(const char *s);")

local elf = {}

local PT_LOAD, PT_TLS = 1, 7
local SHT_SYMTAB, SHT_RELA, SHT_REL, SHT_DYNSYM = 2, 4, 9, 11
local STT_OBJECT, STT_FUNC, STT_TLS, STT_GNU_IFUNC = 1, 2, 6, 10

local Image = {}
Image.__index = Image

-- elf.load(path) -> image (raises on a file that is not an x86 ELF executable)
function elf.load(path)
    local f = assert(io.open(path, "rb"))
    local data = f:read("*a")
    f:close()
    return elf.parse(data, path)
end

function elf.parse(data, path)
    local p = ffi.cast("const uint8_t *", data)
    assert(#data > 64 and data:sub(1, 4) == "\127ELF", (path or "?") .. ": not an ELF file")
    local bits = p[4] == 2 and 64 or 32
    local function u16(o) return ffi.cast("const uint16_t *", p + o)[0] end
    local function u32(o) return ffi.cast("const uint32_t *", p + o)[0] end
    local function u64(o) return tonumber(ffi.cast("const uint64_t *", p + o)[0]) end
    local function i64(o) return tonumber(ffi.cast("const int64_t *", p + o)[0]) end
    local word = bits == 64 and u64 or u32

    local image = setmetatable({ path = path, data = data, bits = bits, segments = {},
        sections = {}, symbols = {}, imports = {}, relocs = {} }, Image)
    image.machine = u16(18)
    image.pie = u16(16) == 3
    local phoff, shoff, phentsize, phnum, shentsize, shnum, shstrndx
    if bits == 64 then
        image.entry = u64(24)
        phoff, shoff = u64(32), u64(40)
        phentsize, phnum, shentsize, shnum, shstrndx = u16(54), u16(56), u16(58), u16(60), u16(62)
    else
        image.entry = u32(24)
        phoff, shoff = u32(28), u32(32)
        phentsize, phnum, shentsize, shnum, shstrndx = u16(42), u16(44), u16(46), u16(48), u16(50)
    end

    for i = 0, phnum - 1 do
        local o = phoff + i * phentsize
        local seg
        if bits == 64 then
            seg = { type = u32(o), flags = u32(o + 4), offset = u64(o + 8), vaddr = u64(o + 16),
                filesz = u64(o + 32), memsz = u64(o + 40), align = u64(o + 48) }
        else
            seg = { type = u32(o), offset = u32(o + 4), vaddr = u32(o + 8), filesz = u32(o + 16),
                memsz = u32(o + 20), flags = u32(o + 24), align = u32(o + 28) }
        end
        if seg.type == PT_LOAD then
            image.segments[#image.segments + 1] = seg
        elseif seg.type == PT_TLS then
            image.tls = seg
        end
    end

    local secs = {}
    for i = 0, shnum - 1 do
        local o = shoff + i * shentsize
        local s
        if bits == 64 then
            s = { name_off = u32(o), type = u32(o + 4), addr = u64(o + 16), offset = u64(o + 24),
                size = u64(o + 32), link = u32(o + 40), info = u32(o + 44), entsize = u64(o + 56) }
        else
            s = { name_off = u32(o), type = u32(o + 4), addr = u32(o + 12), offset = u32(o + 16),
                size = u32(o + 20), link = u32(o + 24), info = u32(o + 28), entsize = u32(o + 36) }
        end
        secs[i] = s
    end
    local function cstr(o)
        return ffi.string(p + o, ffi.C.strlen(ffi.cast("const char *", p + o)))
    end
    if shstrndx ~= 0 and secs[shstrndx] then
        local base = secs[shstrndx].offset
        for i = 0, shnum - 1 do
            secs[i].name = cstr(base + secs[i].name_off)
            image.sections[secs[i].name] = secs[i]
        end
    end

    -- symbol tables: .symtab (the game's own functions, when not stripped) and .dynsym (imports)
    local function read_symbols(s)
        local strtab = secs[s.link].offset
        local entsize = bits == 64 and 24 or 16
        local list = {}
        for i = 0, s.size / entsize - 1 do
            local o = s.offset + i * entsize
            local name_off, info, shndx, value, size
            if bits == 64 then
                name_off, info, shndx, value, size = u32(o), p[o + 4], u16(o + 6), u64(o + 8), u64(o + 16)
            else
                name_off, value, size, info, shndx = u32(o), u32(o + 4), u32(o + 8), p[o + 12], u16(o + 14)
            end
            list[i] = { name = name_off ~= 0 and cstr(strtab + name_off) or "", value = value,
                size = size, type = info % 16, bind = math.floor(info / 16), defined = shndx ~= 0 }
        end
        return list
    end
    local dynsym = {}
    for i = 0, shnum - 1 do
        local s = secs[i]
        if s.type == SHT_SYMTAB or s.type == SHT_DYNSYM then
            local list = read_symbols(s)
            if s.type == SHT_DYNSYM then
                dynsym[i] = list
            end
            for j = 1, #list do
                local sym = list[j]
                if sym.defined and sym.name ~= "" and sym.type ~= STT_TLS then
                    if image.symbols[sym.name] == nil then
                        image.symbols[sym.name] = sym
                    end
                end
            end
            image.has_symtab = image.has_symtab or s.type == SHT_SYMTAB
        end
    end

    -- relocations of the loaded image (.rela.dyn, .rela.plt / .rel.dyn, .rel.plt)
    for i = 0, shnum - 1 do
        local s = secs[i]
        if (s.type == SHT_RELA or s.type == SHT_REL) and dynsym[s.link] then
            local syms = dynsym[s.link]
            local rela = s.type == SHT_RELA
            local entsize = bits == 64 and 24 or (rela and 12 or 8)
            for j = 0, s.size / entsize - 1 do
                local o = s.offset + j * entsize
                local r
                if bits == 64 then
                    local info = ffi.cast("const uint64_t *", p + o + 8)[0]
                    r = { offset = u64(o), type = tonumber(info % 2 ^ 32), sym = tonumber(info / 2 ^ 32),
                        addend = i64(o + 16) }
                else
                    local info = u32(o + 4)
                    r = { offset = u32(o), type = info % 256, sym = math.floor(info / 256),
                        addend = rela and tonumber(ffi.cast("const int32_t *", p + o + 8)[0]) or nil }
                end
                local sym = syms[r.sym]
                if r.sym ~= 0 and sym then
                    r.name, r.defined, r.symtype = sym.name, sym.defined, sym.type
                    r.value = sym.value
                end
                image.relocs[#image.relocs + 1] = r
            end
        end
    end
    return image
end

-- image:symbol(name) -> address or nil
function Image:symbol(name)
    local s = self.symbols[name]
    return s and s.value
end

-- image:find(pattern) -> { {name, value, size}, ... } sorted by name: the defined symbols whose
-- (mangled) name matches the Lua pattern
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

-- image:name_at(address) -> "name+0xoff" for the function containing the address, or nil
function Image:name_at(address)
    if not self.by_address then
        local list = {}
        for _, s in pairs(self.symbols) do
            if (s.type == STT_FUNC or s.type == STT_GNU_IFUNC or s.type == STT_OBJECT) and s.value ~= 0 then
                list[#list + 1] = s
            end
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
    return off == 0 and s.name or string.format("%s+0x%x", s.name, off)
end

-- image:object_at(address) -> symbol, offset: the defined symbol (data object or function) whose
-- bytes [value, value + size) hold the address exactly, or nil (unlike name_at, no guessing past
-- the end of a symbol)
function Image:object_at(address)
    if not self.by_extent then
        local list = {}
        for _, s in pairs(self.symbols) do
            if s.size > 0 and s.value ~= 0 and (s.type == STT_OBJECT or s.type == STT_FUNC) then
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

elf.STT_OBJECT, elf.STT_FUNC = STT_OBJECT, STT_FUNC

return elf
