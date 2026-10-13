-- tools/oracle_crtinit.lua : a Windows build's C runtime started in the emulator as
-- oracle/machine.lua does (Machine:crt_init: the security cookie, __scrt_initialize_crt, the C
-- initializers), and how each step went; then the imports it called that oracle/hle_msvc.lua does
-- not have, and the procedures it asked GetProcAddress for that it did not get.
--
--   luajit tools/oracle_crtinit.lua <stellaris.exe>

local here = arg[0]:match("^(.*)[/\\]tools[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. package.path

local machine = require("oracle.machine")
local m = machine.new(require("oracle.image").load(assert(arg[1], "usage: luajit tools/oracle_crtinit.lua <exe>")))
for _, r in ipairs(m.crt_init_results or {}) do
    print(r.name, r.ok and "ok" or "failed", r.ok and tostring(r.result) or tostring(r.error))
end
local missing = {}
for name, count in pairs(m.unimplemented) do missing[#missing + 1] = name .. "=" .. count end
table.sort(missing)
print("imports not implemented: " .. table.concat(missing, " "))
local procs = {}
for name in pairs(m.missing_procs or {}) do procs[#procs + 1] = name end
table.sort(procs)
print("GetProcAddress misses: " .. table.concat(procs, " "))
m:close()
