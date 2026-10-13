# The start of the game: InitGame and the databases

`gameinit.lua` reads, from a build's own code, what `CGameApplication::InitGame` does and the
table of game databases it sets up: their names, their order in the table, what each one's
`CanInitialize` waits for, and the order the game's loop then initializes them in. It works on
the 50 Linux builds with symbols, 1.0.0 to 4.5.2.

```
luajit tools/oracle_initrun.lua <stellaris executable> out.tsv     # one build (5 to 7 seconds)
luajit tools/oracle_initreport.lua <dir of .tsv> [--full]          # the builds compared
```

`oracle_initrun.lua` demangles with `c++filt` when it is on the path.

## How it works

**Isolated runs.** A function of the game runs alone: its own code runs, and every other
function of the game it reaches (by a direct call, an indirect call, a tail jump) returns at once,
from a basic block hook that sets the return value, pops the return address and moves the
program counter. Each such call is recorded. The value returned is the null object: a 64 KB page
whose every word is its own address. Read as a pointer it is an object, its fields and its vtable
are the page, and a virtual call on it lands in the page and returns at once too. Read as a 32-bit
integer or a bool on x86-64 it is 0 (the page is at 2^32). The first 64 KB of the address space
are mapped the same way, so a field read through a null global reads the null object. Imports run
(`hle.lua`); the unknown ones return 0.

**InitGame's steps.** Two lists, merged by call site in address order:

- static: every `call rel32` (e8) and `jmp rel32` (e9) in InitGame's bytes whose target is the
  start of a function or a PLT entry (a byte scan, not a disassembly: an e8 inside another
  instruction counts only if it lands exactly on a function's start);
- dynamic: InitGame run isolated, `this` an object of zeros. It gives the indirect calls (the
  null objects' `Allocate` and `Initialize` from a table on the stack, std::function managers)
  and which static calls are on its path. The path is one path: on x86-64 every test of a
  callee's bool or int result sees 0 and every pointer is valid (on i386 the null object is at
  0x100000, so an int is not 0 there).

Address order is the order of the source near enough; it is not the order of a loop's iterations.

**The table.** The function that builds it (InitGame up to 4.0, `SetupDatabases` from 4.1) runs
isolated. At each call it makes, the stack is searched for an array of records whose fields point
to functions named `...::CreateInstance()`. The longest run at one stride is the table; the name
field is the word that points to a C string in every record; each other field's role is the name
its symbols end in (`CreateInstance`, `DestroyInstance`, `CanInitialize`, `InitInstance`,
`PostReadInitInstance`). Nothing about the layout is written in the code:

| versions | built in | record | fields after the name |
|---|---|---|---|
| 1.0.0 to 1.2.5 | `CGameApplication::InitGame` | 20 bytes | Create, CanInitialize, Init, PostRead |
| 2.3.0 to 2.5.0 | `CGameApplication::InitGame` | 40 bytes | Create, CanInitialize, Init, PostRead |
| 3.12.5 to 4.0.23 | `CGameApplication::InitGame` | 48 bytes | Create, Destroy, CanInitialize, Init, PostRead |
| 4.1.7 to 4.5.2 | `NNullObjAndDatabaseInitUtil::SetupDatabases` | 48 bytes | Create, Destroy, CanInitialize, Init, PostRead |

**The dependencies.** Each `CanInitialize` of the table runs with a read hook
(`engine:hook("read", ...)`) on the executable's writable segments. A global it reads that is zero is set (a pointer to the null object, or 1) and
the function runs again, until it reads nothing new: so `a && b && c` reads all three. The globals
are named by the symbol table. A global belongs to a database when its mangled name has the
database's class (`TGameDatabase<CFoo>::_pInstance`, `CFoo::_pInstance`, a static of
`CFoo::GetInstance()`): the class is the name in the table or the one `CreateInstance` belongs to.
A global of no database is `other`; of a class with a `CreateInstance` outside the table,
`external`. Reads through an accessor function count (`CGfxCultureDatabase::GetInstance()`).

**The order.** The game's loop, simulated: the first database left whose dependencies are done
is initialized, and the search starts again from the first. A database waits when it is
initialized after one that is later in the table (the loop passed it: its `CanInitialize` was
false).

### Checked

- 4.5.2: 198 databases, 126 with a `CanInitialize`, 178 with a `PostReadInitInstance`, as in
  stellarstellaris-win's `docs/loading.md` (the Windows build). The simulated order is the order
  the game's own loop made on Windows 4.5.2 (the `cache/database_order-<md5>.tsv` a load of
  stellarstellaris-win kept), all 198 the same.
