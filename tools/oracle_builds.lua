-- tools/oracle_builds.lua : the lists of builds tools/oracle_runall.sh runs: the executables of the
-- game in the archive that the oracle can run, one per line: executable TAB name [TAB transfer
-- chain].
--
--   luajit tools/oracle_builds.lua <kind> [archive]
--
-- kinds:
--   linux      the Linux builds with symbols (.symtab), stellaris_backups_steam/by_version/281994
--   pdb        the Windows builds with a PDB next to the executable, GOG and Steam
--   labels     the Windows builds without a PDB that stellar-fnmatch labelled (PDXORACLE_LABELS,
--              PDXORACLE_CORPUS: oracle/labels.lua)
--   transfer   the 32-bit Windows builds with neither, each with the chain PDXORACLE_TRANSFER takes
--              (oracle/image.lua): the nearest 32-bit build with a PDB, then one build of each
--              version between it and this one, nearest to the PDB build first
--   windows    pdb, labels and transfer
--   none       the Windows builds the oracle cannot run (64-bit, without a PDB or labels)
-- archive: the directory of stellaris_backups_steam and stellaris_backups_gog (PDXORACLE_ARCHIVE,
-- else /zpool0/share).
--
-- Names: v<version>_<build directory> for Linux (spaces as _, without parentheses);
-- v<version>_W_gog, and v<version>_W_steam_<manifest> (the by_manifest directory the build's links
-- to, else the build directory) for Windows.

local kind = arg[1]
local archive = arg[2] or os.getenv("PDXORACLE_ARCHIVE") or "/zpool0/share"
local KINDS = { linux = true, pdb = true, labels = true, transfer = true, windows = true, none = true }
if not KINDS[kind] then
    io.stderr:write("usage: luajit tools/oracle_builds.lua linux|pdb|labels|transfer|windows|none [archive]\n")
    os.exit(2)
end
local steam = archive .. "/stellaris_backups_steam/by_version"
local gog = archive .. "/stellaris_backups_gog"

