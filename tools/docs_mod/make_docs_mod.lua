-- make_docs_mod.lua : builds a Stellaris mod that uses every keyword the game's own script
-- documentation lists, once each and where the game accepts it: every trigger, effect, scope
-- link, modifier and localisation command. The mod is a coverage corpus: when the game loads it,
-- each keyword is compiled at a known file and line, which the mod's manifest.tsv lists.
--
-- Usage: luajit make_docs_mod.lua <documentation dir> <game dir> <output dir> [review file]
--
-- The documentation dir is what the game writes when it starts, to Documents/Paradox
-- Interactive/Stellaris/logs/script_documentation (triggers.log, effects.log, scopes.log,
-- modifiers.log, localizations.log). The game dir gives real examples and object names (vanilla
-- common/ and events/) and the version for the descriptor. The mod goes to the output dir, its
-- launcher descriptor next to it (<output dir>.mod). The optional review file lists every use
-- with how it was made. The output is sorted, so a rerun on the same input writes the same files.
--
-- How a trigger or effect is used, the first way that works:
--   1. an entry of OVERRIDES (below), for what the other ways get wrong;
--   2. the documentation's own example, with its placeholders (<target>, <key>, <int> ...)
--      filled with a value vanilla writes for the same keyword and parameter, an object of the
--      right kind from vanilla, or one of the mod's own names (sdc_flag, sdc_var, sdc_text);
--   3. the shortest use of the keyword in vanilla, in a trigger or effect block as it should be.
-- A use must parse, and every word the example names must be known: vanilla writes it after the
-- same key, or it is a vanilla object, a scope, a number, a value the example lists as one of
-- its choices (yes/no) or one of the mod's names. Keywords that cannot be placed (deprecated,
-- debug-only, a scope nothing reaches) are listed in the manifest with the reason.
--
-- Nothing in the mod fires: every event is is_triggered_only with trigger = { always = no } and
-- nothing calls the events; the scripted triggers and effects are only called from them, and
-- nothing applies the static modifiers.

local doc_dir, game_dir, out_dir, review_path = arg[1], arg[2], arg[3], arg[4]
if out_dir == nil then
    io.stderr:write("usage: luajit make_docs_mod.lua <documentation dir> <game dir> "
        .. "<output dir> [review file]\n")
    os.exit(2)
end
local here = (arg[0]:match("^(.*)[/\\]") or ".")
package.path = here .. "/../../?.lua;" .. here .. "/?.lua;" .. package.path

local pdxscript = require("pdxscript")

local windows = package.config:sub(1, 1) == "\\"
local NAMESPACE = "sdc"
local MOD_NAME = "Stellar Docs Coverage"
local PER_EVENT = 50 -- keywords per event

---------------------------------------------------------------------------------------------------
-- Files

local function read_file(path)
    local f = io.open(path, "rb")
    if f == nil then
        return nil
    end
    local text = f:read("*a")
    f:close()
    return (text:gsub("\r\n", "\n"))
end

local function make_dir(path)
    if windows then
        os.execute('mkdir "' .. path:gsub("/", "\\") .. '" 2>nul')
    else
        os.execute("mkdir -p '" .. path .. "'")
    end
end

local function write_file(path, text)
    make_dir(path:match("^(.*)[/\\]"))
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
end

-- The absolute form of an existing directory, with forward slashes.
local function absolute(dir)
    local p
    if windows then
        p = io.popen('cd /d "' .. dir:gsub("/", "\\") .. '" 2>nul && cd')
    else
        p = io.popen("cd '" .. dir .. "' 2>/dev/null && pwd")
    end
    local path = p and p:read("*l")
    if p then
        p:close()
    end
    if path == nil or path == "" then
        return nil
    end
    return (path:gsub("\\", "/"):gsub("/+$", ""))
end

