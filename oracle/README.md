# oracle: every build of the game as a test oracle

`pdxscript.lua` reads script the way Stellaris 4.5.2 does. Earlier and later builds read it
differently, and the only exact description of how is their own code. The oracle runs that code:
a build's executable is loaded into a CPU emulator, and its own functions (the lexer first) are
called on any text, from Lua. Nothing is reimplemented from the disassembly. The game's own
constructors make the objects, and the game's own small functions show where their fields are.
So one driver works for every build, from 1.0.0 to 4.5.2.

```
luajit tools/oracle_tokens.lua <stellaris executable> -e 'a = { b >= 1 }'   # one build, one text
luajit tools/oracle_lexrun.lua <stellaris executable> out.tsv                # the cases, one build
luajit tools/oracle_lexreport.lua <dir of .tsv> [--logic | --raw]            # the builds compared
```

It needs LuaJIT and the Unicorn 2 emulator library (`PDXORACLE_UNICORN` = the path of
`libunicorn.so` / `unicorn.dll` unless it is on the library path). Unicorn 2.1.1 builds with
`cmake -DUNICORN_ARCH=x86 -DCMAKE_BUILD_TYPE=Release`.

## How it works

| file | |
|---|---|
| `unicorn.lua` | Unicorn through the LuaJIT FFI: memory, registers, hooks |
| `elf.lua` | an ELF executable (x86, x86-64): segments, symbols, relocations, sections |
| `machine.lua` | the process: the image mapped and relocated, a stub per imported function, a heap, a stack, the thread pointer and TLS; `m:call(address, ...)` runs a function of the game; static initializers (`m:static_init`), function replacement (`m:replace`), a basic block trace for errors (`m:trace`), observation hooks (`m:on_enter`, `m:coverage`) |
| `hle.lua` | the shared libraries the game calls, in Lua: libc, libm, operator new/delete, the C++ runtime, pthreads (one thread), tbb's allocator. The hottest (memcpy, memcmp, strlen, tolower ...) are x86 code that runs inside the emulator |
| `hle_string.lua`, `hle_cowstring.lua` | libstdc++'s `std::string`, C++11 ABI (2.x, 3.x) and old copy-on-write ABI (1.x): the game's `CString` is one |
| `hle_tree.lua` | libstdc++'s red-black tree (`std::map`) and hash table rehash policy |
| `gamelog.lua` | the game's log (`CLogger::Log`, `CLogStream`) captured into `m.log` |
| `gamelexer.lua` | `CTextLexer::GetTok` on any text: the lexer made by the game, its layout found by probing |
| `cases.lua` | texts that probe the corners of a lexer |

Character classes are glibc's in the "C" locale, measured: `iswspace` of a signed char is HT, LF,
VT, FF, CR and space in every locale, and `tolower` of -128..-2 is c + 256.

### Finding the layout instead of knowing it

The lexer's token and file objects changed between versions (an inline 256-byte buffer and an
overflow vector in 1.x, a `CPdxHybridArray` in 4.x; the file's last byte at +0xc in 2.x and 3.x,
+0x10 in 4.x). `gamelexer.lua` finds them each time:

- the token: four tokens made by the game's `CToken(int, char const*)` (or, in 1.x,
  `CToken(int, CString const&)`) with known ids and short and long texts; the id is the field that
  holds the ids, the text is behind the pointer (or pointer to pointer, or in the token while short)
  that reads back the texts, the size is the field that holds their lengths plus one;
- the file: `CFile::UnGet` on a block of line feeds shows the put-back flag (the byte set to 1) and
  the line (the word decremented); on a block of zeros, the byte that makes it decrement the line is
  the last byte read;
- the quoted flag: the byte that GetTok sets for `"x"` and not for `y`.

### What the game's code needed

1.x keeps its token table in globals that the static initializers construct: the machine runs
them (`m:static_init`; all 884 of 1.0.0 run). 1.x profiles `InitTokens`, and the profiler asks
tbb's thread-local storage which thread it is on: `ThreadIsMainThread` and `CProfileScope` are
replaced (`gamelexer.ENVIRONMENT`). On i386 a function returning a struct removes the hidden
pointer itself (`ret 4`), and a floating point result is pushed on the x87 stack: both handled
for the imports that do it.

## Results: the lexers of 50 builds

The 50 Linux builds whose executables have symbols (Steam depot 281994: 1.0.0 to 1.2.5, 32-bit;
2.3.0 to 2.5.0 and 3.12.5 to 4.5.2, 64-bit), 100 cases each: about 40 seconds on 16 cores. With
`--logic` (keywords and other words counted as one kind, so what is compared is the lexer's own
logic), 76 cases behave the same in every build, and 24 differ:

| behaviour | versions |
|---|---|
| `>=` and `<=` are two tokens (`>` `=`), and `>` / `<` do not look at the next byte | 1.0.0 to 1.2.5 |
| `>=` (971) and `<=` (972) are one token; after `>` / `<` the next byte is read and put back | 2.3.0 to 4.5.2 |
| `!` starts a comment, like `#` (so `a != b` is `a`) | 1.0.0 to 2.5.0 |
| `!` is a token (1062), `!=` too (1063); the words `NOT`, `not` get the id of `!` | 3.12.5 to 4.5.2 |
| a NUL byte ends a token's text (`"a\0b"` is `a`), a lone NUL is a token of id 0 | 1.0.0 to 1.2.5 |
| a token's text keeps NUL bytes (`a\0b`), a lone NUL is a NUMBER (12) | 2.3.0 to 4.5.2 |
| a word longer than 256 bytes overruns the token's buffer into its quoted flag | 1.0.0 to 1.0.3 |
| `?=` is the word `?` and `=`; `owner?=` is `owner?` and `=` | all |
| `;` starts a comment; `(` `)` `,` are tokens | all |
| a backslash before anything but `"` or `\` in a string stays, with the warning "Backslash followed by neither quote nor backslash, ..." | all |

Between 2.5.0 and 3.12.5 there is no Linux build with symbols. The Windows builds of those
versions (with PDBs, or labelled by stellar-fnmatch) are the next to add.

## pdxlexer: GetTok of every version, checked

`pdxlexer.lua` is GetTok in plain Lua with a profile per version (`pdxlexer.profile("2.8.1")`):
`comparisons`, `bang`, `nul`, `read_math`, `long_token`, from the table above. Checked with
`tools/oracle_check_lexer.lua` against what each of the 50 builds' own lexers did, every field of
every call (rc, id kind, quoted flag, text, line, position, last byte, put-back flag):

| builds | cases that differ |
|---|---|
| 1.1.0 to 4.5.2 (45 builds) | 0 |
| 1.0.0 to 1.0.3 (5 builds) | 4: the tokens longer than 256 bytes, which overrun the token's buffer in the game (a bug, not imitated; counted in `long_tokens`) |

stellarstellaris-win's `lua/stellar/script/lexer.lua` (written for 4.5.2) is exact for 3.12.5 to
4.5.2 and differs before, where the profiles change. A version in a gap between measured ranges
gets the earlier profile, marked `uncertain` when a profile changes in that gap.
