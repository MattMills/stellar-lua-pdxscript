-- tools/oracle_importprofile.lua : the imports a Linux build calls while its static lexer builds
-- its token table (CStaticLexer::InitTokens, the heaviest start-up the oracle runs), counted: the
-- ones worth a native version (oracle/hle.lua: hle.native, tools/native/).
--
--   luajit tools/oracle_importprofile.lua <stellaris> [how many, default 15]

local here = arg[0]:match("^(.*)[/\\]tools[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. package.path

local machine = require("oracle.machine")
local m = machine.new(require("oracle.elf").load(assert(arg[1], "usage: luajit tools/oracle_importprofile.lua <stellaris> [n]")))
local counts = {}
local stub_hit = m.stub_hit
m.stub_hit = function(self, address)
    local name = self.stub_names[address]
    if name then counts[name] = (counts[name] or 0) + 1 end
    return stub_hit(self, address)
end
local t = os.clock()
local lexer = m:call(m:sym("_ZN12CStaticLexer17AccessStaticLexerEv"))
m:call(m:sym("_ZN12CStaticLexer10InitTokensEv"), lexer)
print(string.format("InitTokens: %.1f s", os.clock() - t))
local list = {}
for name, n in pairs(counts) do list[#list + 1] = { name, n } end
table.sort(list, function(a, b) return a[2] > b[2] end)
for i = 1, math.min(tonumber(arg[2]) or 15, #list) do
    print(string.format("%10d  %s", list[i][2], list[i][1]))
end
m:close()