local function lines(command)
    local p = io.popen(command)
    local t = {}
    for l in p:lines() do t[#t + 1] = l end
    p:close()
    return t
end

-- a listing in byte order, whatever the locale's
local function sorted(t)
    table.sort(t)
    return t
end

local function exists(path)
    local f = io.open(path, "rb")
    if f then f:close() end
    return f ~= nil
end

local function version_key(v)
    local key = {}
    for n in v:gmatch("%d+") do key[#key + 1] = tonumber(n) end
    return key
end

local function version_less(a, b)
    local x, y = version_key(a), version_key(b)
    for i = 1, math.max(#x, #y) do
        if (x[i] or -1) ~= (y[i] or -1) then return (x[i] or -1) < (y[i] or -1) end
    end
    return false
end

-- the version as a number, to measure how far apart two are
local function version_number(v)
    local k = version_key(v)
    return (k[1] or 0) * 1e6 + (k[2] or 0) * 1e3 + (k[3] or 0)
end

local function sanitize(dir)
    return (dir:gsub(" +", "_"):gsub("[()]", ""))
end

local out = {}
local function emit(exe, name, chain)
    out[#out + 1] = exe .. "\t" .. name .. (chain and ("\t" .. chain) or "")
end

if kind == "linux" then
    for _, dir in ipairs(sorted(lines('ls "' .. steam .. '/281994"'))) do
        local exe = steam .. "/281994/" .. dir .. "/stellaris"
        if exists(exe) then
            local symtab = lines('readelf -S "' .. exe .. '" 2>/dev/null | grep -c "\\.symtab"')[1]
            if tonumber(symtab) and tonumber(symtab) > 0 then
                emit(exe, sanitize(dir))
            end
        end
    end
    for _, l in ipairs(out) do print(l) end
    return
end

-- the Windows builds: { exe, name, version, bits, pdb, id }
local corpus = {}
local corpus_path = os.getenv("PDXORACLE_CORPUS")
if corpus_path then
    local f = io.open(corpus_path, "rb")
    if f then
        local text = f:read("*a")
        f:close()
        for obj in text:gmatch("{[^{}]*}") do
            local id = obj:match('"id"%s*:%s*"([^"]*)"')
            local exe = obj:match('"exe_path"%s*:%s*"([^"]*)"')
            if id and exe then corpus[exe] = id end
        end
    end
end
local labels_dir = os.getenv("PDXORACLE_LABELS")

local function bits_of(exe)
    local f = io.open(exe, "rb")
    if not f then return nil end
    local head = f:read(4096) or ""
    f:close()
    if head:sub(1, 2) ~= "MZ" or #head < 0x40 then return nil end
    local e = head:byte(0x3d) + head:byte(0x3e) * 256 + head:byte(0x3f) * 65536
    if #head < e + 6 then return nil end
    local machine = head:byte(e + 5) + head:byte(e + 6) * 256
    return machine == 0x8664 and 64 or machine == 0x14c and 32 or nil
end

local builds = {}
local function add(exe, version, name, real)
    local bits = bits_of(exe)
    if not bits then return end
    local id = corpus[exe] or (real and corpus[real])
    builds[#builds + 1] = { exe = exe, version = version, name = name, bits = bits, id = id,
        pdb = exists((exe:gsub("%.[eE][xX][eE]$", "")) .. ".pdb"),
        labels = id and labels_dir and exists(labels_dir .. "/" .. id .. ".csv") }
end
for _, dir in ipairs(sorted(lines('ls "' .. gog .. '"'))) do
    local exe = gog .. "/" .. dir .. "/windows/depots/stellaris.exe"
    if exists(exe) then
        add(exe, dir:match("^[%d%.]+"), "v" .. dir .. "_W_gog")
    end
end
-- a Steam build directory is a link to by_manifest/281992/<manifest>, the path the corpus has
local steam_dirs = sorted(lines('cd "' .. steam .. '/281992" && for d in *; do printf "%s\\t%s\\n" "$d" "$(readlink -f "$d")"; done'))
for _, l in ipairs(steam_dirs) do
    local dir, real = l:match("^(.-)\t(.*)$")
    local exe = steam .. "/281992/" .. dir .. "/stellaris.exe"
    if exists(exe) then
        local version = dir:match("^v([%d%.]+)")
        local manifest = real:match("/by_manifest/%d+/(%d+)$")
        add(exe, version, manifest and ("v" .. version .. "_W_steam_" .. manifest) or (sanitize(dir) .. "_W"),
            real .. "/stellaris.exe")
    end
end

-- a version as major.minor.patch: a fourth number (GOG's 2.1.4.4, Steam's build 1.2.1.23501) names
-- a build of that version
local function short(v)
    local k = version_key(v)
    return string.format("%d.%d.%d", k[1] or 0, k[2] or 0, k[3] or 0)
end

-- the chain of a 32-bit build with neither a PDB nor labels
local function chain_of(b)
    local best
    for _, r in ipairs(builds) do
        if r.bits == 32 and r.pdb then
            local d = math.abs(version_number(r.version) - version_number(b.version))
            if not best or d < best.d then
                best = { r = r, d = d }
            end
        end
    end
    if not best then return nil end
    local ref = best.r
    local bv, rv = short(b.version), short(ref.version)
    local down = version_less(bv, rv)
    -- one build of each version strictly between the two (the first of the version by name)
    local between, seen = {}, {}
    for _, c in ipairs(builds) do
        local cv = short(c.version)
        if c.bits == 32 and not c.pdb and not c.labels and not seen[cv] and cv ~= bv and cv ~= rv
            and version_less(cv, rv) == down and version_less(bv, cv) == down then
            seen[cv] = true
            between[#between + 1] = c
        end
    end
    table.sort(between, function(x, y)
        if down then return version_less(y.version, x.version) end
        return version_less(x.version, y.version)
    end)
    local chain = { ref.exe }
    for _, c in ipairs(between) do chain[#chain + 1] = c.exe end
    return table.concat(chain, ";")
end

for _, b in ipairs(builds) do
    local source = b.pdb and "pdb" or b.labels and "labels" or b.bits == 32 and "transfer" or "none"
    if kind == source or (kind == "windows" and source ~= "none") then
        emit(b.exe, b.name, source == "transfer" and chain_of(b) or nil)
    end
end
for _, l in ipairs(out) do print(l) end
