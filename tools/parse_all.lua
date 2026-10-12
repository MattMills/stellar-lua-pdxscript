-- parse_all.lua : parses every script file of a Stellaris install with pdxscript.lua, and
-- checks that writing each tree back (pdxscript.write) and parsing that gives the same tree.
--
-- Usage: luajit tools/parse_all.lua <game dir> [primary | secondary]
--
-- The primary corpus is the game's script: common/**/*.txt, events/*.txt, map/setup_scenarios,
-- prescripted_countries and flags. The secondary corpus is the interface and graphics
-- definitions in the same syntax: the .gui, .gfx and .asset files under interface/ and gfx/.
-- Both are parsed unless one is named. Prints the counts per directory, every error and every
-- warning, the warnings by kind, and statistics for the interpreter (operators, quoted and bare
-- values, the most common keys). Exits with 0 only if there was no error.
--
-- The files are read first, then parsed (the time printed is that of parse alone, with the
-- garbage collection of the trees it makes), then parsed again for the round trip.

local game_dir, only = arg[1], arg[2]
if game_dir == nil or (only ~= nil and only ~= "primary" and only ~= "secondary") then
    io.stderr:write("usage: luajit parse_all.lua <game dir> [primary | secondary]\n")
    os.exit(2)
end
local here = (arg[0]:match("^(.*)[/\\]") or ".")
package.path = here .. "/../?.lua;" .. package.path

local pdxscript = require("pdxscript")

-- A monotonic clock in seconds with the LuaJIT FFI (os.clock is CPU time).
local util = { now = os.clock }
local has_ffi, ffi = pcall(require, "ffi")
if has_ffi and ffi.os == "Windows" then
    ffi.cdef [[
        int QueryPerformanceCounter(int64_t *count);
        int QueryPerformanceFrequency(int64_t *frequency);
    ]]
    local frequency, count = ffi.new("int64_t[1]"), ffi.new("int64_t[1]")
    ffi.C.QueryPerformanceFrequency(frequency)
    local scale = 1 / tonumber(frequency[0])
    function util.now()
        ffi.C.QueryPerformanceCounter(count)
        return tonumber(count[0]) * scale
    end
elseif has_ffi then
    ffi.cdef [[
        struct pdxscript_timespec { long tv_sec; long tv_nsec; };
        int clock_gettime(int clock, struct pdxscript_timespec *t);
    ]]
    local t = ffi.new("struct pdxscript_timespec")
    function util.now()
        ffi.C.clock_gettime(1, t) -- CLOCK_MONOTONIC
        return tonumber(t.tv_sec) + tonumber(t.tv_nsec) * 1e-9
    end
end

local CORPORA = {
    {
        name = "primary",
        dirs = { "common", "events", "map/setup_scenarios", "prescripted_countries", "flags" },
        extensions = { "txt" },
    },
    {
        name = "secondary",
        dirs = { "interface", "gfx" },
        extensions = { "gui", "gfx", "asset" },
    },
}

-- Files in those directories that are not script: the game does not load them.
local SKIP = {
    ["common/HOW_TO_MAKE_NEW_SHIPS.txt"] = "prose documentation, not loaded by the game",
}

local windows = package.config:sub(1, 1) == "\\"
game_dir = game_dir:gsub("[/\\]+$", "")
if windows then
    -- the absolute path, which is how dir prints the files
    local p = io.popen('cd /d "' .. game_dir:gsub("/", "\\") .. '" 2>nul && cd')
    local absolute = p and p:read("*l")
    if p then
        p:close()
    end
    if absolute == nil or absolute == "" then
        io.stderr:write("parse_all: no directory " .. game_dir .. "\n")
        os.exit(2)
    end
    game_dir = absolute:gsub("[/\\]+$", "")
end