- The number of records is the count in the code of every era (`mov eax, 0x45` in 1.0.0, the
  `memcpy` of 0xff0 = 102 × 40 bytes in 2.3.0, `InsertAt(…, 0xc6)` in 4.5.2, and so on).
- 4.5.2: the globals each `CanInitialize` reads are the data symbols its disassembly names, plus
  those read through an accessor (7, seen only by the run). One `CanInitialize` the disassembly
  has is not in the table (`CSectorTypeDatabase`'s: its entry is null).
- In every build every `CanInitialize` returns true once the globals it reads are set, and no
  database is left waiting at the end.

### Limits

- InitGame's dynamic path is one path. A step on another path is in the static list (marked `?`
  in the report) unless it is an indirect call.
- A `CanInitialize` that tested an object's state (a field, not a global) would show only the
  global. None in these builds needed more than the globals.
- The simulation takes a database's instance as set once it is initialized, and an `other` global
  as set (the one there is, `CGui::_pGui`, is set before InitGame).
- The report compares InitGame's steps by name without parameters; repeated keys (two
  `CTriggerDatabase::CreateInstance`) are compared in order. The plumbing (strings, log, arrays,
  destructors, imports, std::function managers, the profiler) is left out.

## Results: 50 builds

All 50 run (15 to 60 seconds on 24 workers, the files on a network share). Builds with the same
results are one row:

| versions | databases | CanInitialize | PostRead | dependencies (on databases) | wait |
|---|---|---|---|---|---|
| 1.0.0 to 1.1.0 | 69 | 26 | 35 | 17 | 8 |
| 1.2.0 to 1.2.5 | 71 | 26 | 35 | 17 | 8 |
| 2.3.0 to 2.5.0 | 102 | 46 | 69 | 50 | 9 |
| 3.12.5 | 163 | 91 | 123 | 117 | 34 |
| 3.13.2 | 165 | 91 | 125 | 117 | 34 |
| 3.14.1 | 168 | 96 | 129 | 121 | 38 |
| 4.0.23 | 181 | 107 | 136 | 138 | 49 |
| 4.1.7 | 186 | 111 | 141 | 138 | 49 |
| 4.2.4 to 4.3.7 | 187 | 112 | 142 | 139 | 49 |
| 4.4.1 to 4.4.6 | 196 | 125 | 176 | 164 | 55 |
| 4.5.1 to 4.5.2 | 198 | 126 | 178 | 165 | 55 |

One dependency is on no database: `CCouncilAgendaDatabase` reads `CGui::_pGui` (3.12.5 on). No
`CanInitialize` reads a database outside the table.

### The databases

| from | added | removed | notes |
|---|---|---|---|
| 1.2.0 | 2 | | `CMapModeDatabase`, `CButtonEffectDatabase` |
| 2.3.0 | 43 | 12 | the tiles, armies' attachments, war demands, spaceport modules, buildable pops go; jobs, districts, deposits, traditions, starbases, megastructures, archaeology come; 8 move in the table |
| 3.12.5 | 66 | 5 | `CNamedColorDatabase` first; subjects, species rights, agendas, mandates, sector focuses go |
| 3.13.2 | 2 | | |
| 3.14.1 | 3 | | `CShipCategoryDatabase`, `CSpecimenDatabase`, `CMutationDatabase` |
| 4.0.23 | 15 | 2 | zones, district zone slots, ship sets, country focus cards, timeline events |
| 4.1.7 | 5 | | `CLeaderTierDatabase`, `CPsionicAuraTypeDatabase`, three of the patrons |
| 4.2.4 | 1 | | `COverclockTypeDatabase` |
| 4.4.1 | 9 | | `CSituationLogCategoryDatabase`, the technology categories and tiers, `CScriptedActionDatabase`, `CResourceConverterDatabase` |
| 4.5.1 | 2 | | `CResourceRegionDatabase`, `CPolicyCategoriesDatabase`; `CEthicCategoryDatabase` moves |

The first in the table: `CWeaponTagDatabase` (1.x), `CAsteroidBeltTypeDatabase` (2.x),
`CNamedColorDatabase` (3.12.5 on).

### Dependencies that change

