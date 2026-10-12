rockspec_format = "3.0"
package = "pdxscript"
version = "scm-1"
source = {
    url = "git+https://github.com/MattMills/stellar-lua-pdxscript.git",
}
description = {
    summary = "A parser for Paradox script (pdxscript), in plain Lua",
    detailed = "Turns Paradox (Clausewitz/Jomini) script text into a tree that keeps everything the text says, and writes trees back; checked on every vanilla Stellaris 4.5.2 script file.",
    homepage = "https://github.com/MattMills/stellar-lua-pdxscript",
    license = "MIT",
}
dependencies = {
    "lua >= 5.1",
}
build = {
    type = "builtin",
    modules = {
        pdxscript = "pdxscript.lua",
    },
}
test = {
    type = "command",
    script = "tests/test_pdxscript.lua",
}
