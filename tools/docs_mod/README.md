# make_docs_mod.lua

Builds a Stellaris mod that uses, once each and where the game accepts it, every keyword of the
game's own script documentation: every trigger, effect, scope link, modifier and localisation
command. It is a coverage corpus for comparing a reading of the script with what the game
compiled: when the game loads the mod, each documented keyword is compiled at a known file and
line, and the mod's `manifest.tsv` says which. Nothing in the mod fires.

```
cd tools/docs_mod
luajit make_docs_mod.lua "<documentation dir>" "<Stellaris dir>" "<output dir>" [review file]
```

* `<documentation dir>`: what the game writes when it starts, in
  `Documents/Paradox Interactive/Stellaris/logs/script_documentation` (`triggers.log`,
  `effects.log`, `scopes.log`, `modifiers.log`, `localizations.log`). The game empties these
  files when it starts and writes them a few minutes later: copy them first if the game may run.
* `<Stellaris dir>`: the game, for vanilla examples and object names (`common/`, `events/`) and
  the version (`launcher-settings.json`).
* `<output dir>`: the mod, written there; its launcher descriptor goes next to it,
  `<output dir>.mod`. Nothing is installed or enabled.
* `[review file]`: optional, every trigger and effect use with how it was made.

On Windows, run it from this directory with the short relative script path (LuaJIT fails on
long script paths). It reads `pdxscript.lua` from the repository root. A run takes a few seconds,
writes sorted output (a rerun on the same input writes the same files), checks that every
script file it wrote parses with no warning, that every manifest line holds its keyword and that
every documented item has a row, prints the counts per kind, and exits with 1 if a check fails.

## The mod

| file | holds |
|---|---|
| `events/sdc_triggers.txt` | every trigger, in the `trigger` block of events grouped by scope, 50 a time |
| `events/sdc_effects.txt` | every effect, in the `immediate` block of events grouped by scope |
| `events/sdc_links.txt` | every scope link as a scope change (`owner = { always = yes }`), and dotted chains |
| `events/sdc_anchors.txt` | `sdc.1`, the main event (localisation, desc triggers, scripted calls), and one event per event type for the `*_event` effects |
| `events/sdc_control_flow.txt` | AND/OR/NOT/NOR/NAND, if/else_if/else, while, random_list, switch, iterators as vanilla writes them |
| `common/scripted_triggers`, `common/scripted_effects` | scripted triggers and effects with `$PARAM$`, `$PARAM\|default$`, `[[PARAM]` blocks, `optimize_memory`, inline math |
| `common/static_modifiers/sdc_static_modifiers.txt` | every modifier, in one static modifier per category of `modifiers.log` |
| `localisation/english/sdc_l_english.yml` | every localisation command, one key each, all shown by the desc of `sdc.1` |
| `manifest.tsv` | one row per documented item: kind, name, file, line, scope, status (placed or skipped: reason), source |

Every event is `is_triggered_only = yes` with `trigger = { always = no }` and nothing calls it.
A scope with an event type (country, planet, colony, fleet, ship, pop group, leader, system,
starbase, pop faction, first contact, situation, espionage operation, astral rift, bypass,
agreement) gets events of that type; the others are reached by a scope link or an iterator from
one of them (species, federation, sector, deposit ... in `REACH`).

## How a use is made

The first that works:

1. an entry of `OVERRIDES` in the script, for what the other ways get wrong (about 60);
2. the documentation's example, its placeholders filled with what vanilla writes for the same
   keyword and parameter, an object of the right kind from vanilla, or the mod's own names
   (`sdc_flag`, `sdc_var`, `sdc_text`, `from` for targets, `always = yes` for triggers,
   `log = "sdc"` for effects);
3. the shortest use of the keyword in vanilla (in a trigger or effect block as it should be).

A use must parse, and every word the example names must be known to vanilla (a value written
after the same key, an object, a scope, a number) or be one of the choices it lists. The manifest's
`source` column says which way was used (`docs`, `override`, `vanilla <file>:<line>`, and for
links `scope change`).

Skipped, with the reason in the manifest: what the documentation calls deprecated, debug-only
keywords, keywords whose only scope nothing reaches (pop, dlc_recommendation), the two effects
that fire cosmic storm events (vanilla has no such event), and the localisation sections of
objects only special localisation has (dead objects, timeline events, patron relations,
specimens).
