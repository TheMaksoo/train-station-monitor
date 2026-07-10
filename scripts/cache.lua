-- ---------------------------------------------------------------------------
-- scripts/cache.lua
-- ---------------------------------------------------------------------------
-- Owns the entire persistent data schema (Factorio 2.0 `storage`). No other
-- module touches `storage` directly — they go through these accessors. That is
-- what keeps state ownership clear and prevents "global spaghetti".
--
-- Schema
-- ------
-- storage.stations : map<unit_number, StationRecord>   -- the authoritative cache
--   StationRecord = {
--     unit_number, entity,           -- LuaEntity (re-validated on read)
--     name,                          -- last known backer_name
--     kind, proto, mode, group_key,  -- parsed descriptor (see parser.lua)
--     sprite,
--     disabled_by_mod,               -- did WE disable it? (to restore limit)
--     saved_limit,                   -- trains_limit before we forced it to 0
--     stats = {                      -- filled by statistics.lua every 60 ticks
--       present, waiting, disabled,  -- booleans / counts for THIS station
--       queue_bucket,                -- 0 / 1 / 2 / 3 ("3+")
--       state,                       -- "present"|"waiting"|"idle"|"disabled"|"no_path"
--     },
--     wait = { last_arrival_tick, samples = {..}, avg },  -- avg-wait tracker
--   }
--
-- storage.groups : map<group_key, GroupRecord>          -- rebuilt from stations
--   (derived view for the GUI; never the source of truth)
--
-- storage.players : map<player_index, PlayerUiState>
--   PlayerUiState = { open, sort, filters={...}, search, expanded={group_key=bool} }
-- ---------------------------------------------------------------------------

local cache = {}

-- Default per-player UI state. Centralised so the GUI and renderer agree.
local function default_ui_state()
  return {
    open   = false,
    sort   = "waiting",     -- see rendering.SORTERS
    search = "",
    filters = {
      load_only     = false,
      unload_only   = false,
      hide_healthy  = false,
      only_queues   = false,
      only_disabled = false,
    },
    expanded = {},          -- group_key -> true when the row is expanded
  }
end
cache.default_ui_state = default_ui_state

--- Initialise the schema. Idempotent — safe to call from on_init AND on the
--- migration path in on_configuration_changed.
function cache.init()
  storage.stations = storage.stations or {}
  storage.groups   = storage.groups   or {}
  storage.players  = storage.players  or {}
end

-- Stations -----------------------------------------------------------------

--- Insert or replace a station record from a parsed descriptor + entity.
function cache.put_station(entity, parsed)
  local un = entity.unit_number
  local existing = storage.stations[un]
  storage.stations[un] = {
    unit_number     = un,
    entity          = entity,
    name            = entity.backer_name,
    kind            = parsed.kind,
    proto           = parsed.proto,
    mode            = parsed.mode,
    group_key       = parsed.group_key,
    sprite          = parsed.sprite,
    disabled_by_mod = existing and existing.disabled_by_mod or false,
    saved_limit     = existing and existing.saved_limit or nil,
    stats           = existing and existing.stats or { queue_bucket = 0, state = "idle" },
    wait            = existing and existing.wait or { samples = {}, avg = 0 },
  }
  return storage.stations[un]
end

function cache.remove_station(unit_number)
  storage.stations[unit_number] = nil
end

function cache.get_station(unit_number)
  return storage.stations[unit_number]
end

--- Iterate valid stations, transparently pruning any whose entity died without
--- an event we caught (defensive; should be rare thanks to discovery.lua).
function cache.each_station(fn)
  for un, rec in pairs(storage.stations) do
    if rec.entity and rec.entity.valid then
      fn(un, rec)
    else
      storage.stations[un] = nil
    end
  end
end

function cache.station_count()
  local n = 0
  for _ in pairs(storage.stations) do n = n + 1 end
  return n
end

-- Groups (derived) ----------------------------------------------------------

--- Rebuild the derived group view from the station cache. Called by statistics
--- after it refreshes numbers, so the GUI always renders a consistent snapshot.
function cache.rebuild_groups()
  local groups = {}
  cache.each_station(function(_, rec)
    local g = groups[rec.group_key]
    if not g then
      g = {
        group_key = rec.group_key,
        kind      = rec.kind,
        proto     = rec.proto,
        sprite    = rec.sprite,
        load      = 0,
        unload    = 0,
        stations  = {},   -- array of station records
        present   = 0,
        waiting   = 0,
        qcap      = 0,    -- total slots that can wait across the group
        saturation= 0,    -- waiting / qcap (0 = starved, >=1 = fully saturated)
        congestion= 0,    -- 0..1 by average train wait (heatmap lens)
        disabled  = 0,
        wait_avg  = 0,
      }
      groups[rec.group_key] = g
    end
    g[rec.mode] = g[rec.mode] + 1
    g.stations[#g.stations + 1] = rec
  end)
  storage.groups = groups
  return groups
end

function cache.groups()
  return storage.groups or {}
end

-- Player UI state -----------------------------------------------------------

function cache.ui(player_index)
  local s = storage.players[player_index]
  if not s then
    s = default_ui_state()
    storage.players[player_index] = s
  end
  return s
end

return cache