-- The files under a directory (recursively) with one of the extensions, as names relative to the
-- game directory with forward slashes, sorted.
local function list_files(dir, extensions)
    local path = game_dir .. "/" .. dir
    local command
    if windows then
        -- (dir also matches the 8.3 names: "*.txt" can list "a.txt2"; the extension test below
        -- drops those)
        local specs = {}
        for i, e in ipairs(extensions) do
            specs[i] = '"' .. path:gsub("/", "\\") .. "\\*." .. e .. '"'
        end
        command = "dir /s /b /a-d " .. table.concat(specs, " ") .. " 2>nul"
    else
        command = "find '" .. path .. "' -type f 2>/dev/null"
    end
    local wanted = {}
    for _, e in ipairs(extensions) do
        wanted[e] = true
    end
    local files = {}
    local p = assert(io.popen(command))
    for line in p:lines() do
        local name = line:sub(#game_dir + 2):gsub("\\", "/")
        local extension = name:match("%.([^./]+)$")
        if extension and wanted[extension:lower()] then
            files[#files + 1] = name
        end
    end
    p:close()
    table.sort(files)
    return files
end

local function same(a, b)
    if a.text or b.text then
        return a.text == b.text and a.quoted == b.quoted
    end
    if a.op or b.op then
        return a.op == b.op and same(a.key, b.key) and same(a.value, b.value)
    end
    if a.type ~= b.type or a.param ~= b.param or a.negated ~= b.negated or #a ~= #b then
        return false
    end
    for i = 1, #a do
        if not same(a[i], b[i]) then
            return false
        end
    end
    return true
end

-- Statistics of a corpus, gathered from its trees.
local function new_stats()
    return {
        entries = 0, statements = 0, bare_tokens = 0, bare_blocks = 0, conditions = 0, negated = 0,
        ops = {}, keys = {}, quoted_keys = 0, bare_keys = 0, variables = 0,
        quoted_values = 0, bare_values = 0, math = 0, block_values = 0, types = {},
    }
end

local function count_token(st, t)
    if t.quoted then
        st.quoted_values = st.quoted_values + 1
    else
        st.bare_values = st.bare_values + 1
        if t.text:byte(1) == 64 and t.text:find("^@\\?%[") then
            st.math = st.math + 1
        end
    end
end

local function gather(st, block)
    if block.type then
        st.types[block.type] = (st.types[block.type] or 0) + 1
    end
    st.entries = st.entries + #block
    for i = 1, #block do
        local e = block[i]
        if e.op then
            st.statements = st.statements + 1
            st.ops[e.op] = (st.ops[e.op] or 0) + 1
            local key = e.key.text
            st.keys[key] = (st.keys[key] or 0) + 1
            if e.key.quoted then
                st.quoted_keys = st.quoted_keys + 1
            else
                st.bare_keys = st.bare_keys + 1
            end
            local v = e.value
            if v.text then
                count_token(st, v)
            else
                st.block_values = st.block_values + 1
                gather(st, v)
            end
        elseif e.text then
            st.bare_tokens = st.bare_tokens + 1
            count_token(st, e)
        elseif e.param then
            st.conditions = st.conditions + 1
            if e.negated then
                st.negated = st.negated + 1
            end
            gather(st, e)
        else
            st.bare_blocks = st.bare_blocks + 1
            gather(st, e)
        end
    end
end

local function sorted_counts(t)
    local list = {}
    for k, v in pairs(t) do
        list[#list + 1] = { k, v }
    end
    table.sort(list, function(a, b)
        if a[2] ~= b[2] then
            return a[2] > b[2]
        end
        return a[1] < b[1]
    end)
    return list
end

local function mb(bytes)
    return bytes / (1024 * 1024)
end

local function print_stats(st)
    print(string.format("  entries: %d = %d statements, %d bare values, %d blocks in lists, %d parameter blocks ([[!X]: %d)",
        st.entries, st.statements, st.bare_tokens, st.bare_blocks, st.conditions, st.negated))
    local ops = {}
    for _, kv in ipairs(sorted_counts(st.ops)) do
        ops[#ops + 1] = string.format("%s %d", kv[1], kv[2])
    end
    print("  operators: " .. table.concat(ops, ", "))
    print(string.format("  keys: %d bare, %d quoted; top-level scripted variables (@name = ...): %d",
        st.bare_keys, st.quoted_keys, st.variables))
    local types = {}
    for _, kv in ipairs(sorted_counts(st.types)) do
        types[#types + 1] = string.format("%s %d", kv[1], kv[2])
    end
    print(string.format("  values: %d bare (of which %d inline math), %d quoted; %d block values; typed blocks: %s",
        st.bare_values, st.math, st.quoted_values, st.block_values, #types > 0 and table.concat(types, ", ") or "none"))
    print("  the 20 most common keys:")
    local keys = sorted_counts(st.keys)
    for i = 1, math.min(20, #keys) do
        print(string.format("    %8d  %s", keys[i][2], keys[i][1]))
    end
end

local t_start = util.now()
local total = { files = 0, bytes = 0, entries = 0, read_time = 0, parse_time = 0, round_trip_time = 0 }
local errors, warnings, warning_kinds = {}, {}, {}
local skipped = {}

for _, corpus in ipairs(CORPORA) do
    if only == nil or only == corpus.name then
        print(string.format("%s corpus (%s)", corpus.name, "*." .. table.concat(corpus.extensions, ", *.")))

        -- read
        local t0 = util.now()
        local files, per_dir = {}, {}
        for _, dir in ipairs(corpus.dirs) do
            per_dir[dir] = { files = 0, bytes = 0, entries = 0, errors = 0 }
            for _, name in ipairs(list_files(dir, corpus.extensions)) do
                if SKIP[name] then
                    skipped[#skipped + 1] = name .. ": " .. SKIP[name]
                else
                    local f = io.open(game_dir .. "/" .. name, "rb")
                    local text = f and f:read("*a")
                    if f then
                        f:close()
                    end
                    if text == nil then
                        errors[#errors + 1] = name .. ": cannot read the file"
                        per_dir[dir].errors = per_dir[dir].errors + 1
                    else
                        files[#files + 1] = { name = name, dir = dir, text = text }
                    end
                end
            end
        end
        total.read_time = total.read_time + (util.now() - t0)
        if #files == 0 then
            errors[#errors + 1] = string.format("%s: no %s corpus files (is it the game directory?)", game_dir, corpus.name)
        end

        -- parse
        local st = new_stats()
        local c_bytes, c_time = 0, 0
        for _, file in ipairs(files) do
            local d = per_dir[file.dir]
            local t1 = util.now()
            local tree, message = pdxscript.parse(file.text, file.name)
            c_time = c_time + (util.now() - t1)
            d.files, d.bytes = d.files + 1, d.bytes + #file.text
            c_bytes = c_bytes + #file.text
            if tree == nil then
                errors[#errors + 1] = message
                d.errors = d.errors + 1
            else
                file.parsed = true
                for _, w in ipairs(tree.warnings) do
                    warnings[#warnings + 1] = string.format("%s:%d:%d: %s: %s", file.name, w.line, w.col, w.kind, w.message)
                    warning_kinds[w.kind] = (warning_kinds[w.kind] or 0) + 1
                end
                local before = st.entries
                gather(st, tree)
                d.entries = d.entries + st.entries - before
                for i = 1, #tree do
                    local e = tree[i]
                    if e.op and not e.key.quoted and e.key.text:byte(1) == 64 then
                        st.variables = st.variables + 1
                    end
                end
            end
        end

        -- round trip: write the tree, parse that, compare
        local t2 = util.now()
        local identical = 0
        for _, file in ipairs(files) do
            if file.parsed then
                local tree = pdxscript.parse(file.text, file.name)
                local again, problem = pdxscript.parse(pdxscript.write(tree), file.name .. " (written back)")
                if again == nil then
                    errors[#errors + 1] = problem
                    per_dir[file.dir].errors = per_dir[file.dir].errors + 1
                elseif not same(tree, again) then
                    errors[#errors + 1] = file.name .. ": writing the tree back and parsing it gives another tree"
                    per_dir[file.dir].errors = per_dir[file.dir].errors + 1
                else
                    identical = identical + 1
                end
            end
        end
        total.round_trip_time = total.round_trip_time + (util.now() - t2)

        for _, dir in ipairs(corpus.dirs) do
            local d = per_dir[dir]
            print(string.format("  %-24s %5d files %8.2f MB %9d entries%s", dir, d.files, mb(d.bytes), d.entries,
                d.errors > 0 and string.format(", %d errors", d.errors) or ""))
        end
        print(string.format("  %-24s %5d files %8.2f MB %9d entries, parsed in %.2f s (%.1f MB/s)", "all", #files, mb(c_bytes),
            st.entries, c_time, mb(c_bytes) / math.max(c_time, 1e-9)))
        print(string.format("  round trip (write, parse again, compare): %d of %d files give the same tree", identical, #files))
        print_stats(st)
        print()
        total.files, total.bytes = total.files + #files, total.bytes + c_bytes
        total.entries, total.parse_time = total.entries + st.entries, total.parse_time + c_time
    end
end

for _, s in ipairs(skipped) do
    print("skipped " .. s)
end
print(string.format("total: %d files, %d bytes (%.2f MB), %d entries, parsed in %.2f s (%.1f MB/s)",
    total.files, total.bytes, mb(total.bytes), total.entries, total.parse_time, mb(total.bytes) / math.max(total.parse_time, 1e-9)))
print(string.format("       listing and reading %.2f s, round trip %.2f s, everything %.2f s",
    total.read_time, total.round_trip_time, util.now() - t_start))
print(string.format("errors: %d", #errors))
for _, e in ipairs(errors) do
    print("  " .. e)
end
print(string.format("warnings: %d", #warnings))
for _, kv in ipairs(sorted_counts(warning_kinds)) do
    print(string.format("  %-18s %d", kv[1], kv[2]))
end
for _, w in ipairs(warnings) do
    print("  " .. w)
end
os.exit(#errors == 0 and 0 or 1)