-- The files under base/dir (recursive) with the extension, relative to base with forward
-- slashes, sorted.
local function list_files(base, dir, extension)
    local path = base .. "/" .. dir
    local command
    if windows then
        command = 'dir /s /b /a-d "' .. path:gsub("/", "\\") .. "\\*." .. extension .. '" 2>nul'
    else
        command = "find '" .. path .. "' -type f -name '*." .. extension .. "' 2>/dev/null"
    end
    local files = {}
    local p = assert(io.popen(command))
    for line in p:lines() do
        local name = line:gsub("\\", "/"):sub(#base + 2)
        if name:sub(-#extension - 1):lower() == "." .. extension then
            files[#files + 1] = name
        end
    end
    p:close()
    table.sort(files)
    return files
end

local function sorted_keys(t)
    local keys = {}
    for k in pairs(t) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    return keys
end

local function words(s)
    local list = {}
    for w in s:gmatch("%S+") do
        list[#list + 1] = w
    end
    return list
end

local function set_of(list)
    local set = {}
    for _, v in ipairs(list) do
        set[v] = true
    end
    return set
end

---------------------------------------------------------------------------------------------------
-- The documentation

-- An entry of triggers.log, effects.log or scopes.log is a paragraph that starts after a blank
-- line:
--   name - description
--   <syntax lines, optional; may contain blank lines>
--   Supported Scopes: country ship fleet      (or "all")
--   Output Scope: planet                      (scopes.log only)
-- Returns the entries in file order and the number of names written twice (kept once).
local function read_entries(path)
    local text = assert(read_file(path), "cannot read " .. path)
    local body = text:match("DOCUMENTATION ==\n(.*)$") or text
    local list, seen, duplicates = {}, {}, 0
    local current, blank = nil, true
    for line in (body .. "\n"):gmatch("([^\n]*)\n") do
        local name, description = line:match("^([%w_]+) %- (.*)$")
        if name and blank then
            current = { name = name, description = description, syntax = {} }
            if seen[name] then
                duplicates = duplicates + 1
            else
                seen[name] = true
                list[#list + 1] = current
            end
        elseif line:match("^=+$") then
            current = nil
        elseif current then
            local scopes = line:match("^Supported Scopes:%s*(.*)$")
            local output = line:match("^Output Scope:%s*(.*)$")
            if scopes then
                current.scopes = words(scopes)
            elseif output then
                current.output = output
            elseif current.scopes == nil then
                current.syntax[#current.syntax + 1] = line
            end
        end
        blank = line == ""
    end
    for _, e in ipairs(list) do
        e.syntax = table.concat(e.syntax, "\n"):gsub("%s+$", "")
        e.scopes = e.scopes or {}
    end
    return list, duplicates
end

-- modifiers.log: "- name, Category: Pops, AI Economy" lines.
local function read_modifiers(path)
    local text = assert(read_file(path), "cannot read " .. path)
    local list, seen, duplicates = {}, {}, 0
    for name, category in text:gmatch("\n%- ([^,\n]+), Category: ([^\n]*)") do
        if seen[name] then
            duplicates = duplicates + 1
        else
            seen[name] = true
            list[#list + 1] = { name = name, category = category }
        end
    end
    return list, duplicates
end

-- localizations.log: "--Section--" headers, then "Promotions:" and "Properties" with one command
-- per line (indented by a space). The header names a few unscoped commands in a sentence.
local function read_localizations(path)
    local text = assert(read_file(path), "cannot read " .. path)
    local list = {}
    local unscoped = text:match("several unscoped commands: ([^\n]-)%.?\n")
    for name in (unscoped or ""):gmatch("[%w_]+") do
        list[#list + 1] = { section = "Unscoped", kind = "property", name = name }
    end
    local section, part
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        local s = line:match("^%-%-(.-)%-%-$")
        if s then
            section, part = s, nil
        elseif line:match("^Promotions:?$") then
            part = "promotion"
        elseif line:match("^Properties:?$") then
            part = "property"
        elseif section and part and line:match("^ %S") then
            list[#list + 1] = { section = section, kind = part, name = line:match("^ (%S+)") }
        elseif line:match("^=+$") then
            section = nil
        end
    end
    return list
end

-- The game empties the files when it starts and writes them a few minutes later.
for _, name in ipairs({ "triggers", "effects", "scopes", "modifiers", "localizations" }) do
    local text = read_file(doc_dir .. "/" .. name .. ".log")
    if text == nil or not text:find("DOCUMENTATION ==", 1, true) then
        io.stderr:write("make_docs_mod: " .. doc_dir .. "/" .. name .. ".log is missing or "
            .. "empty (the game writes it while it starts; wait for it, or copy the files "
            .. "somewhere first)\n")
        os.exit(2)
    end
end

local docs = {}
docs.triggers, docs.trigger_duplicates = read_entries(doc_dir .. "/triggers.log")
docs.effects, docs.effect_duplicates = read_entries(doc_dir .. "/effects.log")
docs.links, docs.link_duplicates = read_entries(doc_dir .. "/scopes.log")
docs.modifiers, docs.modifier_duplicates = read_modifiers(doc_dir .. "/modifiers.log")
docs.localizations = read_localizations(doc_dir .. "/localizations.log")

local by_kind = { trigger = {}, effect = {}, link = {} }
for _, e in ipairs(docs.triggers) do
    by_kind.trigger[e.name] = e
end
for _, e in ipairs(docs.effects) do
    by_kind.effect[e.name] = e
end
for _, e in ipairs(docs.links) do
    by_kind.link[e.name] = e
end

---------------------------------------------------------------------------------------------------
-- Vanilla: words, objects, and uses of the documented keywords

local vanilla = {
    words = {},      -- every key and value written anywhere
    key_values = {}, -- key -> set of the values written after it
    key_counts = {}, -- key -> value -> how many times
    value_words = {},-- every value written anywhere
    objects = {},    -- directory under common/ -> sorted top-level block keys of its files
    is_object = {},  -- top-level block key of any common/ directory -> true
    uses = { trigger = {}, effect = {} },   -- name -> list of { file, line, node, vars }
    values = { trigger = {}, effect = {} }, -- name -> path -> value -> count
    variables = {},  -- @name -> value, from common/scripted_variables
}

-- Keys whose block holds triggers or effects, to tell in which a vanilla use is. A use with
-- neither above it is not counted (it is likely a property with the same name).
local TRIGGER_BLOCKS = set_of({ "trigger", "limit", "potential", "allow", "possible",
    "is_valid", "condition", "pre_triggers", "can_start", "active", "valid", "show_in_tooltip",
    "can_end", "visible", "prerequisites_trigger", "shown", "available", "fail_triggers",
    "abort_trigger", "can_activate", "happened", "requirements", "has_trait_in_council",
    "triggered_condition", "is_unique", "can_be_picked", "ai_will_do", "weight", "modifier" })
local EFFECT_BLOCKS = set_of({ "immediate", "option", "effect", "after", "on_success",
    "on_fail", "on_enabled", "on_disabled", "on_start", "on_end", "on_activate", "on_complete",
    "on_abort", "on_queued", "on_unqueued", "on_built", "on_destroy", "on_enact", "on_repeal",
    "on_gain", "on_loss", "fail_effects", "init_effect", "on_fire", "on_cleared",
    "hidden_effect", "on_finish", "on_monthly", "on_yearly", "on_first_enter", "on_enter",
    "on_leave", "on_select", "on_unselect", "on_create", "on_roll_failed", "on_spawn" })

local function context_of(stack, file)
    for i = #stack, 1, -1 do
        local k = stack[i]
        if TRIGGER_BLOCKS[k] then
            return "trigger"
        elseif EFFECT_BLOCKS[k] then
            return "effect"
        elseif by_kind.trigger[k] and not by_kind.effect[k] then
            return "trigger"
        elseif by_kind.effect[k] and not by_kind.trigger[k] then
            return "effect"
        end
    end
    if file:find("^common/scripted_triggers/") then
        return "trigger"
    elseif file:find("^common/scripted_effects/") then
        return "effect"
    elseif #stack < 2 then
        return nil -- a property of a top-level object, not a trigger or effect
    end
    return "either"
end

-- A token is clean when it does not depend on where it is written: no parameter, no scripted
-- variable that cannot be resolved, no inline math.
local function clean_text(text, vars)
    if text:find("$", 1, true) or text:find("[", 1, true) then
        return nil
    end
    if text:sub(1, 1) == "@" then
        local v = vars and vars[text] or vanilla.variables[text]
        if v == nil or v:find("[%$@%[]") then
            return nil
        end
        return v
    end
    return text
end

-- Records the values a use writes, by path below the keyword ("" for its own value).
local function record_values(kind, name, node, vars)
    local per_name = vanilla.values[kind][name] or {}
    vanilla.values[kind][name] = per_name
    local function add(path, text)
        local v = clean_text(text, vars)
        if v then
            local t = per_name[path] or {}
            per_name[path] = t
            t[v] = (t[v] or 0) + 1
        end
    end
    local function walk(block, prefix)
        for _, e in ipairs(block) do
            if e.op then
                local path = prefix == "" and e.key.text or prefix .. "." .. e.key.text
                if e.value.text then
                    add(path, e.value.text)
                else
                    walk(e.value, path)
                end
            end
        end
    end
    if node.value.text then
        add("", node.value.text)
    else
        walk(node.value, "")
    end
end

local function index_vanilla()
    local files = list_files(game_dir, "common", "txt")
    for _, f in ipairs(list_files(game_dir, "events", "txt")) do
        files[#files + 1] = f
    end
    local trees = {}
    for _, f in ipairs(files) do
        if f ~= "common/HOW_TO_MAKE_NEW_SHIPS.txt" then
            trees[f] = pdxscript.parse(read_file(game_dir .. "/" .. f) or "", f)
        end
    end
    -- global scripted variables first
    for _, f in ipairs(files) do
        if f:find("^common/scripted_variables/") and trees[f] then
            for _, e in ipairs(trees[f]) do
                if e.op and e.value.text and e.key.text:sub(1, 1) == "@" then
                    vanilla.variables[e.key.text] = e.value.text
                end
            end
        end
    end
    for _, f in ipairs(files) do
        local tree = trees[f]
        if tree then
            local vars = {}
            local dir = f:match("^common/(.+)/[^/]+$")
            for _, e in ipairs(tree) do
                if e.op and e.value.text and e.key.text:sub(1, 1) == "@" then
                    vars[e.key.text] = e.value.text
                elseif e.op and not e.value.text and dir and e.key.text:sub(1, 1) ~= "@" then
                    vanilla.objects[dir] = vanilla.objects[dir] or {}
                    vanilla.objects[dir][e.key.text] = true
                    vanilla.is_object[e.key.text] = true
                end
            end
            local stack = {}
            local function walk(block)
                for _, e in ipairs(block) do
                    if e.op then
                        local k = e.key.text
                        vanilla.words[k] = true
                        if e.value.text then
                            local v = e.value.text
                            vanilla.words[v] = true
                            vanilla.value_words[v] = true
                            local kv = vanilla.key_values[k] or {}
                            vanilla.key_values[k] = kv
                            kv[v] = true
                            local kc = vanilla.key_counts[k] or {}
                            vanilla.key_counts[k] = kc
                            kc[v] = (kc[v] or 0) + 1
                        end
                        if by_kind.trigger[k] or by_kind.effect[k] then
                            local kind = context_of(stack, f)
                            if kind == "either" then
                                -- deep in an unknown block: what the keyword alone says
                                kind = not by_kind.effect[k] and "trigger"
                                    or not by_kind.trigger[k] and "effect" or nil
                            end
                            if kind and by_kind[kind][k] then
                                local list = vanilla.uses[kind][k] or {}
                                vanilla.uses[kind][k] = list
                                list[#list + 1] = { file = f, line = e.line, node = e, vars = vars }
                                record_values(kind, k, e, vars)
                            end
                        end
                        if not e.value.text then
                            stack[#stack + 1] = k
                            walk(e.value)
                            stack[#stack] = nil
                        end
                    elseif e.text then
                        vanilla.words[e.text] = true
                        vanilla.value_words[e.text] = true
                    else
                        walk(e)
                    end
                end
            end
            walk(tree)
        end
    end
    for dir, set in pairs(vanilla.objects) do
        vanilla.objects[dir] = sorted_keys(set)
    end
end

index_vanilla()

local function game_version()
    local text = read_file(game_dir .. "/launcher-settings.json") or ""
    return text:match('"rawVersion"%s*:%s*"([^"]+)"') or "v4.5.2"
end

---------------------------------------------------------------------------------------------------
-- Scopes: the event types, and how to reach the scopes that have none

-- The event types, by the scope of their root, in the order the mod writes them.
local EVENT_TYPES = {
    { "country", "country_event" }, { "planet", "planet_event" }, { "colony", "colony_event" },
    { "fleet", "fleet_event" }, { "ship", "ship_event" }, { "pop_group", "pop_group_event" },
    { "leader", "leader_event" }, { "galactic_object", "system_event" },
    { "starbase", "starbase_event" }, { "pop_faction", "pop_faction_event" },
    { "first_contact", "first_contact_event" }, { "situation", "situation_event" },
    { "espionage_operation", "espionage_operation_event" },
    { "astral_rift", "astral_rift_event" }, { "bypass", "bypass_event" },
    { "agreement", "agreement_event" },
}
local EVENT_OF = {}
for _, t in ipairs(EVENT_TYPES) do
    EVENT_OF[t[1]] = t[2]
end

-- The other scopes: the root to start from and the steps from there. A step is a scope link
-- (written the same in triggers and effects) or an iterator ({ trigger form, effect form }),
-- with the scope it leads to.
local REACH = {
    species = { root = "country", steps = { { "species", "species", "species" } } },
    federation = { root = "country", steps = { { "federation", "federation", "federation" } } },
    war = { root = "country", steps = { { "any_war", "every_war", "war" } } },
    army = { root = "country", steps = { { "any_owned_army", "every_owned_army", "army" } } },
    megastructure = { root = "country",
        steps = { { "any_owned_megastructure", "every_owned_megastructure", "megastructure" } } },
    debris = { root = "country",
        steps = { { "any_available_debris", "every_available_debris", "debris" } } },
    cosmic_storm = { root = "country",
        steps = { { "any_cosmic_storm", "every_cosmic_storm", "cosmic_storm" } } },
    mission = { root = "country",
        steps = { { "any_owned_mission", "every_owned_mission", "mission" } } },
    exhibit = { root = "country", steps = { { "any_exhibit", "every_exhibit", "exhibit" } } },
    trait = { root = "country", steps = { { "species", "species", "species" },
        { "any_trait_of_species", "every_trait_of_species", "trait" } } },
    no_scope = { root = "country", steps = { { "no_scope", "no_scope", "no_scope" } } },
    sector = { root = "colony", steps = { { "sector", "sector", "sector" } } },
    job = { root = "colony", steps = { { "any_owned_pop_job", "every_owned_pop_job", "job" } } },
    deposit = { root = "planet",
        steps = { { "last_added_deposit", "last_added_deposit", "deposit" } } },
    archaeological_site = { root = "planet", steps = { { "archaeological_site",
        "archaeological_site", "archaeological_site" } } },
    ambient_object = { root = "galactic_object", steps = { { "any_system_ambient_object",
        "every_system_ambient_object", "ambient_object" } } },
    cosmic_storm_influence_field = { root = "galactic_object", steps = { {
        "storm_influence_field", "storm_influence_field", "cosmic_storm_influence_field" } } },
    spy_network = { root = "espionage_operation",
        steps = { { "spynetwork", "spynetwork", "spy_network" } } },
    espionage_asset = { root = "espionage_operation", steps = { { "any_espionage_asset",
        "every_espionage_asset", "espionage_asset" } } },
    design = { root = "ship", steps = { { "design", "design", "design" } } },
    ship_growth_stage = { root = "ship",
        steps = { { "ship_growth_stage", "ship_growth_stage", "ship_growth_stage" } } },
}

-- Scopes no event, link or iterator reaches.
local UNREACHABLE = {
    pop = "pop scope: no event type, scope link or iterator leads to a pop (4.x has pop groups)",
    galactic_community = "galactic_community scope: no event type, scope link or iterator "
        .. "leads to it",
    dlc_recommendation = "dlc_recommendation scope: only the DLC recommendations of the "
        .. "empire designer use it",
}

-- The order in which a keyword's supported scopes are tried.
local PREFERENCE = { "country", "planet", "colony", "fleet", "ship", "leader", "pop_group",
    "species", "galactic_object", "starbase", "federation", "army", "sector", "war",
    "megastructure", "pop_faction", "deposit", "archaeological_site", "first_contact",
    "situation", "espionage_operation", "spy_network", "espionage_asset", "agreement",
    "astral_rift", "bypass", "ambient_object", "debris", "cosmic_storm",
    "cosmic_storm_influence_field", "job", "mission", "design", "trait", "ship_growth_stage",
    "exhibit", "no_scope" }

local function reachable(scope)
    return EVENT_OF[scope] ~= nil or REACH[scope] ~= nil
end

local function supports(entry, scope)
    for _, s in ipairs(entry.scopes) do
        if s == scope or s == "all" then
            return true
        end
    end
    return false
end

-- Checks the steps of REACH against the documentation (each step must exist and accept the
-- scope it starts from), so that a dump that changes them stops the generator.
local function check_reach()
    for _, scope in ipairs(sorted_keys(REACH)) do
        local r = REACH[scope]
        local at = r.root
        assert(EVENT_OF[at], scope .. ": no event type for " .. at)
        for _, step in ipairs(r.steps) do
            local t, e, to = step[1], step[2], step[3]
            if t == e then
                local link = assert(by_kind.link[t], scope .. ": no scope link " .. t)
                assert(supports(link, at), scope .. ": " .. t .. " does not start from " .. at)
                assert(link.output == to, scope .. ": " .. t .. " does not lead to " .. to)
            else
                local any = assert(by_kind.trigger[t], scope .. ": no trigger " .. t)
                local every = assert(by_kind.effect[e], scope .. ": no effect " .. e)
                assert(supports(any, at) and supports(every, at),
                    scope .. ": " .. t .. "/" .. e .. " do not start from " .. at)
            end
            at = to
        end
        assert(at == scope, scope .. ": the steps lead to " .. at)
    end
end

check_reach()

-- The root of the events for a scope, and the keys that lead from it to the scope.
local function path_to(scope, kind)
    if EVENT_OF[scope] then
        return scope, {}
    end
    local r = REACH[scope]
    local keys = {}
    for i, step in ipairs(r.steps) do
        keys[i] = kind == "trigger" and step[1] or step[2]
    end
    return r.root, keys
end

---------------------------------------------------------------------------------------------------
-- Placeholders

local TRIGGER_FILLER = "always = yes"
local EFFECT_FILLER = 'log = "sdc"'

-- The mod's own names, for flags, variables, texts and event targets.
local OWN = { flag = "sdc_flag", variable = "sdc_var", text = "sdc_text", target = "sdc_target" }

-- The fixed ids of the anchor events, one per event type (see write_anchors); the last two are
-- event types no keyword is placed in, only referred to (carrier_event, observer_event).
local ANCHOR_TYPES = {}
for _, t in ipairs(EVENT_TYPES) do
    ANCHOR_TYPES[#ANCHOR_TYPES + 1] = t[2]
end
ANCHOR_TYPES[#ANCHOR_TYPES + 1] = "carrier_event"
ANCHOR_TYPES[#ANCHOR_TYPES + 1] = "observer_event"
local ANCHOR_ID = {}
for i, t in ipairs(ANCHOR_TYPES) do
    ANCHOR_ID[t] = NAMESPACE .. "." .. i
end

-- Placeholders that name a kind of object: the directory under common/ that defines them.
local PLACEHOLDER_DIRS = {
    ["federation law"] = "federation_laws", ["federation perk"] = "federation_perks",
    ["federation type"] = "federation_types",
    ["federation law category"] = "federation_law_categories",
    ["resolution"] = "resolutions", ["resolution_type_key"] = "resolutions",
    ["resolution type"] = "resolutions", ["resolution_category"] = "resolution_categories",
    ["relic_key"] = "relics", ["relic_name"] = "relics", ["specimen"] = "specimens",
    ["specimen_key"] = "specimens", ["patron_key"] = "patrons", ["patron_name"] = "patrons",
    ["patron"] = "patrons", ["patron key"] = "patrons", ["patron 1"] = "patrons",
    ["patron 2"] = "patrons", ["starbase module"] = "starbase_modules",
    ["starbase_module"] = "starbase_modules", ["starbase building"] = "starbase_buildings",
    ["starbase_building"] = "starbase_buildings", ["building_type_key"] = "buildings",
    ["district_type_key"] = "districts", ["zone_type_key"] = "zones", ["tech key"] = "technology",
    ["tradition_key"] = "traditions", ["tradition_category_key"] = "tradition_categories",
    ["ascension_perk_key"] = "ascension_perks", ["civic"] = "governments/civics",
    ["archaeological site type key"] = "archaeological_site_types",
    ["site type"] = "archaeological_site_types",
    ["espionage category key"] = "espionage_operation_categories",
    ["espionage type key"] = "espionage_operation_types", ["asset type"] = "espionage_assets",
    ["espionage asset type"] = "espionage_assets", ["crisis_level_name"] = "crisis_levels",
    ["storm_type"] = "storm_types", ["megastructure type"] = "megastructures",
    ["name of type"] = "megastructures", ["new_type"] = "megastructures",
    ["overclock_type"] = "megastructure_overclock_types", ["sector type"] = "sector_types",
    ["cb_type"] = "casus_belli", ["war goal"] = "war_goals", ["preset key"] = "agreement_presets",
    ["preset_name"] = "agreement_presets", ["term"] = "agreement_terms",
    ["term_value"] = "agreement_term_values", ["perk_key"] = "specialist_subject_perks",
    ["specialist_type_key"] = "specialist_subject_types",
    ["specialist_subject_type"] = "specialist_subject_types",
    ["component template key"] = "component_templates",
    ["component key"] = "component_templates", ["event_chain_key"] = "event_chains",
    ["event_chain"] = "event_chains", ["pop_category"] = "pop_categories",
    ["pop category"] = "pop_categories", ["jobtype"] = "pop_jobs", ["job"] = "pop_jobs",
    ["deposit"] = "deposits", ["category key"] = "deposit_categories", ["trait"] = "traits",
    ["species class key"] = "species_classes", ["colony type"] = "colony_types",
    ["star class"] = "star_classes", ["class"] = "planet_classes", ["ship_size"] = "ship_sizes",
    ["ship size key"] = "ship_sizes", ["situation_type"] = "situations",
    ["project key"] = "special_projects", ["mission key"] = "missions",
    ["mission_key"] = "missions", ["personality"] = "personalities",
    ["converter_key"] = "resource_converters", ["objective"] = "crisis_objectives",
    ["path_name"] = "crisis_paths", ["bypass type"] = "bypass",
    ["asteroid belt type key"] = "asteroid_belts",
    ["graphical culture key"] = "graphical_culture", ["resource_name"] = "strategic_resources",
    ["resource_key"] = "strategic_resources", ["resource_name_1"] = "strategic_resources",
    ["resource_name_2"] = "strategic_resources", ["crisis_perk_name"] = "menace_perks",
    ["origin key"] = "governments/civics", ["origin"] = "governments/civics",
    ["category_name"] = "economic_categories", ["focus_card_key"] = "country_focus/focus_cards",
    ["focus_category_key"] = "country_focus/card_categories", ["deed"] = "patrons/deeds",
    ["modifier"] = "static_modifiers", ["council_position_tag"] = "governments/councilors",
    ["council_pos_key"] = "governments/councilors", ["action_key"] = "tradable_actions",
    ["key for pre-defined system"] = "solar_system_initializers",
}

-- The directory of a generic <key> placeholder, by the key it is written after.
local KEY_DIRS = { ethic = "ethics", trait = "traits", civic = "governments/civics",
    tech = "technology", modifier = "static_modifiers", building = "buildings",
    district = "districts", zone = "zones", job = "pop_jobs", deposit = "deposits",
    resource = "strategic_resources", patron = "patrons", policy = "policies",
    holding = "buildings", authority = "governments/authorities", relic = "relics",
    edict = "edicts", mission = "missions", new_ethic = "ethics", old_ethic = "ethics" }

-- Placeholder words for plain values, tried in order on each choice of the placeholder.
local GENERIC = {
    { "^yes$", "yes" }, { "^no$", "no" }, { "^bool", "yes" }, { "^y$", "yes" }, { "^n$", "no" },
    { "flag", OWN.flag }, { "variable", OWN.variable },
    { "^int", "1" }, { "integer", "1" },
    { "percentage", "0.5" }, { "fraction", "0.5" }, { "^0%.0", "0.5" }, { "^0%-1", "0.5" },
    { "radius", "10" }, { "index", "0" }, { "^num", "1" }, { "number", "1" },
    { "float", "1" }, { "^value", "1" }, { "amount", "1" }, { "days", "30" }, { "level", "1" },
    { "cap$", "1" }, { "^%+/%- ", "1" }, { "^%+/%-", "1" }, { "experience", "1" },
    { "string", OWN.text }, { "^text", OWN.text }, { "loc", OWN.text }, { "^name$", OWN.text },
}

-- Choices that name something to point at: written as a scope (from).
local ENTITY = { "target", "scope", "country", "^who$", "owner", "planet", "fleet", "ship",
    "system", "species", "leader", "army", "colony", "carrier", "starbase", "pop group",
    "attacker", "^design$", "^star$", "^war$" }
-- Words in placeholders that say something about the parameter, not what to write.
local META = set_of({ "optional", "default", "default: yes", "default: no", "only" })

local function is_entity(choice)
    for _, p in ipairs(ENTITY) do
        if choice:find(p) then
            return true
        end
    end
    return false
end

local function is_type(choice)
    if PLACEHOLDER_DIRS[choice] or choice:find(" ") or choice == "key" or choice == "type"
        or choice:find("_key$") or choice == "id" or choice:find("_id$") then
        return true
    end
    for _, g in ipairs(GENERIC) do
        if choice:find(g[1]) then
            return true
        end
    end
    return false
end

-- Words of the examples that stand for a value without brackets.
local BARE = { x = "1", y = "1", int = "1", float = "1", nDays = "30", num = "1",
    bool = "yes" }

-- The keys whose value is one of the mod's own names, whatever the placeholder says.
local KEY_OWN = { which = OWN.variable, variable = OWN.variable, order_by = OWN.variable,
    flag = OWN.flag }
-- The same for a word of the example that vanilla does not know.
local KEY_OWN_WORD = { which = OWN.variable, variable = OWN.variable, flag = OWN.flag,
    name = OWN.text, text = OWN.text, title = OWN.text, tooltip = OWN.text, desc = OWN.text,
    description = OWN.text, localization = OWN.text, fail_text = OWN.text,
    success_text = OWN.text, ship_name = OWN.text, army_name = OWN.text,
    divider_tooltip = OWN.text }
-- The keys whose value is a scope.
local KEY_TARGET = set_of({ "who", "target", "owner", "country", "location", "attacker",
    "defender", "with_country", "enemy", "surveyor", "controller", "homeworld", "center",
    "from", "to", "closer_object", "further_object", "species", "faction", "pop_group", "for",
    "planet", "fleet", "war", "side", "background_planet", "released_by_country",
    "released_from_country", "use_hostilities_from", "exclude_day_zero_contact",
    "coords_from", "relative_to", "in_place_of", "source", "ftl", "system" })

-- The most written vanilla value of a keyword's parameter (ties: the first in sort order).
local function vanilla_value(kind, name, path)
    local per_name = vanilla.values[kind][name]
    local t = per_name and per_name[path]
    if t == nil then
        return nil
    end
    local best, count = nil, 0
    for _, v in ipairs(sorted_keys(t)) do
        if t[v] > count then
            best, count = v, t[v]
        end
    end
    return best
end

-- What the value of another keyword's parameter is in vanilla (for overrides); a use that gets
-- MISSING is skipped.
local function like(kind, name, path)
    return vanilla_value(kind, name, path or "") or "MISSING"
end

local SCOPE_WORDS = set_of({ "root", "from", "this", "prev", "fromfrom", "fromfromfrom",
    "fromfromfromfrom", "prevprev", "prevprevprev", "prevprevprevprev", "yes", "no",
    "none", "any", "all", "random" })

-- Words too general to stand for an object even if a directory defines one by that name.
local NOT_OBJECTS = set_of({ "country", "modifier", "planet", "fleet", "ship", "species",
    "leader", "army", "category", "type", "key", "value", "default", "stage", "setting",
    "approach", "rarity", "buildable", "any", "all", "none", "random" })

-- The first object of a directory that vanilla also refers to somewhere (n-th for <x_2>).
local function object_of(dir, n)
    local objects = vanilla.objects[dir]
    if objects == nil then
        return nil
    end
    local found = 0
    for _, o in ipairs(objects) do
        if vanilla.value_words[o] and not SCOPE_WORDS[o] and not NOT_OBJECTS[o]
            and not o:match("^[%d%.%-]+$") then
            found = found + 1
            if found == (n or 1) then
                return o
            end
        end
    end
    return objects[1]
end

-- A word is known when the game will find it: a number, a scope (chain), one of the mod's
-- names, a vanilla object, or a value vanilla writes after the same key.
local function known_word(word, key, kind, name, path)
    if word:match("^[%+%-]?%d+%.?%d*$") or word:match("^%d+%.%d+%.%d+$") then
        return true
    end
    local lower = word:lower()
    if SCOPE_WORDS[lower] or word:find("^sdc_") or word:find("^" .. NAMESPACE .. "%.%d+$") then
        return true
    end
    if word:find("^event_target:") or word:find("^trigger:") or word:find("^value:")
        or word:find("^modifier:") then
        return true
    end
    if vanilla.is_object[word] and not NOT_OBJECTS[lower] then
        return true
    end
    if key and vanilla.key_values[key] and vanilla.key_values[key][word] then
        return true
    end
    local per_name = vanilla.values[kind][name]
    if per_name and per_name[path] and per_name[path][word] then
        return true
    end
    -- a scope chain: every part is a scope link or a scope word
    if word:find(".", 1, true) then
        for part in word:gmatch("[^%.]+") do
            local p = part:lower():gsub("%?$", "")
            if not (SCOPE_WORDS[p] or by_kind.link[p] or p:find("^event_target:")) then
                return false
            end
        end
        return true
    end
    return false
end

-- Keys too general for "what vanilla writes most after this key" to mean anything.
local GENERAL_KEYS = set_of({ "", "type", "category", "key", "name", "value", "id", "target",
    "who", "amount", "count", "trigger", "text", "desc", "title", "icon", "class" })

-- Values for placeholders of particular keywords: PLACEHOLDERS[name][path] = value, where path
-- is "" for the keyword's own value and the keys below it otherwise ("owners.category").
local PLACEHOLDERS = {}

-- The value for a placeholder written after `key` (path: from the keyword down), or a table
-- { block = "statements" } for a placeholder that stands for a block.
local function resolve(text, key, kind, name, path)
    local p = text:lower():gsub("^%s+", ""):gsub("%s+$", "")
    local fixed = PLACEHOLDERS[name] and PLACEHOLDERS[name][path]
    if fixed then
        return fixed
    end
    -- a statement in brackets: <add/factor = float>
    local k, v = p:match("^([%w_/]+)%s*=%s*(.+)$")
    if k then
        local value = v
        if not (SCOPE_WORDS[v] or v:match("^[%d%.]+$")) then
            value = resolve(v, k, kind, name, path)
        end
        return k:match("^[^/]+") .. " = " .. (type(value) == "string" and value or "1")
    end
    -- a block of triggers or effects where a value goes: limit = <triggers>
    if p:find("trigger") and key ~= "trigger" and not p:find(":") then
        return { block = TRIGGER_FILLER }
    elseif p:find("effect") then
        return { block = EFFECT_FILLER }
    end
    if key == name then
        if name:find("flag") then
            return OWN.flag
        elseif name:find("event_target") then
            return OWN.target
        elseif name:find("variable") then
            return OWN.variable
        end
    end
    -- the choices: a/b/c, a|b, "a or b", "a, b"
    local choices = {}
    for c in (p:gsub(" or ", "/") .. "/"):gmatch("([^/|,]*)[/|,]") do
        c = c:gsub("%b()", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if c ~= "" and not META[c] then
            choices[#choices + 1] = c
        end
    end
    -- an object of a kind the placeholder names
    for _, c in ipairs(choices) do
        local dir = PLACEHOLDER_DIRS[c]
        if dir then
            local value = vanilla_value(kind, name, path)
            if value and known_word(value, key, kind, name, path) then
                return value
            end
            local o = object_of(dir, tonumber(c:match("_(%d)$") or c:match(" (%d)$") or "1"))
            if o then
                return o
            end
        end
    end
    if KEY_OWN[key] then
        return KEY_OWN[key]
    end
    -- a list of values to choose from: what vanilla writes, else the first plain word
    if #choices > 1 then
        local listed
        for _, c in ipairs(choices) do
            if c:match("^[a-z_][a-z0-9_]*$") and not is_type(c) and not is_entity(c) then
                listed = listed or c
            end
        end
        if listed then
            local value = vanilla_value(kind, name, path)
            if value and known_word(value, key, kind, name, path) then
                return value
            end
            return listed
        end
    end
    for _, c in ipairs(choices) do
        if is_entity(c) then
            return "from"
        else
            for _, g in ipairs(GENERIC) do
                if c:find(g[1]) then
                    return g[2]
                end
            end
            if c == "key" or c == "type" or c:find("key") or c:find("type$") or c == "id"
                or c:find("_id$") then
                local value = vanilla_value(kind, name, path)
                if value then
                    return value
                end
                if KEY_DIRS[key] then
                    local o = object_of(KEY_DIRS[key])
                    if o then
                        return o
                    end
                end
                -- what vanilla writes most after the same key anywhere
                if not GENERAL_KEYS[key] and vanilla.key_counts[key] then
                    local best, count = nil, 0
                    for _, w in ipairs(sorted_keys(vanilla.key_counts[key])) do
                        local times = vanilla.key_counts[key][w]
                        if times > count and clean_text(w) and not w:find("[%.:]") then
                            best, count = w, times
                        end
                    end
                    if best then
                        return best
                    end
                end
            end
        end
    end
    return vanilla_value(kind, name, path)
end

---------------------------------------------------------------------------------------------------
-- Uses from the documentation's examples

local SENTINEL = "SDCPLACEHOLDER"

-- The lines of an example that make the keyword's statement: from the line that starts with the
-- keyword (or, if none does, the first line that starts with a word and an operator, renamed)
-- to the line that closes its braces.
local function example_lines(entry)
    local name = entry.name
    local lines = {}
    local syntax = entry.syntax
    if syntax == "" then
        local from = entry.description:find(name .. " = ", 1, true)
        if from == nil then
            return nil
        end
        syntax = entry.description:sub(from)
    end
    for line in (syntax .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line:gsub("^%s*example:%s*", ""):gsub("^%s*Begin:%s*", "")
    end
    local start, rename
    for i, line in ipairs(lines) do
        local w = line:match("^%s*([%w_:%.]+)%s*[=<>!{]")
        if w == name then
            start = i
            break
        end
    end
    if start == nil then
        for i, line in ipairs(lines) do
            local w = line:match("^%s*([%w_%.]+)%s*[=<>]")
            if w and w ~= "if" then
                start, rename = i, w
                break
            end
        end
    end
    if start == nil then
        return nil
    end
    -- else and else_if need the if before them
    if (name == "else" or name == "else_if") and start > 1
        and lines[start - 1]:match("^%s*if%s*=") then
        start = start - 1
    end
    local out, depth = {}, 0
    for i = start, #lines do
        local line = lines[i]
        if i == start and rename then
            line = line:gsub("^(%s*)[%w_%.]+", "%1" .. name, 1)
        end
        out[#out + 1] = line
        -- count the braces outside placeholders and comments
        local stripped = line:gsub("#.*$", "")
        local before
        repeat
            before = stripped
            stripped = stripped:gsub("<[^<>]*>", "")
        until stripped == before
        local _, opens = stripped:gsub("{", "")
        local _, closes = stripped:gsub("}", "")
        depth = depth + opens - closes
        local pair = (name == "else" or name == "else_if") and i == start
        if depth <= 0 and not pair then
            break
        end
    end
    local text = table.concat(out, "\n")
    for _ = 1, depth do
        text = text .. "\n}"
    end
    return text
end

-- Fills the placeholders of an example and checks it. Returns the statements' text, or nil and
-- why not.
local function from_example(kind, entry)
    local text = example_lines(entry)
    if text == nil then
        return nil, "no example"
    end
    local name = entry.name
    -- operators written as placeholders
    text = text:gsub("<comparator>", ">"):gsub("< = >", ">"):gsub("><=", ">"):gsub(">=<", ">")
        :gsub("<=>", ">")
    -- placeholders -> sentinels (inner ones first)
    local placeholders = {}
    local changed = true
    while changed do
        changed = false
        text = text:gsub("<([^%s=<>][^<>]-)>", function(p)
            changed = true
            placeholders[#placeholders + 1] = p
            return SENTINEL .. #placeholders .. "X"
        end)
    end
    -- comments: after #, in brackets [ ], in parentheses (also unclosed ones), stray ");"
    text = text:gsub("#[^\n]*", ""):gsub("%s?%b[]", "")
    local before
    repeat
        before = text
        text = text:gsub("%s%b()", "")
    until text == before
    text = text:gsub("%s%([^\n]*", ""):gsub("%)+;?", "")
    -- choices on a line: keep the first; prose after a value ("<number> If set, the ...")
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        line = line:gsub("%s+OR%s+.*$", ""):gsub("%s+or%s+.*$", ""):gsub("%s+|%s+.*$", "")
            :gsub("%s+/%s+[^%s{}]+", "")
        if not line:find('"', 1, true) then
            line = line:gsub("%s+%u%l+,?%s+%l.*$", "")
        end
        lines[#lines + 1] = line
    end
    text = table.concat(lines, "\n")
    -- choices in a word: a/b/c -> a (a choice the example lists counts as known)
    local listed = {}
    text = text:gsub("[^%s{}=<>!\"]+", function(w)
        if w:find("[/|]") and not w:find("^[/|]") then
            local first = w:match("^[^/|]+")
            listed[first] = true
            return first
        end
        return w
    end)
    text = text:gsub("%.%.%.", "")
    local tree, message = pdxscript.parse(text, name)
    if tree == nil then
        return nil, "example does not parse: " .. message
    end
    local found = false
    for _, e in ipairs(tree) do
        if e.op and e.key.text == name then
            found = true
        end
    end
    if not found then
        return nil, "example does not use the keyword"
    end
    -- resolve the sentinels, check the words
    local problem
    local function sentinel(t)
        return tonumber(t:match("^" .. SENTINEL .. "(%d+)X$") or "")
    end
    local function value_of(token, key, path)
        local t = token.text
        local n = sentinel(t)
        if n then
            local v = resolve(placeholders[n], key, kind, name, path)
            if v == nil then
                problem = problem or ("no value for <" .. placeholders[n] .. ">")
                return t
            end
            return v
        end
        if t:find(SENTINEL, 1, true) then
            problem = problem or ("placeholder inside a word: " .. t)
            return t
        end
        if BARE[t] then
            return BARE[t]
        end
        if token.quoted or listed[t] or known_word(t, key, kind, name, path) then
            return t
        end
        -- an unknown word: a value given for it, what vanilla writes there, or the kind of
        -- object it names
        local fixed = PLACEHOLDERS[name] and PLACEHOLDERS[name][path]
        if fixed then
            return fixed
        end
        local v = vanilla_value(kind, name, path)
        if v and known_word(v, key, kind, name, path) then
            return v
        end
        local dir = PLACEHOLDER_DIRS[t:lower()]
        local o = dir and object_of(dir)
        if o then
            return o
        end
        if KEY_TARGET[key] then
            return "from"
        elseif KEY_OWN_WORD[key] then
            return KEY_OWN_WORD[key]
        end
        problem = problem or ("unknown word " .. t)
        return t
    end
    local function fix(block, prefix, depth)
        local i = 1
        while i <= #block do
            local e = block[i]
            if e.op then
                local key = e.key.text
                local n = sentinel(key)
                if n then
                    local k = resolve(placeholders[n], "", kind, name, prefix)
                    if type(k) ~= "string" or k:find("[%s=]") then
                        problem = problem or ("no key for <" .. placeholders[n] .. ">")
                    else
                        e.key = { text = k, line = e.key.line }
                        key = k
                    end
                elseif not vanilla.words[key] and (key:find("^some_") or key:find("^my_")
                    or key:find("_%d+$")) then
                    -- a stand-in key of the example (some_flag_1)
                    problem = problem or ("example key " .. key)
                end
                local path = depth == 0 and "" or (prefix == "" and key or prefix .. "." .. key)
                if e.value.text then
                    local v = value_of(e.value, depth == 0 and name or key, path)
                    if type(v) == "table" then
                        e.value = assert(pdxscript.parse(v.block))
                    else
                        e.value = { text = v, quoted = e.value.quoted, line = e.value.line }
                    end
                else
                    fix(e.value, path, depth + 1)
                end
                i = i + 1
            elseif e.text then
                local n = sentinel(e.text)
                if n then
                    -- a placeholder for statements
                    local p = placeholders[n]:lower()
                    local filler
                    if p:find("=") then
                        filler = resolve(p, "", kind, name, prefix)
                    elseif p:find("trigger") then
                        filler = TRIGGER_FILLER
                    elseif p:find("effect") then
                        filler = EFFECT_FILLER
                    end
                    if type(filler) == "table" then
                        filler = filler.block
                    end
                    if filler == nil then
                        problem = problem or ("no statements for <" .. placeholders[n] .. ">")
                        i = i + 1
                    else
                        local sub = assert(pdxscript.parse(filler))
                        table.remove(block, i)
                        for j = #sub, 1, -1 do
                            table.insert(block, i, sub[j])
                        end
                        i = i + #sub
                    end
                elseif depth == 0 then
                    problem = problem or ("stray word " .. e.text)
                    i = i + 1
                else
                    local v = value_of(e, prefix:match("([^%.]+)$") or name, prefix)
                    if type(v) == "table" then
                        problem = problem or ("block where a word goes: " .. e.text)
                    else
                        block[i] = { text = v, quoted = e.quoted, line = e.line }
                    end
                    i = i + 1
                end
            else
                fix(e, prefix, depth + 1)
                i = i + 1
            end
        end
    end
    fix(tree, "", 0)
    if problem then
        return nil, problem
    end
    return pdxscript.write(tree)
end

---------------------------------------------------------------------------------------------------
-- Uses from vanilla

local function count_tokens(node)
    if node.text then
        return 1
    end
    local n = 0
    for _, e in ipairs(node) do
        if e.op then
            n = n + 1 + count_tokens(e.value)
        else
            n = n + count_tokens(e)
        end
    end
    return n
end

-- A copy of a vanilla statement with its scripted variables resolved, or nil if it depends on
-- where it is written (parameters, unresolved variables, inline math).
local function clean_copy(node, vars)
    local ok = true
    local function copy(v)
        if v.text then
            local t = clean_text(v.text, vars)
            if t == nil then
                ok = false
                return v
            end
            return { text = t, quoted = v.quoted, line = v.line }
        end
        local b = { line = v.line, type = v.type }
        for i, e in ipairs(v) do
            if e.op then
                local k = clean_text(e.key.text, vars)
                if k == nil then
                    ok = false
                end
                b[i] = { key = { text = k or e.key.text }, op = e.op, value = copy(e.value) }
            elseif e.param then
                ok = false
            else
                b[i] = copy(e)
            end
        end
        return b
    end
    local c = { key = node.key, op = node.op, value = copy(node.value) }
    return ok and c or nil
end

local function from_vanilla(kind, name)
    local best, best_size, best_use
    for _, use in ipairs(vanilla.uses[kind][name] or {}) do
        local c = clean_copy(use.node, use.vars)
        if c then
            local size = count_tokens(c.value)
            if best == nil or size < best_size then
                best, best_size, best_use = c, size, use
            end
        end
    end
    if best == nil then
        return nil
    end
    return pdxscript.write({ best }), best_use.file .. ":" .. best_use.line
end

---------------------------------------------------------------------------------------------------
-- Overrides: uses written here because neither the documentation's example nor vanilla gives a
-- valid one. A spec is { text = "...", scope = "..." }, { skip = "reason" }, or { scope = "..." }
-- (only choose the scope). `where = "desc"` puts a trigger in the desc = { trigger = { } } of
-- the main event (sdc.1). A `note` says what in the use is not from the documentation.

local OVERRIDES = { trigger = {}, effect = {}, link = {} }
local T, E = OVERRIDES.trigger, OVERRIDES.effect
local DEBUG = "debug-only: stops a debugger (docs)"
local STORM_EVENT = "fires an event of a cosmic storm type; vanilla defines no such event to "
    .. "refer to"

-- desc = { trigger = { } } only (docs: "For 'desc={trigger={' use")
T.text = { where = "desc", text = "text = " .. NAMESPACE .. ".1.desc" }
T.success_text = { where = "desc", text = "success_text = { text = sdc_text always = yes }" }
T.fail_text = { where = "desc", text = "fail_text = { text = sdc_text always = no }" }

T.debug_break = { skip = DEBUG }
E.debug_break = { skip = DEBUG }
E.cosmic_storm_event = { skip = STORM_EVENT }
E.cosmic_storm_influence_field_event = { skip = STORM_EVENT }

-- triggers without an example, written like their siblings
T["and"] = { text = "and = { always = yes always = yes }", note = "no example in the docs" }
T.nand = { text = "nand = { always = yes always = no }", note = "no example in the docs" }
T.fallen_empire_strength_scale = { text = "fallen_empire_strength_scale > 0",
    note = "no example; written like voidworms_scaling in vanilla" }
T.stored_physics_points = { text = "stored_physics_points > 100",
    note = "the example has no operator" }
T.stored_society_points = { text = "stored_society_points > 100",
    note = "the example has no operator" }
T.stored_engineering_points = { text = "stored_engineering_points > 100",
    note = "the example has no operator" }
T.can_join_factions = { text = "can_join_factions = yes", note = "no example in the docs" }
T.is_on_galaxy_map = { text = "is_on_galaxy_map = yes", note = "no example in the docs" }
T.num_cosmic_storms = { text = "num_cosmic_storms > 0", note = "no example in the docs" }
T.cosmic_storm_system_influence = { text = "cosmic_storm_system_influence > 0",
    note = "no example; written like cosmic_storm_influence_value in vanilla" }
T.is_storm_active_in_storm_sector = { text = "is_storm_active_in_storm_sector = yes",
    note = "no example in the docs" }
for _, w in ipairs({ "early", "mid", "late" }) do
    for _, s in ipairs({ "spawn_chance_scale", "spawn_max_cap" }) do
        local n = "num_cosmic_storm_" .. w .. "_game_" .. s .. "_setting"
        T[n] = { text = n .. " > 0", note = "no example in the docs" }
    end
end
T.num_cosmic_storm_spawn_cooldown_scale_setting = {
    text = "num_cosmic_storm_spawn_cooldown_scale_setting > 0", note = "no example in the docs" }
T.has_existing_ship_design = { text = 'has_existing_ship_design = "NAME_Euthanizer"',
    note = "no example; a design name from common/global_ship_designs" }
T.conditional_tooltip = { text = "conditional_tooltip = { trigger = { always = yes } "
    .. "always = yes }", note = "no example; the block form the description gives" }
T.galaxy_shape = { text = "galaxy_shape = spiral_2",
    note = "spiral_2 is a shape of map/galaxy/galaxy_shapes.txt" }
T.species_has_happiness_with_owner = { text = "species_has_happiness_with_owner = from",
    note = "the example's 'country' is a target" }
T.count_species_traits = { text = "count_species_traits = { limit = { always = yes } "
    .. "category = cyborg cost = 1 count < 2 }",
    note = "category and cost as vanilla's script values write them" }
T.count_war_participants = { text = "count_war_participants = { limit = { always = yes } "
    .. "side = attackers count < 4 }", note = "side as in is_war_participant's example" }
T.num_leader_traits = { text = "num_leader_traits = { value > 2 is_councilor = any "
    .. "negative = any count_tiers = no contains_modifier = { string = \"federation\" "
    .. "type = any } is_subclass = any }", note = "the example's broken syntax repaired" }
T.has_federation_setting = { text = "has_federation_setting = commercial_pact",
    note = "a setting set_federation_settings sets in vanilla" }
T.current_stage = { text = "current_stage = stage_1",
    note = "a stage of common/situations/01_narrative_situations.txt" }
T.check_economic_production_modifier_for_job = { text = "check_economic_production_modifier_"
    .. "for_job = { job = miner resource = { minerals = 0.5 energy = 0.5 } "
    .. "species_modifiers_only = no value > 1.25 }",
    note = "the example gives resource twice (a word and a block); the block kept" }
T.starbase_buildable_is_in_queue_before = { text = "starbase_buildable_is_in_queue_before = "
    .. "{ first = shipyard second = anchorage }", note = "two starbase modules" }

E.switch = { text = "switch = { trigger = num_owned_colonies 1 = { log = \"sdc\" } "
    .. "5 <= { log = \"sdc\" } default = { log = \"sdc\" } }",
    note = "a value case and a comparison case, as in vanilla" }
E.inverted_switch = { text = "inverted_switch = { trigger = has_technology "
    .. "TECH = { log = \"sdc\" } default = { log = \"sdc\" } }" }
E.observer_event = { text = "observer_event = { id = " .. ANCHOR_ID.observer_event .. " }",
    note = "no example; written like vanilla, with the mod's own observer event" }
E["while"] = { text = "while = { count = 3 log = \"sdc\" }",
    note = "the example's count form (its limit form would loop on always = yes)" }
E.set_spawn_system_batch = { text = "set_spawn_system_batch = begin\n"
    .. "set_spawn_system_batch = end" }
E.set_update_modifiers_batch = { text = "set_update_modifiers_batch = begin\n"
    .. "set_update_modifiers_batch = end" }
E.set_country_code_flags = { text = "set_country_code_flags = { custom_name = yes "
    .. "initialized = no }", note = "flags from the example's list" }
E.rename_species = { text = "rename_species = { name = random }" }
-- the docs' forms that Stellaris 4.5.2 refuses (error.log), written as vanilla writes them; a
-- refused value can also throw the game's reader off for the rest of the file
E.owned_fleet_list_tooltip = { text = "owned_fleet_list_tooltip = { limit = { always = yes } }",
    note = "the game refuses divider_tooltip (\"Unhandled Entry\"), vanilla uses limit only" }
E.refuse_covenant = { text = "refuse_covenant = { patron = end_of_the_cycle reset_attunement = yes }",
    note = "the game wants a block, not `= <patron>` (vanilla form)" }
E.create_ship_design = { text = "create_ship_design = { design = NAME_Brigand }",
    note = "the game refuses ftl (\"Unexpected token\"), vanilla gives the design only" }
T.count_used_naval_cap = { text = "count_used_naval_cap = { limit = { always = yes } value >= 6 }",
    note = "the game wants value, not count (vanilla form)" }
T.get_attunement_points_for = { skip = "the game wants `value = { ... }` (error.log), and neither "
    .. "the docs (`value = <int/variable>`) nor vanilla say what goes in it" }
T.planet_happiness_above_threshold = { skip = "the game refuses the docs' `value > 0` (error.log: "
    .. "\"Unexpected token: value\"), and vanilla does not use it" }
T.valid_planet_killer_target = { skip = "the game wants a block where the docs give `= <planet>`, "
    .. "and vanilla does not use it" }
E.stop_mission = { skip = "the game reads the docs' block as effects (mission and status become "
    .. "scripted effect calls), and vanilla does not use it" }
E.create_smaller_size_creature_in_fleet = { text = "create_smaller_size_creature_in_fleet = { count = 1 "
    .. "effect = { set_ship_flag = sdc_flag } }", note = "the game wants a block, not a number (vanilla form)" }
E.tooltip = { text = "tooltip = { log = \"sdc\" }",
    note = "a block of effects shown, not run (vanilla events); the shortest vanilla `tooltip` is a "
        .. "scripted action field" }
T.ship_size_cost_resource_percent = { skip = "the game wants a block where the docs give "
    .. "`= <resource_key>`; vanilla uses it only as a complex_trigger_modifier trigger" }
E.start_colony = { text = "start_colony = { owner = from species = from }",
    note = "vanilla form; with the docs' `ethos = random` the game's reader loses its place "
        .. "(error.log: the next effect is \"Unexpected token\")" }
T.count_ship_size_in_system = { skip = "the game refuses the docs' `count` (error.log: "
    .. "\"Unexpected token: count\"), and vanilla does not use it" }
T.governors_skill_in_system = { skip = "the game wants a block (error.log) and refuses the docs' "
    .. "example in it (has_base_skill > 2); vanilla does not use it" }
T.is_system_connected_to_relay_network = { text = "is_system_connected_to_relay_network = yes",
    note = "a yes/no trigger (error.log: \"Expected: yes/no\"); the docs give a target" }
E.spawn_psionic_aura = { text = "spawn_psionic_aura = { owner = from type = exiled_aura "
    .. "update_type = no }", note = "vanilla form (common/patrons/psionic_auras); the game refuses "
        .. "the docs' `country`" }
E.create_bypass = { text = "create_bypass = { owner = from type = entropy_wormhole }",
    note = "the game refuses the docs' `effect = { ... }` (error.log: \"Unexpected token: "
        .. "effect\"); vanilla does not use it" }
T.nb_pop_exact_species = { skip = "the game wants `value = { ... }` (error.log), and neither the "
    .. "docs nor vanilla say what goes in it" }
T.subject_can_diplomacy = { text = "subject_can_diplomacy = yes",
    note = "a yes/no trigger (error.log: \"Expected: yes/no\"); the docs give a target" }
E.end_fleet_contract = { text = "end_fleet_contract = { initiator = this.controller reason = cancelled }",
    note = "the game wants a block (vanilla form), not `= yes`" }
E.set_empire_flag = { text = "set_empire_flag = { icon = { category = \"zoological\" "
    .. "file = \"flag_zoological_1.dds\" } background = { category = \"backgrounds\" "
    .. "file = \"00_solid.dds\" } colors = { \"black\" \"black\" \"null\" \"null\" } }",
    note = "the empire's flag, a flag block (vanilla grand_archive/voidworms_flag); the game "
        .. "refuses `= <flag>`" }
E.storm_apply_aftermath_modifier = { text = "storm_apply_aftermath_modifier = { severity = "
    .. "{ modifier = MODIFIER days = 30 chance = 1 } }" }
E.copy_ascension_perks_from = { text = "copy_ascension_perks_from = { target = from "
    .. "exceptions = { PERK1 PERK2 } }" }
E.copy_traditions_from = { text = "copy_traditions_from = { target = from "
    .. "exceptions = { TRADITION1 TRADITION2 } }" }
E.copy_techs_from = { text = "copy_techs_from = { target = from except = { TECH1 TECH2 } }" }
E.set_council_position_title_male = { text = "set_council_position_title_male = { "
    .. "position_tag = COUNCILOR title = sdc_text }" }
E.set_council_position_title_female = { text = "set_council_position_title_female = { "
    .. "position_tag = COUNCILOR title = sdc_text }" }
E.create_cosmic_storm = { text = "create_cosmic_storm = { cosmic_storm_start_position = from "
    .. "type = STORM }", note = "the example lists the block's lines without the block; "
    .. "start position named as in vanilla" }
E.create_cosmic_storm_influence_field = { text = "create_cosmic_storm_influence_field = { "
    .. "radius = 10 }", note = "the example lists the block's lines without the block" }
E.destroy_cosmic_storm_influence_field = { text = "destroy_cosmic_storm_influence_field = { "
    .. "center = from }", note = "the example lists the block's lines without the block" }
E.start_storm_area_placing = { text = "start_storm_area_placing = { radius = 10 }",
    note = "the example lists the block's lines without the block" }
E.set_cosmic_storm = { text = "set_cosmic_storm = { cosmic_storm = from }",
    note = "the example lists the block's lines without the block (as vanilla writes it)" }
E.set_terraform_progress = { text = "set_terraform_progress = 0.5",
    note = "no example; written like add_terraform_progress in vanilla" }
E.recalculate_storm_influence_field = { text = "recalculate_storm_influence_field = yes",
    note = "no example in the docs" }
E.set_fauna_fleet_growth_stance = { text = "set_fauna_fleet_growth_stance = controlled" }
E.custom_tooltip_with_params = { text = "custom_tooltip_with_params = { description = sdc_text "
    .. "description_parameters = { SDC_PARAM = 1 } }" }
E.release_vivarium_fauna_count = { text = "release_vivarium_fauna_count = { count = 1 "
    .. "location = from owners = { SHIPCATEGORY = from } }" }
E.room_name_override = { text = "room_name_override = ROOM",
    note = "an empty string removes the override (docs)" }
E.kill_leader = { text = "kill_leader = { class = scientist show_notification = no "
    .. "fire = no }", note = "the documented parameters but ability and heir" }
E.create_leader = { text = "create_leader = { name = random species = from class = scientist "
    .. "skill = 1 set_age = 30 traits = { 1 = LEADERTRAIT } gender = female "
    .. "event_leader = no immortal = no hide_age = no can_manually_change_location = yes "
    .. "can_assign_to_council = yes hide_leader = no randomize_traits = yes "
    .. "leader_age_min = 25 leader_age_max = 30 use_regnal_name = no "
    .. "effect = { log = \"sdc\" } custom_description = sdc_text "
    .. "custom_catch_phrase = sdc_text skip_background_generation = no "
    .. "background_planet = from background_job = BACKGROUNDJOB "
    .. "background_ethic = BACKGROUNDETHIC }",
    note = "the documented parameters but sub_type; the example's prose lines removed" }
E.modify_species = { text = "modify_species = { species = this base = auto "
    .. "add_trait = SPECIESTRAIT remove_trait = SPECIESTRAIT2 add_traits_at_start_of_list = yes "
    .. "ideal_planet_class = PLANETCLASS change_scoped_species = no portrait = PORTRAIT "
    .. "add_random_species_trait = { always = yes } on_random_trait_added = { log = \"sdc\" } "
    .. "sapient = yes effect = { log = \"sdc\" } }",
    note = "the documented parameters; the example's prose removed" }
E.set_planet_entity = { text = "set_planet_entity = { entity = ENTITY graphical_culture = from "
    .. "picture = PLANETCLASS atmosphere_color = hsv { 0.5 0.5 0.5 } "
    .. "atmosphere_intensity = 0.5 atmosphere_width = 0.5 }",
    note = "the documented parameters; colour written as planet classes write theirs" }
E.spawn_natural_wormhole = { text = "spawn_natural_wormhole = { bypass_type = wormhole "
    .. "orbit_distance = 100 orbit_angle = 90 random_pos = yes }" }

-- Values for placeholders of particular keywords (see resolve).
local function ph(name, path, value)
    PLACEHOLDERS[name] = PLACEHOLDERS[name] or {}
    PLACEHOLDERS[name][path] = value
end

---------------------------------------------------------------------------------------------------
-- Choosing a use and a scope for each keyword

local function supported(entry)
    local list = {}
    for _, s in ipairs(entry.scopes) do
        list[#list + 1] = s == "all" and "country" or s
    end
    return list
end

local function choose_scope(entry, forced)
    if forced then
        return forced
    end
    local scopes = set_of(supported(entry))
    for _, s in ipairs(PREFERENCE) do
        if scopes[s] and reachable(s) then
            return s
        end
    end
    local reasons = {}
    for _, s in ipairs(supported(entry)) do
        reasons[#reasons + 1] = UNREACHABLE[s] or (s .. " scope: not reachable")
    end
    return nil, table.concat(reasons, "; ")
end

-- Replaces the capitalised stand-ins of OVERRIDES texts by vanilla names.
local STAND_INS

-- -> { kind, name, scope, text, source, where, note } or { kind, name, skip }
local function build_use(kind, entry)
    local name = entry.name
    local spec = OVERRIDES[kind][name] or {}
    local use = { kind = kind, name = name }
    if spec.skip then
        use.skip = spec.skip
        return use
    end
    local deprecated = (entry.description .. "\n" .. entry.syntax):match("(Deprecated[^%)\n]*)")
    if deprecated then
        use.skip = "deprecated (docs: " .. deprecated:gsub("%s+$", "") .. ")"
        return use
    end
    local scope, why = choose_scope(entry, spec.scope)
    if scope == nil then
        use.skip = why
        return use
    end
    use.scope, use.where, use.note = scope, spec.where, spec.note
    if spec.text then
        use.text = spec.text:gsub("%u[%u%d_]+", function(w)
            return STAND_INS[w] or w
        end)
        use.source = "override"
        if use.text:find("MISSING", 1, true) then
            use.skip = "override: vanilla has no value to model it on"
        end
        return use
    end
    local text, problem = from_example(kind, entry)
    if text and text:find("MISSING", 1, true) then
        text, problem = nil, "a placeholder value vanilla does not have"
    end
    if text then
        use.text, use.source = text, "docs"
        return use
    end
    local vtext, at = from_vanilla(kind, name)
    if vtext then
        use.text, use.source = vtext, "vanilla " .. at
        use.note = problem
        return use
    end
    use.skip = "no valid use: " .. problem .. "; no vanilla use"
    return use
end

-- Vanilla names for the overrides' stand-ins, and placeholder values of particular keywords.
STAND_INS = {
    TECH = object_of("technology"),
    MODIFIER = object_of("static_modifiers"),
    MISSION = like("trigger", "is_mission_type"),
    PERK1 = object_of("ascension_perks", 1), PERK2 = object_of("ascension_perks", 2),
    TRADITION1 = object_of("traditions", 1), TRADITION2 = object_of("traditions", 2),
    TECH1 = object_of("technology", 1), TECH2 = object_of("technology", 2),
    COUNCILOR = like("effect", "set_council_position"),
    STORM = object_of("storm_types"),
    SHIPCATEGORY = object_of("ship_categories"),
    ROOM = '""',
    LEADERTRAIT = like("effect", "create_leader", "traits.1"),
    BACKGROUNDJOB = like("trigger", "has_background_job"),
    BACKGROUNDETHIC = object_of("ethics"),
    SPECIESTRAIT = like("effect", "change_species_characteristics", "add_trait"),
    SPECIESTRAIT2 = like("effect", "change_species_characteristics", "remove_trait"),
    PLANETCLASS = like("trigger", "is_planet_class"),
    PORTRAIT = like("trigger", "species_portrait"),
    ENTITY = like("effect", "set_planet_entity", "entity"),
}
ph("has_stage_modifier", "", like("effect", "add_stage_modifier", "modifier"))
ph("remove_stage_modifier", "", like("effect", "add_stage_modifier", "modifier"))
ph("has_completed_focus", "", like("trigger", "has_active_focus"))
ph("has_invalid_civic", "", like("trigger", "has_valid_civic"))
ph("set_pre_ftl_age", "", like("trigger", "has_pre_ftl_age"))
ph("set_city_graphical_culture", "", object_of("graphical_culture"))
ph("change_species_portrait", "", like("trigger", "species_portrait"))
ph("trade_action_value", "action", like("trigger", "is_action_active", "action"))
ph("is_specimen_rarity", "", "common")
ph("is_last_acquired_specimen_rarity", "", "common")
ph("unlock_exhibit", "", like("trigger", "is_specimen_category"))
ph("uses_ship_category", "", object_of("ship_categories"))
ph("count_deposits", "category", object_of("deposit_categories"))
ph("add_deposit_category_effect", "", object_of("deposit_categories"))
ph("is_job_of_pop_category", "category", like("trigger", "is_pop_category"))
ph("can_set_situation_approach", "", like("trigger", "current_situation_approach"))
ph("has_starbase_size", "", like("effect", "set_starbase_size"))
ph("check_galaxy_setup_value", "setting", "num_empires") -- from the example's list
ph("get_galaxy_setup_value", "setting", "num_empires")
ph("set_mission_counter", "mission", like("effect", "add_mission_counter", "mission"))
ph("set_mission_counter", "counter", like("effect", "add_mission_counter", "counter"))
ph("has_job_category", "", like("trigger", "is_pop_category"))
ph("pop_ethic_percentage", "ethic", object_of("ethics"))
ph("get_councilor_level", "type", like("effect", "set_council_position"))
ph("count_starbase_sizes", "starbase_size", like("effect", "set_starbase_size"))
ph("add_random_research_option", "category", like("trigger", "can_copy_random_tech_from",
    "category"))
ph("add_intel_report", "category", object_of("intel_categories"))
ph("clear_intel_report", "category", object_of("intel_categories"))
ph("set_war_goal", "type", object_of("war_goals"))
ph("set_saved_date", "key", OWN.flag)
ph("fire_on_action", "on_action", like("effect", "fire_on_action", "on_action"))
ph("add_zone", "zone_slot", "0")
ph("remove_zone", "zone_slot", "0")
for _, t in ipairs(ANCHOR_TYPES) do
    ph(t, "id", ANCHOR_ID[t])
end
ph("set_next_astral_rift_event", "id", ANCHOR_ID.astral_rift_event)
ph("set_next_astral_rift_event", "on_roll_failed", ANCHOR_ID.astral_rift_event)

local uses = { trigger = {}, effect = {} }
for _, kind in ipairs({ "trigger", "effect" }) do
    for _, entry in ipairs(kind == "trigger" and docs.triggers or docs.effects) do
        uses[kind][#uses[kind] + 1] = build_use(kind, entry)
    end
end

---------------------------------------------------------------------------------------------------
-- Writing

-- A file being written: its path in the mod and its lines.
local function new_file(path)
    return { path = path, lines = {} }
end

local function add_line(f, line)
    f.lines[#f.lines + 1] = line
    return #f.lines
end

-- Adds the statements of `text` at an indentation; returns the line of the first top-level
-- statement whose key is `name` (or the first line).
local function add_statements(f, indent, text, name)
    local tree = assert(pdxscript.parse(text, name))
    local first_line, name_line
    for _, e in ipairs(tree) do
        local written = pdxscript.write({ e })
        local start = #f.lines + 1
        for line in written:gmatch("([^\n]*)\n") do
            add_line(f, indent .. line)
        end
        first_line = first_line or start
        if name_line == nil and e.op and e.key.text == name then
            name_line = start
        end
    end
    return name_line or first_line
end

local manifest = {}
local function place(kind, name, f, line, scope, source)
    manifest[#manifest + 1] = { kind = kind, name = name, file = f.path, line = line,
        scope = scope, status = "placed", source = source or "" }
end
local function skip(kind, name, reason)
    manifest[#manifest + 1] = { kind = kind, name = name, file = "", line = "", scope = "",
        status = "skipped: " .. reason, source = "" }
end

local next_id = 100
local function new_id()
    next_id = next_id + 1
    return NAMESPACE .. "." .. next_id
end

local files = {}

-- Opens an event of the type rooted at `root`; returns the indentation inside its trigger or
-- immediate block (after the steps of `keys`) and a function that closes it.
local function open_event(f, root, kind, keys, comment)
    add_line(f, "")
    if comment then
        add_line(f, "# " .. comment)
    end
    add_line(f, EVENT_OF[root] .. " = {")
    add_line(f, "\tid = " .. new_id())
    add_line(f, "\thide_window = yes")
    add_line(f, "\tis_triggered_only = yes")
    if kind == "trigger" then
        add_line(f, "\ttrigger = {")
        add_line(f, "\t\talways = no")
    else
        add_line(f, "\ttrigger = { always = no }")
        add_line(f, "\timmediate = {")
    end
    local indent = "\t\t"
    for _, key in ipairs(keys) do
        add_line(f, indent .. key .. " = {")
        indent = indent .. "\t"
    end
    return indent, function()
        for _ = 1, #keys do
            indent = indent:sub(2)
            add_line(f, indent .. "}")
        end
        add_line(f, "\t}")
        add_line(f, "}")
    end
end

-- Events for the triggers or effects, grouped by scope, PER_EVENT keywords each.
local function write_keyword_events(kind, path, title)
    local f = new_file(path)
    files[#files + 1] = f
    add_line(f, "# " .. title)
    add_line(f, "namespace = " .. NAMESPACE)
    local by_scope = {}
    for _, use in ipairs(uses[kind]) do
        if use.skip then
            skip(kind, use.name, use.skip)
        elseif use.where == nil then
            by_scope[use.scope] = by_scope[use.scope] or {}
            table.insert(by_scope[use.scope], use)
        end
    end
    for _, scope in ipairs(PREFERENCE) do
        local list = by_scope[scope]
        if list then
            table.sort(list, function(a, b)
                return a.name < b.name
            end)
            local root, keys = path_to(scope, kind)
            for first = 1, #list, PER_EVENT do
                local last = math.min(first + PER_EVENT - 1, #list)
                local indent, close = open_event(f, root, kind, keys, string.format(
                    "%ss in %s scope (%d to %d of %d)", kind, scope, first, last, #list))
                for i = first, last do
                    local use = list[i]
                    local line = add_statements(f, indent, use.text, use.name)
                    place(kind, use.name, f, line, scope, use.source)
                end
                close()
            end
        end
    end
end

write_keyword_events("trigger", "events/sdc_triggers.txt",
    "Every documented trigger, in events that never fire (made by make_docs_mod.lua)")
write_keyword_events("effect", "events/sdc_effects.txt",
    "Every documented effect, in events that never fire (made by make_docs_mod.lua)")

---------------------------------------------------------------------------------------------------
-- Scope links

-- Every link as a scope change in a trigger block, from the first scope (by PREFERENCE) it
-- starts from; then a few dotted chains of two links, as scope changes and as targets.
local function write_links()
    local f = new_file("events/sdc_links.txt")
    files[#files + 1] = f
    add_line(f, "# Every documented scope link, in events that never fire "
        .. "(made by make_docs_mod.lua)")
    add_line(f, "namespace = " .. NAMESPACE)
    local by_scope = {}
    for _, link in ipairs(docs.links) do
        local spec = OVERRIDES.link[link.name] or {}
        local scope, why = choose_scope(link, spec.scope)
        if spec.skip then
            skip("link", link.name, spec.skip)
        elseif scope == nil then
            skip("link", link.name, why)
        else
            by_scope[scope] = by_scope[scope] or {}
            table.insert(by_scope[scope], link.name)
        end
    end
    for _, scope in ipairs(PREFERENCE) do
        local list = by_scope[scope]
        if list then
            table.sort(list)
            local root, keys = path_to(scope, "trigger")
            local indent, close = open_event(f, root, "trigger", keys,
                "scope links from " .. scope .. " scope")
            for _, name in ipairs(list) do
                local line = add_line(f, indent .. name .. " = { always = yes }")
                place("link", name, f, line, scope, "scope change")
            end
            close()
        end
    end
    -- dotted chains: a link from country to a scope, then a link from that scope
    local chains = {}
    for _, a in ipairs(docs.links) do
        if supports(a, "country") and a.output ~= "various" and by_kind.link[a.name] then
            for _, b in ipairs(docs.links) do
                if b.output ~= "various" and supports(b, a.output) and a.output ~= "no_scope"
                    and b.output ~= "no_scope" and not supports(b, "all") then
                    chains[#chains + 1] = a.name .. "." .. b.name
                end
            end
        end
    end
    table.sort(chains)
    local picked = {}
    local step = math.max(1, math.floor(#chains / 12))
    for i = 1, #chains, step do
        picked[#picked + 1] = chains[i]
    end
    local indent, close = open_event(f, "country", "trigger", {},
        "dotted chains of scope links, as scope changes and as targets")
    for _, chain in ipairs(picked) do
        add_line(f, indent .. chain .. " = { always = yes }")
        add_line(f, indent .. "exists = " .. chain)
    end
    close()
end

write_links()

---------------------------------------------------------------------------------------------------
-- Static modifiers

local function slug(s)
    return (s:lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", ""))
end

-- One static modifier per category (as modifiers.log writes it), every modifier at 0.01.
local static_names = {}
local function write_static_modifiers()
    local f = new_file("common/static_modifiers/sdc_static_modifiers.txt")
    files[#files + 1] = f
    add_line(f, "# Every documented modifier, in static modifiers nothing applies "
        .. "(made by make_docs_mod.lua)")
    add_line(f, "# One static modifier per category of modifiers.log.")
    local by_category = {}
    for _, m in ipairs(docs.modifiers) do
        by_category[m.category] = by_category[m.category] or {}
        table.insert(by_category[m.category], m.name)
    end
    for _, category in ipairs(sorted_keys(by_category)) do
        local list = by_category[category]
        table.sort(list)
        local name = NAMESPACE .. "_mod_" .. slug(category)
        static_names[#static_names + 1] = { name = name, category = category }
        add_line(f, "")
        add_line(f, "# Category: " .. category)
        add_line(f, name .. " = {")
        for _, m in ipairs(list) do
            local line = add_line(f, "\t" .. m .. " = 0.01")
            place("modifier", m, f, line, name, "")
        end
        add_line(f, "}")
    end
end

write_static_modifiers()

---------------------------------------------------------------------------------------------------
-- Scripted triggers and effects (called from the main event)

local SCRIPTED_TRIGGERS = [[
# Scripted triggers called by the main event sdc.1 (made by make_docs_mod.lua): a plain one,
# one with parameters (one with a default), and one with [[PARAM] ... ] blocks.
sdc_trigger_plain = {
	always = no
}
sdc_trigger_param = {
	has_country_flag = sdc_$FLAG$
	num_owned_colonies > $COUNT|1$
}
sdc_trigger_conditional = {
	[[FLAG]
		has_country_flag = $FLAG$
	]
	[[!FLAG]
		always = no
	]
}
]]

local SCRIPTED_EFFECTS = [[
# Scripted effects called by the main event sdc.1 (made by make_docs_mod.lua): a plain one,
# one with parameters, one with [[PARAM] ... ] blocks and optimize_memory, and one with inline
# math on a parameter.
sdc_effect_plain = {
	log = "sdc"
}
sdc_effect_param = {
	set_country_flag = sdc_$FLAG$
	add_resource = { energy = $AMOUNT|1$ }
}
sdc_effect_conditional = {
	optimize_memory
	[[FLAG]
		set_country_flag = $FLAG$
	]
	[[!FLAG]
		set_country_flag = sdc_flag
	]
}
sdc_effect_math = {
	add_resource = { minerals = @\[ $AMOUNT$ * 2 + 1 ] }
}
]]

local SCRIPTED_CALLS_TRIGGER = {
    "sdc_trigger_plain = yes",
    "sdc_trigger_param = { FLAG = test COUNT = 3 }",
    "sdc_trigger_param = { FLAG = test }",
    "sdc_trigger_conditional = { FLAG = sdc_flag }",
    "sdc_trigger_conditional = yes",
}
local SCRIPTED_CALLS_EFFECT = {
    "sdc_effect_plain = yes",
    "sdc_effect_param = { FLAG = test AMOUNT = 5 }",
    "sdc_effect_conditional = { FLAG = sdc_flag }",
    "sdc_effect_conditional = yes",
    "sdc_effect_math = { AMOUNT = 2 }",
}

---------------------------------------------------------------------------------------------------
-- Localisation commands and the main event

-- How each section of localizations.log is reached from the main event (a country event):
-- `prefix` is written before the command; `save` is a path of links or random_ iterators (from
-- the country) whose end is saved as the event target the commands start from.
local LOC_SECTIONS = {
    ["Base Scope"] = { prefix = "" },
    ["Unscoped"] = { prefix = "" },
    ["Country"] = { prefix = "Root" },
    ["Leader"] = { prefix = "Root.Ruler" },
    ["Species"] = { prefix = "Root.Species" },
    ["Federation"] = { prefix = "Root.Federation" },
    ["Planet"] = { save = { "capital_star" } },
    ["Colony"] = { save = { "capital_scope" } },
    ["System"] = { save = { "capital_scope", "solar_system" } },
    ["Pop Group"] = { save = { "capital_scope", "random_owned_pop_group" } },
    ["Ship (and Starbase)"] = { save = { "random_owned_ship" } },
    ["Fleet"] = { save = { "random_owned_fleet" } },
    ["Army"] = { save = { "random_owned_army" } },
    ["Ambient Object"] = { save = { "capital_scope", "solar_system",
        "random_system_ambient_object" } },
    ["War"] = { save = { "random_war" } },
    ["Pop Faction"] = { save = { "random_pop_faction" } },
    ["Archaeological Site"] = { save = { "random_archaeological_site" } },
    ["First Contact"] = { save = { "random_first_contact" } },
    ["Espionage Operation"] = { save = { "random_espionage_operation" } },
    ["Espionage Asset"] = { save = { "random_espionage_operation", "random_espionage_asset" } },
    ["Spy Network"] = { save = { "random_spynetwork" } },
    ["Deposit"] = { save = { "capital_star", "random_deposit" } },
    ["Megastructure"] = { save = { "random_owned_megastructure" } },
    ["Sector"] = { save = { "random_owned_sector" } },
    ["Agreement"] = { save = { "random_agreement" } },
    ["Situation"] = { save = { "random_situation" } },
    ["Debris"] = { save = { "random_available_debris" } },
    ["Astral Rift"] = { save = { "random_astral_rift" } },
    ["Bypass"] = { save = { "random_bypass" } },
    ["Cosmic Storm"] = { save = { "random_cosmic_storm" } },
    ["Timeline Event"] = { skip = "timeline event: only the localisation of "
        .. "common/timeline_events has one" },
    ["Patron Relation"] = { skip = "patron relation: only patron localisation has one" },
    ["Specimen"] = { skip = "specimen: only specimen localisation has one" },
}
-- The command a promotion is followed by (a promotion leads to an object, not to text).
local AFTER_PROMOTION = { SpyNetwork = "Owner.GetName" }

local function loc_section(section)
    if section:find("^Dead ") then
        return { skip = "dead object: only timeline localisation has one" }
    end
    return LOC_SECTIONS[section] or { skip = "section without a known way to reach it" }
end

-- The loc items: { key, text, section, kind, name } in manifest order, and the effects that
-- save the event targets.
local loc_items, loc_saves = {}, {}
local function build_loc()
    local saved = {}
    local n = 0
    local list = {}
    for _, item in ipairs(docs.localizations) do
        list[#list + 1] = item
    end
    table.sort(list, function(a, b)
        if a.section ~= b.section then
            return a.section < b.section
        elseif a.kind ~= b.kind then
            return a.kind < b.kind
        end
        return a.name < b.name
    end)
    for _, item in ipairs(list) do
        local section = loc_section(item.section)
        local manifest_name = item.section .. ": " .. item.name
            .. (item.kind == "promotion" and " (promotion)" or "")
        if section.skip then
            skip("localization", manifest_name, section.skip)
        else
            local prefix = section.prefix
            if section.save then
                prefix = NAMESPACE .. "_loc_" .. slug(item.section)
                if not saved[prefix] then
                    saved[prefix] = true
                    for _, key in ipairs(section.save) do
                        assert(by_kind.link[key] or by_kind.effect[key],
                            item.section .. ": no link or effect " .. key)
                    end
                    loc_saves[#loc_saves + 1] = { path = section.save, target = prefix }
                end
            end
            local command
            if item.kind == "promotion" then
                command = (prefix ~= "" and prefix .. "." or "") .. item.name .. "."
                    .. (AFTER_PROMOTION[item.name] or "GetName")
            else
                command = (prefix ~= "" and prefix .. "." or "") .. item.name
            end
            n = n + 1
            loc_items[#loc_items + 1] = {
                key = string.format("%s_loc_%04d_%s", NAMESPACE, n, item.name),
                text = "[" .. command .. "]", manifest_name = manifest_name,
                scope = item.section .. " via " .. (prefix ~= "" and prefix or "unscoped"),
            }
        end
    end
end

build_loc()

-- The anchor events: one per event type, with the fixed ids sdc.1, sdc.2 ... that the
-- X_event effects refer to. The first, a country event, is the main one: it is shown (title,
-- desc, option), its desc holds every localisation command and the desc triggers, its trigger
-- calls the scripted triggers and its option the scripted effects.
local function write_anchors()
    local f = new_file("events/sdc_anchors.txt")
    files[#files + 1] = f
    add_line(f, "# The anchor events (made by make_docs_mod.lua): sdc.1 shows every localisation")
    add_line(f, "# command and calls the scripted triggers and effects; the others are the "
        .. "events the")
    add_line(f, "# X_event effects refer to. None of them fires.")
    add_line(f, "namespace = " .. NAMESPACE)
    for i, t in ipairs(ANCHOR_TYPES) do
        local id = ANCHOR_ID[t]
        add_line(f, "")
        add_line(f, t .. " = {")
        add_line(f, "\tid = " .. id)
        if i > 1 then
            add_line(f, "\thide_window = yes")
            add_line(f, "\tis_triggered_only = yes")
            add_line(f, "\ttrigger = { always = no }")
            add_line(f, "\timmediate = { log = \"sdc\" }")
        else
            add_line(f, "\ttitle = " .. id .. ".name")
            -- an event with a window needs a picture (error.log: "has no pictures")
            add_line(f, "\tpicture = GFX_evt_alien_nature")
            add_line(f, "\tdesc = {")
            add_line(f, "\t\ttrigger = {")
            for _, use in ipairs(uses.trigger) do
                if use.where == "desc" and not use.skip then
                    local line = add_statements(f, "\t\t\t", use.text, use.name)
                    place("trigger", use.name, f, line, use.scope, use.source)
                end
            end
            add_line(f, "\t\t}")
            add_line(f, "\t}")
            add_line(f, "\tis_triggered_only = yes")
            add_line(f, "\ttrigger = {")
            add_line(f, "\t\talways = no")
            for _, call in ipairs(SCRIPTED_CALLS_TRIGGER) do
                add_line(f, "\t\t" .. call)
            end
            add_line(f, "\t}")
            add_line(f, "\timmediate = {")
            for _, s in ipairs(loc_saves) do
                local indent = "\t\t"
                for _, key in ipairs(s.path) do
                    add_line(f, indent .. key .. " = {")
                    indent = indent .. "\t"
                end
                add_line(f, indent .. "save_event_target_as = " .. s.target)
                for _ = 1, #s.path do
                    indent = indent:sub(2)
                    add_line(f, indent .. "}")
                end
            end
            add_line(f, "\t}")
            add_line(f, "\toption = {")
            add_line(f, "\t\tname = " .. NAMESPACE .. "_option")
            for _, call in ipairs(SCRIPTED_CALLS_EFFECT) do
                add_line(f, "\t\t" .. call)
            end
            if static_names[1] then
                add_line(f, "\t\tadd_modifier = { modifier = " .. static_names[1].name
                    .. " days = 1 }")
            end
            add_line(f, "\t}")
        end
        add_line(f, "}")
    end
end

write_anchors()

-- The control-flow keywords in the forms vanilla writes them (upper case AND/OR/NOT/NOR/NAND,
-- if/else_if/else chains, while, random_list with modifiers, switch, hidden_effect); the
-- documented lower-case names are in sdc_triggers.txt and sdc_effects.txt.
local CONTROL_FLOW = [[
# Control-flow keywords in the forms vanilla writes them (made by make_docs_mod.lua).
namespace = sdc

country_event = {
	id = sdc.99
	hide_window = yes
	is_triggered_only = yes
	trigger = {
		always = no
		AND = { always = yes is_ai = no }
		OR = { always = no is_ai = yes }
		NOT = { always = yes }
		NOR = { always = yes is_ai = yes }
		NAND = { always = yes is_ai = no }
		if = { limit = { is_ai = yes } always = yes }
		else_if = { limit = { is_ai = no } always = no }
		else = { always = yes }
		count_owned_colony = { limit = { is_capital = yes } count > 0 }
		any_owned_colony = { is_capital = yes }
	}
	immediate = {
		if = {
			limit = { is_ai = yes }
			set_country_flag = sdc_flag
		}
		else_if = {
			limit = { is_ai = no }
			remove_country_flag = sdc_flag
		}
		else = {
			log = "sdc"
		}
		while = {
			limit = { has_country_flag = sdc_flag }
			remove_country_flag = sdc_flag
		}
		while = {
			count = 2
			log = "sdc"
		}
		random_list = {
			10 = {
				modifier = { factor = 2 is_ai = yes }
				log = "sdc"
			}
			90 = { }
		}
		switch = {
			trigger = has_ethic
			ethic_xenophile = { log = "sdc" }
			default = { log = "sdc" }
		}
		hidden_effect = {
			every_owned_colony = {
				limit = { is_capital = no }
				log = "sdc"
			}
			random_owned_colony = {
				limit = { is_capital = yes }
				weights = { base = 1 modifier = { factor = 2 is_capital = yes } }
				log = "sdc"
			}
			ordered_owned_colony = {
				limit = { is_capital = no }
				order_by = trigger:planet_size
				position = 0
				log = "sdc"
			}
		}
	}
}
]]

---------------------------------------------------------------------------------------------------
-- Localisation file

local function write_localisation()
    local f = new_file("localisation/english/sdc_l_english.yml")
    files[#files + 1] = f
    f.bom = true
    add_line(f, "l_english:")
    add_line(f, " # made by make_docs_mod.lua")
    add_line(f, " " .. NAMESPACE .. ".1.name:0 \"" .. MOD_NAME .. "\"")
    local refs = {}
    for _, item in ipairs(loc_items) do
        refs[#refs + 1] = "$" .. item.key .. "$"
    end
    add_line(f, " " .. NAMESPACE .. ".1.desc:0 \"" .. table.concat(refs, " ") .. "\"")
    add_line(f, " " .. NAMESPACE .. "_option:0 \"OK\"")
    add_line(f, " " .. NAMESPACE .. "_text:0 \"" .. MOD_NAME .. " text\"")
    for _, s in ipairs(static_names) do
        add_line(f, " " .. s.name .. ":0 \"" .. MOD_NAME .. ": " .. s.category .. "\"")
    end
    add_line(f, " # every localisation command, one per key")
    for _, item in ipairs(loc_items) do
        local line = add_line(f, " " .. item.key .. ":0 \"" .. item.text .. "\"")
        place("localization", item.manifest_name, f, line, item.scope, "")
    end
end

write_localisation()

---------------------------------------------------------------------------------------------------
-- Output

local function file_text(f)
    return (f.bom and "\239\187\191" or "") .. table.concat(f.lines, "\n") .. "\n"
end

make_dir(out_dir)
local out_abs = assert(absolute(out_dir), "cannot create " .. out_dir)
for _, f in ipairs(files) do
    write_file(out_abs .. "/" .. f.path, file_text(f))
end
local control = new_file("events/sdc_control_flow.txt")
write_file(out_abs .. "/" .. control.path, CONTROL_FLOW)
write_file(out_abs .. "/common/scripted_triggers/sdc_scripted_triggers.txt", SCRIPTED_TRIGGERS)
write_file(out_abs .. "/common/scripted_effects/sdc_scripted_effects.txt", SCRIPTED_EFFECTS)

local version = game_version()
local supported_version = (version:match("^(v%d+%.%d+)") or version) .. ".*"
local descriptor = table.concat({
    'version="1.0"',
    "tags={",
    '\t"Utilities"',
    "}",
    'name="' .. MOD_NAME .. '"',
    'supported_version="' .. supported_version .. '"',
}, "\n") .. "\n"
write_file(out_abs .. "/descriptor.mod", descriptor)
write_file(out_abs .. ".mod", descriptor .. 'path="' .. out_abs .. '"\n')

local KIND_ORDER = { trigger = 1, effect = 2, link = 3, modifier = 4, localization = 5 }
table.sort(manifest, function(a, b)
    if a.kind ~= b.kind then
        return KIND_ORDER[a.kind] < KIND_ORDER[b.kind]
    end
    return a.name < b.name
end)
local rows = { "kind\tname\tfile\tline\tscope\tstatus\tsource" }
for _, m in ipairs(manifest) do
    rows[#rows + 1] = table.concat({ m.kind, m.name, m.file, tostring(m.line), m.scope,
        m.status, m.source }, "\t")
end
write_file(out_abs .. "/manifest.tsv", table.concat(rows, "\n") .. "\n")

if review_path then
    local r = {}
    for _, kind in ipairs({ "trigger", "effect" }) do
        for _, use in ipairs(uses[kind]) do
            if use.skip then
                r[#r + 1] = string.format("%s %s SKIP %s", kind, use.name, use.skip)
            else
                r[#r + 1] = string.format("%s %s [%s] %s%s\n%s", kind, use.name, use.scope,
                    use.source, use.note and (" (" .. use.note .. ")") or "", use.text)
            end
        end
    end
    write_file(review_path, table.concat(r, "\n") .. "\n")
end

---------------------------------------------------------------------------------------------------
-- Checks: every script file parses without a warning, every manifest line holds its keyword,
-- and every documented item has a row.

local failures = 0
local function fail(message)
    failures = failures + 1
    io.stderr:write("check: " .. message .. "\n")
end

local written = list_files(out_abs, "common", "txt")
for _, p in ipairs(list_files(out_abs, "events", "txt")) do
    written[#written + 1] = p
end
local lines_of = {}
for _, p in ipairs(written) do
    local text = read_file(out_abs .. "/" .. p)
    local tree, message = pdxscript.parse(text, p)
    if tree == nil then
        fail(message)
    elseif #tree.warnings > 0 then
        for _, w in ipairs(tree.warnings) do
            fail(p .. ":" .. w.line .. ": " .. w.kind .. ": " .. w.message)
        end
    end
    local lines = {}
    for line in text:gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line
    end
    lines_of[p] = lines
end
do
    local lines = {}
    for line in read_file(out_abs .. "/localisation/english/sdc_l_english.yml"):gmatch(
        "([^\n]*)\n") do
        lines[#lines + 1] = line
    end
    lines_of["localisation/english/sdc_l_english.yml"] = lines
end

local rows_of = { trigger = {}, effect = {}, link = {}, modifier = {}, localization = {} }
for _, m in ipairs(manifest) do
    rows_of[m.kind][m.name] = true
    if m.status == "placed" then
        local line = lines_of[m.file] and lines_of[m.file][m.line]
        local word = m.kind == "localization" and m.name:match(": (%S+)") or m.name
        if line == nil or not line:find(word, 1, true) then
            fail(m.kind .. " " .. m.name .. ": " .. m.file .. ":" .. tostring(m.line)
                .. " does not hold it")
        end
    end
end
for kind, list in pairs({ trigger = docs.triggers, effect = docs.effects, link = docs.links,
    modifier = docs.modifiers }) do
    for _, e in ipairs(list) do
        if not rows_of[kind][e.name] then
            fail(kind .. " " .. e.name .. ": no manifest row")
        end
    end
end
local loc_rows = 0
for _ in pairs(rows_of.localization) do
    loc_rows = loc_rows + 1
end
if loc_rows ~= #docs.localizations then
    fail(string.format("localization: %d rows for %d commands", loc_rows,
        #docs.localizations))
end

-- Summary
local counts = {}
for _, m in ipairs(manifest) do
    local c = counts[m.kind] or { total = 0, placed = 0, skipped = 0 }
    counts[m.kind] = c
    c.total = c.total + 1
    if m.status == "placed" then
        c.placed = c.placed + 1
    else
        c.skipped = c.skipped + 1
    end
end
print("mod: " .. out_abs .. " (supported_version " .. supported_version .. ")")
for _, kind in ipairs({ "trigger", "effect", "link", "modifier", "localization" }) do
    local c = counts[kind]
    if c then
        print(string.format("%-12s %6d total %6d placed %6d skipped", kind, c.total, c.placed,
            c.skipped))
    end
end
local twice = docs.trigger_duplicates + docs.effect_duplicates + docs.link_duplicates
    + docs.modifier_duplicates
if twice > 0 then
    print(string.format("names the documentation writes twice (one row each): %d", twice))
end
print(string.format("files checked: %d script files, %d problems", #written, failures))
os.exit(failures == 0 and 0 or 1)
