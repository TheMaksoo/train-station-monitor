-- ---------------------------------------------------------------------------
-- scripts/discovery.lua
-- ---------------------------------------------------------------------------
-- Keeps the station cache in perfect sync with the world using ONLY events —
-- the map is never scanned tick-by-tick. The single full scan below runs once
-- on init / config-changed (e.g. when the mod is added to an existing save) to
-- back-fill stations that were built before the mod existed.
--
-- Every world mutation of a train-stop funnels through add() / remove() /
-- rename(), so 1000+ stations cost nothing at runtime beyond the rare event.
-- ---------------------------------------------------------------------------

local cache  = require("scripts.cache")
local parser = require("scripts.parser")

local discovery = {}

--- Add (or refresh) a single train-stop entity in the cache.
-- Non train-stops and unparseable names are silently ignored.
function discovery.add(entity)
  if not (entity and entity.valid and entity.type == "train-stop") then return end
  local parsed = parser.parse(entity.backer_name)
  if not parsed then
    -- Name isn't (or is no longer) a tracked resource station. If it used to
    -- be tracked, drop it — this handles a rename FROM a valid TO an invalid name.
    if entity.unit_number then cache.remove_station(entity.unit_number) end
    return
  end
  cache.put_station(entity, parsed)
end

--- Remove a train-stop from the cache (mined / died / destroyed).
function discovery.remove(entity)
  if entity and entity.valid and entity.unit_number then
    cache.remove_station(entity.unit_number)
  end
end

-- Event adapters ------------------------------------------------------------
-- These match the Factorio event payload shapes. They are registered by
-- scripts/events.lua with a {type = "train-stop"} filter where the event
-- supports one, so the game only calls us for the right entity.

function discovery.on_built(event)
  discovery.add(event.entity or event.created_entity)
end

function discovery.on_removed(event)
  discovery.remove(event.entity)
end

function discovery.on_cloned(event)
  -- Cloned stops get a fresh unit_number, so just add the destination.
  discovery.add(event.destination)
end

function discovery.on_renamed(event)
  -- on_entity_renamed cannot be event-filtered, so gate on type here.
  local e = event.entity
  if e and e.valid and e.type == "train-stop" then
    discovery.add(e) -- add() re-parses and re-keys, or drops if now invalid
  end
end

--- Full re-scan of every surface. Only used on init / config change — NOT per
--- tick. Uses find_entities_filtered(type) which is a fast indexed lookup.
function discovery.rescan_all()
  cache.init()
  storage.stations = {}
  for _, surface in pairs(game.surfaces) do
    local stops = surface.find_entities_filtered({ type = "train-stop" })
    for _, stop in pairs(stops) do
      discovery.add(stop)
    end
  end
end

return discovery
