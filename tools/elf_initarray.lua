-- tools/elf_initarray.lua : the static initializers of a Linux build (.init_array, .ctors,
-- .preinit_array), named: how many each table has, the first five, and those whose name contains a
-- word (default "lexer": the translation units Machine:static_init is asked to run). Also says
-- whether the build has IRELATIVE relocations (ifuncs).
--
--   luajit tools/elf_initarray.lua <stellaris> [word]

local here = arg[0]:match("^(.*)[/\\]tools[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. package.path

local ffi = require("ffi")
local img = require("oracle.elf").load(assert(arg[1], "usage: luajit tools/elf_initarray.lua <stellaris> [word]"))
local word = (arg[2] or "lexer"):lower()
for _, name in ipairs({ ".init_array", ".ctors", ".preinit_array" }) do
    local s = img.sections[name]
    if s then
        local w = img.bits / 8
        local n = s.size / w
        print(name, n, "entries")
        local p = ffi.cast("const uint8_t *", img.data) + s.offset
        for i = 0, n - 1 do
            local v = img.bits == 64 and tonumber(ffi.cast("const uint64_t *", p)[i])
                or tonumber(ffi.cast("const uint32_t *", p)[i])
            local name_at = img:name_at(v) or string.format("0x%x", v)
            if i < 5 or name_at:lower():find(word, 1, true) then
                print(i, string.format("0x%x", v), name_at)
            end
        end
    end
end
for _, r in ipairs(img.relocs or {}) do
    if r.type == 37 or r.type == 42 then
        print("IRELATIVE relocations: yes")
        break
    end
end
