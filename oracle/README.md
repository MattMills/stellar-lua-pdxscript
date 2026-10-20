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
luajit tools/oracle_read.lua <stellaris executable> -e '@x = 2 a = @[ x * 3 ]'  # the statement reader
luajit tools/oracle_readrun.lua <stellaris executable> out.tsv               # its cases, one build
luajit tools/oracle_readreport.lua <dir of .tsv> [--raw]                     # the builds compared
luajit tools/oracle_initrun.lua <stellaris executable> out.tsv               # InitGame and the databases
luajit tools/oracle_initreport.lua <dir of .tsv> [--full]                    # the builds compared
luajit tools/oracle_abi.lua <stellaris executable> keys.tsv [k/n] [class]    # the keys every class reads
luajit tools/oracle_abijson.lua abi.json keywords.tsv keys-*.tsv            # the script ABI, one file
luajit tools/oracle_abidocs.lua abi.json triggers.log effects.log [--list]  # it against script_docs
```

It needs LuaJIT and the Unicorn 2 emulator library (`PDXORACLE_UNICORN` = the path of
`libunicorn.so` / `unicorn.dll` unless it is on the library path). Unicorn 2.1.1 builds with
`cmake -DUNICORN_ARCH=x86 -DCMAKE_BUILD_TYPE=Release`.

### Every build at once

```
luajit tools/oracle_builds.lua linux > linux.lst        # or pdb, labels, transfer, windows, none
tools/oracle_runall.sh linux.lst lex/ tools/oracle_lexrun.lua 16   # a runner on every build
tools/oracle_checkall.sh lexer lex/                     # pdxlexer against each (or: reader read/)
tools/oracle_fuzzall.sh linux.lst fuzz/ 2000 1 16       # pdxreader fuzzed against each
```

`tools/oracle_builds.lua` lists the builds of the archive the oracle can run: executable, a name
that starts with its version, and for a build that needs one its transfer chain. The shell scripts
take their environment from `tools/oracle_env.sh`: `PDXORACLE_DEPS` (where unicorn and LuaJIT were
built), `PDXORACLE_ARCHIVE` (the directory of `stellaris_backups_steam` and
`stellaris_backups_gog`), and `PDXORACLE_LABELS` / `PDXORACLE_CORPUS` (stellar-fnmatch's labels
of the Windows builds without a PDB), each with a default for the machine they were made on.

For looking inside a build: `tools/pe_info.lua` (a Windows executable as loaded, its symbols that
match a pattern, decoded), `tools/pe_vtable.lua`, `tools/pe_calls.lua`, `tools/oracle_crtinit.lua`
(its C runtime started in the emulator), `tools/elf_dis.sh`, `tools/elf_initarray.lua`,
`tools/oracle_importprofile.lua` (the imports start-up calls most).

## How it works

| file | |
|---|---|
| `unicorn.lua` | Unicorn through the LuaJIT FFI: memory, registers, hooks |
| `elf.lua` | an ELF executable (x86, x86-64): segments, symbols, relocations, sections |
| `machine.lua` | the process: the image mapped and relocated, a stub per imported function, a heap, a stack, the thread pointer and TLS; `m:call(address, ...)` runs a function of the game; static initializers (`m:static_init`), function replacement (`m:replace`), a basic block trace for errors (`m:trace`), observation hooks (`m:on_enter`, `m:coverage`) |
| `hle.lua` | the shared libraries the game calls, in Lua: libc, libm, operator new/delete, the C++ runtime, pthreads (one thread), tbb's allocator. The hottest (memcpy, memcmp, strlen, tolower ...) are x86 code that runs inside the emulator (its source: `tools/native/`, `assemble.sh --check`) |
| `image.lua` | an executable of either kind: ELF, or PE with its symbols from its PDB, else labels, else a transfer |
| `pe.lua`, `pdb.lua` | a Windows executable (PE32, PE32+): sections, imports, TLS; the public symbols of its program database (MSVC decorated names) |
| `msvc.lua` | what a decorated name says: the qualified name, function or data, the calling convention, what an i386 function pops |
| `labels.lua` | symbols for a Windows build without a PDB from stellar-fnmatch's labels: overloads and vtables placed by a nearby build with a PDB |
| `transfer.lua` | symbols for a 32-bit build with neither, carried over from a build with a PDB by matching its code (not run yet) |
| `hle_msvc.lua`, `hle_msvc_ctype.lua` | the Windows API the game calls (the C and C++ runtimes are linked into the game and run as its own code); Windows' character data, measured (`tools/measure_ctype.py` writes it) |
| `hle_string.lua`, `hle_cowstring.lua` | libstdc++'s `std::string`, C++11 ABI (2.x, 3.x) and old copy-on-write ABI (1.x): the game's `CString` is one |
| `hle_tree.lua` | libstdc++'s red-black tree (`std::map`) and hash table rehash policy |
| `gamelog.lua` | the game's log (`CLogger::Log`, `CLogStream`) captured into `m.log` |
| `gamelexer.lua` | `CTextLexer::GetTok` on any text: the lexer made by the game, its layout found by probing |
| `gamereader.lua` | the statement reader (`CReader` in `CPersistent::Read`) on any text: an object of the game's own class whose `ReadMember` is Lua, blocks read through the game's `CReader::Read(CPersistent&)` in nested emulation |
| `gameabi.lua` | the script ABI: every class's `ReadMember` run with every token of the static lexer, the paths grouped into its keys; the classes of the triggers and effects from their registries; RTTI bases |
| `gameinit.lua` | `CGameApplication::InitGame`'s steps and the databases (table, dependencies, order): [init_sequence.md](init_sequence.md) |
| `report.lua` | the runners' results of all builds grouped by result, with version ranges |
| `cases.lua`, `reader_cases.lua` | texts that probe the corners of a lexer, of a statement reader |

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

Between 1.2.5 and 2.3.0, and between 2.5.0 and 3.12.5, there is no Linux build with symbols. The
Windows builds of those versions (126 with a PDB, 127 labelled by stellar-fnmatch; all but one,
whose PDB cannot be read, run) place the changes closer: `>=` / `<=` as one token and the NUL
handling of 2.x come between 1.2.5 and 2.1.4.4; `!` and `!=` as tokens (so `[[!P]`, and `NOT` /
`not` with the id of `!`) between 2.8.1.2 and 3.0.1. The profiles of `pdxlexer` and `pdxreader`
still change where the Linux builds put it, so the versions in those gaps differ from them
(`tools/oracle_checkall.sh`). The 32-bit Steam builds 1.3 to 2.1 have neither a PDB nor labels;
`transfer.lua` is for them.

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

## Results: the statement readers of 50 builds

`gamereader.lua` runs a build's own `CPersistent::Read` (a loop of `CReader::ReadSimpleStatement`
and the object's `ReadMember`) on any text: the object is of the game's class, with `ReadMember` in
Lua, which records the key, operator and value the reader holds (where it keeps them is probed:
`zzkey = zzval` read, then looked for) and reads a `{` value as an object's member does, with
`CReader::Read(CPersistent&)` in a nested emulation. The reader's own messages are captured from
its loggers (`CNullLogger::Log` and the others, `gamelog.lua`).

The 81 reader cases (`reader_cases.lua`) on the 50 builds split only at the eras:

| | 1.0.0 to 1.2.5 | 2.3.0 to 2.5.0 | 3.12.5 to 4.5.2 |
|---|---|---|---|
| operators | `=` `<` `>` (so `a >= 1` is `a >` with the value `=`, then `1` a new key) | `=` `<` `>` `<=` `>=` | and `!=` |
| a `}` where a value should be | the value is a NUMBER `4` | the value is `}` | the value is `}` |
| variable names | anything | a letter, then letters, digits, `_` ("Invalid variable name [1]. ...") | the same |
| a name already taken | logged; its `=` and value are read as statements | logged; its `=` and value skipped | the same |
| `@y = @x` | x read as another definition ("taken"), then resolved | resolved, and the token after it skipped | the same |
| inline math | none: `@[` is a word | 3 decimals, 32-bit (`7.000`, `0.333`) | 5 decimals, 64-bit (`7`, `0.33333`) |
| `%` in math | | an invalid character, dropped (`7 % 3` is `73.000`) | the remainder |
| inline scripts | | | read from the game's files |

In every version: `?=` is not an operator (`a ?= b` is `a`, then the key `?`); a quoted `"@x"` is
not a variable; a file whose last statement is a variable definition hands the object the previous
statement's key again; the first definition of a name wins.

Three of these are the game doing what nobody meant, and a modder can hit them:
`@a = @[ 1 + 2 ]` (or `@a = @b`) skips the token after it, from 2.3 (`@a = @[ 1 + 2 ] @b = 5`
leaves `@b` undefined); inline math as the very last value of a file makes the reader read past
the end of the file for a `]`, forever (2.3 on); a file that ends in a variable definition reads
its last key twice. Vanilla never does any of them. `pdxreader` reports them in `tree.bugs`, and
`pdxast` as diagnostics.

`pdxreader.lua` is checked with `tools/oracle_check_reader.lua` (the reader cases: the same
statements, variables and messages in all 50 builds) and `tools/oracle_readfuzz.lua`, which reads
random texts made of script's pieces with a build's reader and with pdxreader and shrinks each text
read differently to the fewest pieces that still differ. The fuzzer found what the cases did not
(1.x registers a name once its `=` is read; a quoted `"@x"` is not a variable; NOT has `!`'s id in
3.x); now 3,000 random texts per build read the same on all 50 builds, and 2,000 with inline math on
1.2.5, 2.3.3, 2.5.0, 3.12.5, 4.3.2, 4.3.3 and 4.5.2.

## Results: the vanilla corpora

The GOG archive keeps the game's files for 70 versions (2.1.4.4 to 3.10.4); 4.5.2's are the
installed game's. `tools/ast_check.lua` reads every script file of each with that version's
profile: all print back byte for byte from pdxast, and pdxscript reads all with 0 errors (two
tolerances were added for them: `bracket_word` for 2.8's `log = [from.GetName]`, `stray_operator`
for 2.2 to 2.5's `ion_cannon = { = {`).

What the corpora say about the gaps: 2.1.4.4 to 2.2.7 use `>=` and `<=` 4,777 times, so their
lexer has one-token comparisons (measured from 2.3.0 only); 2.6 to 3.10 use `!=` 342 times, so
`!` is an operator before 3.12.5 (measured from 3.12.5 only). The Windows builds of those versions
will say exactly when.

## The script ABI: every key every class reads

The lexer's design makes the game's script interface enumerable. Every word the code compares
against is a token of the static lexer (10,004 in 4.5.2, ids fixed at startup), and every class
read from script reads its members in one function, `ReadMember(CReader&, int token[,
EScopeType])`: a switch on the token's id, whose default hands the token on (to the base class's,
which ends in `ReportUnexpected`). So running each class's own `ReadMember` once per token, on an
object its own constructor made, with the game's `CReader` reading `<token> = 1`, walks every
path of it, and the paths are the keys.

```
luajit tools/oracle_abi.lua <stellaris executable> keywords.tsv keywords   # triggers, effects: classes, bases
for k in $(seq 1 22); do luajit tools/oracle_abi.lua <stellaris executable> keys-$k.tsv $k/22 & done; wait
luajit tools/oracle_abijson.lua abi-4.5.2.json keywords.tsv keys-*.tsv
```

`gameabi.lua` first runs the 1,524 static initializers (they register the triggers and effects:
`RegisterTriggerEntry`, `RegisterEffectEntry`) and creates the databases the initializers did not
(200). Then, for each class with a `ReadMember` and a vtable, for each token, it records the
basic blocks of `ReadMember` that ran, the first functions it entered, its result and whether it
failed, the class of an object a member is read into (the vtable of `CReader::Read(CPersistent&)`'s
argument) and the databases whose instance it read (a key into one, a block of triggers). Tokens
with the same path are one group; the largest is the token the class does not read. A group is a
key when its first call or its result differs from that one's.

The triggers and effects are the keys of the registries, `std::map`s in the trigger and effect
databases, with each entry's factory (`CTriggerEntry<C...>::Create`) naming its class, and
`std::type_info`'s base chain giving its form (`CBoolTrigger` is `= yes/no`, `CIntTrigger` a
comparison, `CAndTrigger` a block). `oracle_abijson.lua` folds what is not a key of its own: a
class that reads 100 triggers or effects or more reads a block of statements (`"statements"`); a
class that reads 1000 tokens or more with one reader reads any key with it (`"any_key"`: name
lists, weighted string tables); one that reads 1000 or more with no call ignores a token it does
not read (`"ignores_unknown"`: the settings). A keyword's keys are those of the `ReadMember`s
that run for it: its class's (or its nearest base's), then each one a token it does not read goes
to, which can be a helper's (`create_species` reads a species with `CSpecies::ReadMember`).

### Results (Stellaris 4.5.2, Linux)

The ABIs are kept in [stellar-abi-pdxscript](https://github.com/MattMills/stellar-abi-pdxscript) (`abi/v4.5.2.json`): 1,623 classes (491 made by their own constructor, the others an object of
their vtable), 9,851 keys, 1,098 triggers and 1,080 effects: exactly those of the game's own
documentation (`script_docs`). 22 shards on 24 cores take 25 minutes. A key's `reader` is the
first function its value goes to (`CReader::Read(CFixedPoint&)`, `TokenToEnum<EScriptMaths>`,
`NParserUtil::ReadKeyReference<CTechnologyDatabase>` ...), its `object` the class read for a
block (`ai_weight` a `CMeanTimeToHappen`, `cost` a `CScriptableValue`).

Against the documentation's usage examples (`tools/oracle_abidocs.lua`): of 2,137 keys documented
for 834 keywords, the ABI has 2,064. Of the 73 it has not, about half are not keys: example
values of a class that reads any key (`switch`'s `ethic_xenophile`, `random_list`'s `20`, flag
names, resources, ship roles) and mistakes in the docs (`show_nofication`, `Count`, `e.g.mult`).
The rest are the method's limits: a key whose path is the default's (it is read and the function
returns as for a token it does not read: `trait_has_all_tags`, `default`), and keys read after one
that failed in the emulator (`add_timeline_event`'s). 2,692 keys are read but their value failed:
most are references into a database, which is empty in the emulator. The ABI has 723 keys the
docs do not mention (`clone_leader`'s 24, `create_rebels`' 25, ...). For `CTechnology`, all 25
keys vanilla's technologies use are found, with 10 more.

Not yet: the value of a keyword that is not a block (its class's `Read`, for `always = yes`), the
databases loaded so references read, and the other builds.
