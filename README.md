# stellar-lua-pdxscript

A parser for Paradox script ("pdxscript", the Clausewitz/Jomini text format of `common/`,
`events/` and friends), in plain Lua: `pdxscript.lua`, one file, no C, for LuaJIT 2.1 and Lua 5.1
to 5.4. It turns script text into a tree that keeps everything the text says, in order, and writes
trees back as text.

The rules are the ones the Stellaris 4.5.2 files actually use, measured on the installed game:
every vanilla script file (4,371 files, 54 MB) parses with 0 errors, and writing each tree back and
parsing that gives the same tree. It is the syntax layer of the Lua script engine of
[stellarstellaris-win](https://github.com/MattMills/stellarstellaris-win).

```lua
local pdxscript = require("pdxscript")

local tree, message = pdxscript.parse(text, "common/edicts/00_edicts.txt")
if tree == nil then
    error(message)  -- "common/edicts/00_edicts.txt:12:9: expected a value after '='"
end
for _, entry in ipairs(tree) do
    if entry.op then  -- a statement: key op value
        print(entry.key.text, entry.op, entry.value.text or "{ ... }", entry.line)
    end
end
for _, w in ipairs(tree.warnings) do  -- malformed text read the way the game reads it
    print(w.kind, w.line, w.col, w.message)
end
print(pdxscript.write(tree))  -- back to text (without the comments)
```

| | |
|---|---|
| `pdxscript.parse(text [, name])` | the tree of a file, or `nil` and `"name:line:col: message"` |
| `pdxscript.write(block)` | a block (a tree, or any block in it) as script text, one entry per line |
| `pdxscript.unescape(text)` | the value of a quoted string: `\"` -> `"`, `\\` -> `\` |

Install: copy `pdxscript.lua` anywhere on `package.path`, or `luarocks make` (the rockspec is in
this directory).

```
luajit tests/test_pdxscript.lua                     # 209 targeted tests (any Lua 5.1 to 5.4 too)
luajit tools/parse_all.lua "<Stellaris dir>"        # every script file; exit code 0 = no error
luajit tools/parse_all.lua "<Stellaris dir>" primary
cd tools/docs_mod && luajit make_docs_mod.lua "<docs dir>" "<Stellaris dir>" "<out dir>"
```

`parse_all` parses the primary corpus (the game's script: `common/**/*.txt`, `events/*.txt`,
`map/setup_scenarios`, `prescripted_countries`, `flags`) and the secondary one (the `.gui`, `.gfx`
and `.asset` files under `interface/` and `gfx/`, same syntax), prints counts per directory, every
error and warning, statistics (operators, quoted and bare values, the most common keys) and runs
the round trip (write, parse again, compare).

`docs_mod/make_docs_mod.lua` reads the script documentation the game writes when it starts
(`logs/script_documentation`) and builds a mod that uses every documented trigger, effect, scope
link, modifier and localisation command once, where the game accepts it, with a manifest of the
file and line of each: a corpus for checking a reader against what the game compiled. See
[tools/docs_mod/README.md](tools/docs_mod/README.md).

## Every version

`pdxscript.lua` is the fast tree of how 4.5.2 is written. The game's builds from 1.0.0 to 4.5.2
read script differently in places, and the other modules read it the way a given version does,
each checked against that version's own code run in an emulator ([oracle/](oracle/README.md)):

| | |
|---|---|
| `pdxlexer.lua` | the game's tokenizer (`CTextLexer::GetTok`) with a profile per version: `pdxlexer.profile("2.8.1")`; the same tokens, field for field, as every build measured |
| `pdxreader.lua` | the game's statement reader (`CPersistent::Read`, `CReader::ReadSimpleStatement`): keys, operators, values, scripted variables, the reader's messages, and the places where the game does what the text did not mean (`tree.bugs`); the same as every build measured, on the reader cases and on random text |
| `pdxmath.lua` | the game's inline math (`@[ ... ]`): the same text, value and messages as each version's evaluator |
| `pdxast.lua` | the full syntax tree: lossless (printing it gives the text back), typed values (numbers, dates, scope chains, variables, math expressions, parameters), positions, the version's reading as diagnostics; `pdxast.tree` is pdxscript's tree |
| `oracle/` | the game's own lexer, reader and start-up, of any build, run from Lua in an emulator, and the tools that compare builds with each other and with these modules |

```
luajit tests/test_pdxlexer.lua
luajit tests/test_pdxast.lua
luajit tools/ast_check.lua "<Stellaris dir>" [version] [--semantic]   # every file: printed back, the same tree
```

Every vanilla corpus archived (70 GOG versions, 2.1.4.4 to 3.10.4, and 4.5.2) parses with 0 errors
in pdxscript, and prints back byte for byte from pdxast.

## The tree

A block is a Lua array of entries in source order (duplicates kept), with `line` (of its `{`),
`last` (of the `}` that closes it) and, for a typed block, `type`. The tree is the block of the file, with `name` and `warnings`. An entry
is one of:

| entry | shape | test |
|---|---|---|
| statement | `{ key = token, op = "=", value = token or block, line = n }` | `e.op` |
| bare value | a token: `{ text = "...", quoted = true or nil, line = n }` | `e.text` |
| block in a list | a block | otherwise |
| parameter block | `{ param = "NAME", negated = true or nil, line = n, [1..n] = entries }` | `e.param` |

A token keeps its text as written: numbers, dates and booleans stay text (`"-1.5"`, `"2200.01.01"`,
`"yes"`), quoted strings keep their escapes (`pdxscript.unescape` decodes them), inline math is one
token with its brackets. Scripted variables (`@my_var`), parameters (`$PARAM$`), scope chains
(`event_target:x`, `root.owner?`) and script values with arguments (`value:v|P|5|`) are ordinary
words: they mean something only to an interpreter.

Memory: the trees take about 14 times the size of the text (all of Stellaris' script together,
about 470 MB). An interpreter should keep only the trees it uses, or reduce them.

## Lexical rules

* **Encoding.** UTF-8; 84 primary files start with a BOM (5 secondary), which is skipped. Every
  token in the primary corpus is ASCII: non-ASCII bytes only appear in comments (and in one typo
  in a particle file, `30§`). A non-ASCII byte is part of a word.
* **Lines.** All files use LF; there is no CRLF in 4.5.2. A CR is a blank, so CRLF files work too.
  Line numbers count LFs; columns in messages count bytes from 1 (a tab is one column).
* **Blanks.** Space, tab, CR, LF, VT, FF.
* **Comments.** `#` to the end of the line, anywhere outside a quoted string (`a = b#c` is `a = b`).
  Comments are not kept in the tree.
* **Quoted strings.** From `"` to the next `"` not escaped by `\`. They may span lines: 15 values
  do, all script passed as a parameter to an inline script (`TRIGGER = "owner? = {` ... `}"` 7
  times, `TRAITS = "..."` 8 times). `\"` and `\\` are escapes; the only one vanilla uses is `\\`
  (54 times in 44 strings), always before a localisation command in the `log` (30) and
  `variable_string` (14) of scripted effects and triggers: `log = "- Root: \\[Root.GetName]"`,
  which `common/scripted_effects/99_advanced_documentation.txt` says is needed there. The tree
  keeps the escapes as written.
* **Operators.** `=` `==` `!=` `<` `>` `<=` `>=` and `?=`. Seen in the primary corpus: `=`
  1,105,575, `>` 3,676, `>=` 3,105, `<` 2,176, `<=` 553, `!=` 38. No `==` and no `?=`.
* **The question mark.** Stellaris writes "if this scope exists" as a `?` at the end of the scope
  key: `owner? = { ... }` (2,968 keys: `owner?`, `colony?`, `solar_system?`, `from.starbase?`,
  `event_target:x.leader?`, `$SCOPE$?` ...). So `?` is a word byte; `?=` (the Jomini operator) is
  an operator only where a token starts: `owner ?= {` is `owner` `?=`, `owner?={` is `owner?` `=`.
* **Words.** A run of bytes other than blanks and `{ } = < > ! " # [ ]`. That covers numbers
  (`-1.5`, `+0.05`), dates (`2200.01.01`), scripted variables (`@tier1cost`, 34,559 words),
  parameters (`$PARAM$`, `$PARAM|default$`, `$P$_flag`: 4,194 words), scope chains and links
  (`event_target:x`, `root.owner.capital_scope`, `scope:x`, `trigger:planet_stability`),
  script values with arguments (`value:scripted_modifier_mult|MODIFIER|pop_job_amenities_mult|`),
  inline script paths (`script = jobs/soldiers_add`, 5,173 words with `/`), and names with
  apostrophes (`Ni'amh`). In the secondary corpus also `100%`, `alpha=255.000,alpha_fade` (particle
  curves: the value is the word `255.000,alpha_fade`) and one stray `;` after a string in a .gui.
* **Inline math.** `@[` or `@\[` starts it and the matching `]` ends it; it is one token with its
  brackets: `@[ count * 2 ]`, `@\[ ( 72 * $PROGRESS$ ) ]`, `@\[ | 1 - $X$ | / 2 ]`. 52 `@[` and 22
  `@\[` in the primary corpus. `@\[` is the form for scripted effects and triggers (the backslash
  keeps the math from being evaluated before `$PARAM$` is substituted), so an interpreter treats
  both the same after substitution.
* **Parameter blocks.** `[[NAME]` ... `]` and `[[!NAME]` ... `]` in scripted effects, triggers and
  script values: the entries inside are used when the parameter is given (or, with `!`, not given).
  53 in the primary corpus (15 negated), always where an entry can stand, never one inside
  another (the parser allows that).
* **Typed blocks.** A word followed by a block: `color = hsv { 0.5 0.2 0.8 }` (hsv 183, rgb 309 in
  the primary corpus). In a list, only a colour tag (`rgb`, `hsv`, `hsv360`, `hex`) starts a typed
  block: `colors = { rgb { 1 2 3 } ... }` in `common/colors`; any other word before a block there
  is a key missing its `=` (see the tolerances).
* **Scripted variables** `@name = value` are ordinary statements; in 4.5.2 they are only defined at
  the top level of a file (4,140 definitions).
* Blocks can nest 16 deep (primary corpus) and can mix statements and bare values: `optimize_memory`
  at the start of scripted effects, `$TRIGGER$` as a whole entry in inline scripts,
  `prerequisites = { tech_a OR = { ... } }`. Files can hold top-level anonymous blocks
  (`common/gamesetup_settings`) and top-level lists (`common/*_tags/00_tags.txt`).

## Tolerances

Some vanilla files are malformed and the game still loads them. `parse` reads these the way the
game does and records `{ kind, line, col, message }` in `tree.warnings`; anything else that does
not fit the rules above is an error.

| kind | what | read as | vanilla 4.5.2 |
|---|---|---|---|
| `missing_operator` | `key { ... }` where key is not a colour tag | `key = { ... }` | `common/named_colors/01_trait_colors.txt:65` (`trait_bg_active_glow {`); 54 in .gui/.gfx/.asset (`position {`, `spriteType {`, `rotation {0 0 0}`) |
| `missing_close` | the file ends inside blocks | closed at the end | `gfx/models/effects/nomads.gfx`, `gfx/models/ui/nomads_frontend.gfx` |
| `extra_close` | a `}` at the top level | skipped | none; accepted because it is the most common mistake in mods (the game's reader reads on after it: `oracle/reader_cases.lua`, `end.extra_close`) |
| `bracket_word` | `[` or `]` outside a parameter block | a byte of a word, as the game's lexer reads it | none; 2.8's `common/special_projects/00_projects.txt` (`log = [fromfrom.GetName]`, 9 times) |
| `stray_operator` | an operator where a key should be | skipped; a `}` right after it does not close its block, the game's reader has read it | none; 2.2 to 2.5's `common/name_lists/HUMAN1_SC.txt` (`ion_cannon = { = {`) |

Not tolerated (errors, none in vanilla of any version): a lone `!`, a `[` inside a parameter
block that does not start one, an operator with no value (`a = = b`, `key = { b = }`), a `}`
inside a parameter block, and an unclosed string, inline math or parameter block.

Every vanilla corpus archived parses with 0 errors: the 70 GOG versions from 2.1.4.4 to 3.10.4
(`common`, `events`, `map`, ... of each) and 4.5.2. The game's own readers, of every version, are
in [oracle/README.md](oracle/README.md).

Oddities that parse without a warning, because the syntax allows them:

* `common/edicts/99_README_EDICTS.txt` is read by the game as an edicts file but has prose lines
  without `#`: they are 31 bare words at the top level ("Special variables for Edicts (Country and
  Empire):").
* `common/HOW_TO_MAKE_NEW_SHIPS.txt` is prose (with `<gfx_culture>_...`), not script, and the game
  does not load it: `parse_all` skips it.
* `common/inline_scripts/traditions/tr_purity_imperfection_remediation_wilderness` has no `.txt`,
  unlike the inline script name that refers to it; it is outside the corpus.
* The secondary corpus' `,` and `;` (above) are parts of words.

## Results (Stellaris 4.5.2, Steam)

| corpus | files | bytes | entries | parse time | errors | warnings |
|---|---|---|---|---|---|---|
| primary: common, events, map/setup_scenarios, prescripted_countries, flags (`*.txt`) | 2,274 | 34,087,510 | 1,181,195 | 1.4 to 2.3 s | 0 | 1 `missing_operator` |
| secondary: interface, gfx (`*.gui`, `*.gfx`, `*.asset`) | 2,097 | 20,271,189 | 964,360 | 0.8 to 1.6 s | 0 | 54 `missing_operator`, 2 `missing_close` |
| all | 4,371 | 54,358,699 | 2,145,555 | 2.3 to 3.4 s (15 to 23 MB/s) | 0 | 57 |

Entries count every statement, bare value, block in a list and parameter block at every depth.
Times are LuaJIT 2.1 on a desktop, over several runs; the round trip of every file (write, parse
again, compare) gives the same tree for all 4,371 files.

Primary corpus: 1,115,123 statements, 65,098 bare values, 921 blocks in lists, 53 parameter
blocks; keys 1,114,619 bare and 504 quoted (`"CHANCE" = @\[...]`, `"north" = { ... }`); token
values 636,559 bare (74 inline math) and 91,256 quoted, and 452,406 block values. The most common
keys: trigger 27,671, name 25,840, modifier 24,932, id 20,356, owner 19,637, limit 19,037, NOT
16,208, desc 14,781, factor 13,595, option 13,527.

## License

MIT, see [LICENSE.txt](LICENSE.txt).
