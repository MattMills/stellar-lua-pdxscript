-- oracle/pdb.lua : the public symbols of a Microsoft program database (a .pdb, MSF 7.00): the
-- decorated names (`?GetTok@CTextLexer@@MEAAHXZ`) of the functions and data of an executable, with
-- their segment and offset. Only the streams that hold them are read (the file can be 400 MB).
--
--   local pdb = require("oracle.pdb")
--   local publics = pdb.publics("/path/to/stellaris.pdb")
--   publics[i] = { name = "?GetTok@CTextLexer@@MEAAHXZ", segment = 1, offset = 0x1bb0220, func = true }
--
-- The container: a superblock (block size, the blocks of the stream directory), the directory
-- (the size of every stream and its blocks). Stream 3 is the DBI stream; its header names the
-- symbol record stream, a sequence of { u16 length, u16 kind, ... } records, of which S_PUB32
-- (0x110e: u32 flags, u32 offset, u16 segment, name) are the publics.

local ffi = require("ffi")
local bit = require("bit")

local pdb = {}

local MAGIC = "Microsoft C/C++ MSF 7.00\r\n\26DS\0\0\0"
local S_PUB32 = 0x110e

local function u32(s, o)
    local a, b, c, d = s:byte(o + 1, o + 4)
    return a + b * 256 + c * 65536 + d * 16777216
end

-- pdb.open(path) -> msf: msf:stream(i) -> string (or nil for an absent stream), msf:close()
function pdb.open(path)
    local f = assert(io.open(path, "rb"))
    local head = f:read(56)
    if not head or #head < 56 or head:sub(1, #MAGIC) ~= MAGIC then
        f:close()
        error(tostring(path) .. ": not a PDB (MSF 7.00) file")
    end
    local block_size = u32(head, 0x20)
    local dir_bytes = u32(head, 0x2c)
    local block_map = u32(head, 0x34)
    local function block(i, n)
        f:seek("set", i * block_size)
        return f:read(n or block_size)
    end
    -- the blocks of the directory are listed in the block map (one block or more, consecutive
    -- entries starting at block_map)
    local dir_blocks = math.ceil(dir_bytes / block_size)
    local map = {}
    local need = dir_blocks * 4
    local mi = block_map
    while #table.concat(map) < need do
        map[#map + 1] = block(mi)
        mi = mi + 1
    end
    local map_s = table.concat(map)
    local parts = {}
    for i = 0, dir_blocks - 1 do
        parts[#parts + 1] = block(u32(map_s, 4 * i))
    end
    local dir = table.concat(parts):sub(1, dir_bytes)
    local nstreams = u32(dir, 0)
    local sizes, blocks = {}, {}
    local o = 4 + 4 * nstreams
    for i = 0, nstreams - 1 do
        local size = u32(dir, 4 + 4 * i)
        if size == 0xffffffff then
            size = nil
        end
        sizes[i] = size
        local list = {}
        for k = 1, size and math.ceil(size / block_size) or 0 do
            list[k] = u32(dir, o)
            o = o + 4
        end
        blocks[i] = list
    end
    local msf = { path = path, block_size = block_size, sizes = sizes, nstreams = nstreams }
    function msf:stream(i)
        local size = sizes[i]
        if not size then
            return nil
        end
        local out = {}
        local list = blocks[i]
        -- runs of consecutive blocks are read at once
        local k = 1
        while k <= #list do
            local first, n = list[k], 1
            while list[k + n] == first + n do
                n = n + 1
            end
            out[#out + 1] = block(first, n * block_size)
            k = k + n
        end
        return table.concat(out):sub(1, size)
    end
    function msf:close()
        f:close()
    end
    return msf
end

-- pdb.publics(path) -> list of { name, segment, offset, func }, and the DBI header's machine
function pdb.publics(path)
    local msf = pdb.open(path)
    local dbi = msf:stream(3)
    if not dbi or #dbi < 64 then
        msf:close()
        error(tostring(path) .. ": no DBI stream")
    end
    local sym_stream = dbi:byte(21) + dbi:byte(22) * 256
    local machine = dbi:byte(59) + dbi:byte(60) * 256
    local records = msf:stream(sym_stream)
    msf:close()
    local p = ffi.cast("const uint8_t *", records)
    local n = #records
    local out = {}
    local o = 0
    while o + 4 <= n do
        local len = p[o] + p[o + 1] * 256
        local kind = p[o + 2] + p[o + 3] * 256
        if len < 2 then
            break
        end
        if kind == S_PUB32 then
            local flags = ffi.cast("const uint32_t *", p + o + 4)[0]
            local offset = ffi.cast("const uint32_t *", p + o + 8)[0]
            local segment = p[o + 12] + p[o + 13] * 256
            local stop = o + 2 + len
            local e = o + 14
            while e < stop and p[e] ~= 0 do
                e = e + 1
            end
            out[#out + 1] = { name = ffi.string(p + o + 14, e - o - 14), segment = segment,
                offset = tonumber(offset), func = bit.band(flags, 2) ~= 0, code = bit.band(flags, 1) ~= 0 }
        end
        o = o + 2 + len
    end
    return out, machine
end

return pdb