| database | change |
|---|---|
| `CStaticModifierDatabase` | waits for `CCountryTypeDatabase` (1.x); also `CEthic`, `CDistrictType`, `CBuildingType` (2.x); also `CPopCategory`, `CEconomicCategory`, `CBypassType` (3.12.5 to 3.14.1); no `CanInitialize` from 4.0.23, where InitGame calls `CStaticModifierDatabase::Init` after the databases |
| `CShipSizeDatabase` | `CGfxCulture`, `CStrategicResource` (1.x); + `CEconomicCategory` (2.3.0); + `CShipCategory` (3.14.1); + `CTechnology` (4.0.23); + `CPlanetClass` (4.4.1) |
| `CEventManager` | no `CanInitialize` before 4.0.23; then `CTimelineEventDefinition`, + `CEventChain` (4.4.1) |
| `CGovernmentTypeDatabase` | waits for `CPopFactionType` in 1.x; no `CanInitialize` from 2.3.0 |
| `CCountryTypeDatabase` | `CShipSize`, `CArmyType`; + `COwnershipLimits` (3.12.5); + `CResourceConverter` (4.4.1), the last of the table, so it is the last initialized from 4.4.1 |
| 4.4.1 | `CanInitialize` added to `CEventChain`, `CStarClass`, `CNameList`, `CSpecialProject`, `CTerraform`, `CSystemInitializer`, `CMission` |

`tools/oracle_initreport.lua` lists every change.

### The order

The databases that wait (the loop passes them and comes back): 8 of 69 in 1.0.0 (`CShipSize`,
`CCountryType`, `CStaticModifier`, ...), 9 of 102 in 2.x, 34 of 163 in 3.12.5, 49 of 181 in
4.0.23, 55 of 198 in 4.5.2. In 4.x the long chains are the ships (`CPlanetClass` ->
`CShipCategory` -> `CGfxCulture` -> `CShipSize` -> ...), the species rights (citizenship, living
standards, purges, ...) that wait for `CResolutionTypeDatabase`, and what waits for `CEventManager`
(itself late from 4.0.23, when it waits for `CTimelineEventDefinitionDatabase`).

### InitGame

Its steps without the plumbing, in address order (1.0.0 has 42, 4.5.2 68):

| step | versions |
|---|---|
| `CGlobalScriptedVariablesDatabase::InitializeWithDirectory` (first) | 2.3.0 on |
| `CSyncedLocalization::LoadDataFromDirectory` | 2.3.0 to 2.5.0 |
| `CInlineScriptDatabase::CreateInstance`, `CEventManager::InitFiredEvents` | 3.12.5 on |
| `CModifier::InitDefinitions` | all |
| `CGfxUtil` made | 2.3.0 on |
| the null objects: `TPdxNullObject<…>::Allocate` and `Initialize` from a table, 134 (1.0.0), 170 (2.3.0), 252 (3.12.5), 298 (4.0.23), 323 (4.5.2) | all; in `NNullObjAndDatabaseInitUtil::SetupNullObjects` in 4.1.7 and 4.2.4 only |
| the database loop (progress: `LoadingScreenCallback`), the `PostReadInitInstance` of each, `CModifier::InitDefinitionIcons` (2.3.0 on) | inline to 4.0.23; `SetupDatabases` from 4.1.7 (progress through a lambda of InitGame); the deferred references (`CGlobalDeferredDatabaseObjectResolver::Run`) before the PostReads from 4.4.1 |
| `CEventManager::LogFiredEventErrors` | 1.x after the loop; 2.x after the effects; gone in 3.12.5 |
| `CGameRules::CreateInstance` (1.x), `new CGameRules` (2.3.0 on), `InitInstance` | all |
| a task: `CreateShortTask` (2.3.0 to 4.1.7), the task scheduler's `CreateTasks` with a lambda that calls `CApplication::UpdateOneFrame` (4.2.4 on) | 2.3.0 on |
| achievements (`achievements.txt` if it exists), `CalculateGameFilesChecksum`, `SetValidated` | all; `FillCrashReporterChecksumInfo` from 2.4.1 |
| `CStaticModifierDatabase::Init`, `CPostInitModifierDatabase::ProcessModifiers` | 4.0.23 on (`ProcessModifiers` from 3.12.5) |
| triggers and effects: `PostInit`, `PostValidate` | all |
| `CPostInitVariableValueDatabase::ProcessVariableValues` | 3.12.5 on (after the effects from 4.0.23) |
| `CEventManager::PostInit` | 3.12.5 on |
| `CModifier::LogDefinitions`, `DebugDefinitions` | all |
| `CEconomicCategoryDatabase::LogUnusedModifiers` | 2.3.0 on |
| `PrintScriptingDocumentation`, `CGameGraphics::ScriptedLogicInitialization` | 3.12.5 on |
| `ApplicationUtilsInit`, `ParticleEditorInit`, the console commands | all |
| the combat test idler (a debug path) or `CFrontEndIdler` | all |
| `NElasticLogging::TryCreateLogger`, a thread | 3.12.5 on (`ThreadCreateThread`, then `NThreads::CreateThread` in 4.2.4, none from 4.3.0) |

The interface and graphics phases (the first 9 seconds of the bar in 4.5.2) are not in InitGame.
