-- tools/pe_info.lua : a Windows executable as the oracle loads it (oracle/image.lua: its PDB, else
-- labels, else a transfer): the architecture, the image, the imports, TLS, where its symbols come
-- from, and the symbols whose decorated names match each pattern, with what oracle/msvc.lua reads
-- from them (the qualified name, the calling convention, what the function pops on i386). The
-- symbols of a build with labels are the labels (`CTextLexer::GetTok`), not decorated names.
--
--   luajit tools/pe_info.lua <stellaris.exe> [Lua pattern ...]
--
--   luajit tools/pe_info.lua stellaris.exe "^%?GetTok@" "^%?%?0CToken@"

local here = arg[0]:match("^(.*)[/\\]tools[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. package.path

local msvc = require("oracle.msvc")

local path = assert(arg[1], "usage: luajit tools/pe_info.lua <stellaris.exe> [Lua pattern ...]")
local t = os.clock()
local ok, img = pcall(require("oracle.image").load, path)
if not ok then
    print("(" .. tostring(img) .. ")")
    img = require("oracle.pe").load(path, { no_symbols = true })
end
print(string.format("%d-bit %s, base 0x%x, size 0x%x, %d imports, loaded in %.1f s", img.bits, img.abi,
    img.base, img.size, #img.imports, os.clock() - t))
if img.tls then
    print(string.format("TLS: data 0x%x..0x%x, index at 0x%x, %d bytes zero-filled", img.tls.start, img.tls.stop,
        img.tls.index, img.tls.zero_fill))
end
local n = 0
for _ in pairs(img.symbols or {}) do n = n + 1 end
print(string.format("%d symbols, from %s", n, tostring(img.symbol_source)))
for i = 2, #arg do
    for _, s in ipairs(img:find(arg[i])) do
        local sig, err = msvc.signature(s.name, img.bits)
        print(string.format("0x%x %5d %s  [%s]  %s", s.value, s.size or 0, s.name, tostring(msvc.qualified(s.name)),
            sig and (sig.kind .. " " .. tostring(sig.convention) .. " pops=" .. tostring(sig.pops) ..
                (sig.hidden_return and " hidden-return" or "")) or ("unreadable: " .. tostring(err))))
    end
end
