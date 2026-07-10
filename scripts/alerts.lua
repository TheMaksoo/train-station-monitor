-- ---------------------------------------------------------------------------
-- scripts/alerts.lua
-- ---------------------------------------------------------------------------
-- Raises "no available provider" alerts: a resource that has consumers (Unload
-- stations) but no available provider (no Load station at all, or every Load
-- station disabled). These are surfaced two ways:
--
--   1. Native Factorio alerts (player.add_custom_alert) anchored on a consumer
--      station, with the resource's own icon — they appear in the alert flow
--      and on the map, exactly like low-power / no-fuel alerts.
--   2. storage.alerts (a plain list) which the dashboard reads to show a count
--      badge + banner.
--
-- Runs on the once-per-second stats tick, off the cached group view — no scan.
--
-- Schema:  storage.alerts = { { group_key, level, kind, count }, ... }
--   kind : "no_provider" | "providers_disabled"
-- ---------------------------------------------------------------------------

local cache = require("scripts.cache")

local alerts = {}

function alerts.init()
  storage.alerts = storage.alerts or {}
end

--- Recompute the active alert list from the grouped view.
function alerts.compute()
  local list = {}
  for key, g in pairs(cache.groups()) do
    local providers, prov_active, consumers = 0, 0, 0
    for _, rec in ipairs(g.stations) do
      if rec.mode == "load" then
        providers = providers + 1
        if not rec.stats.disabled then prov_active = prov_active + 1 end
      else
        consumers = consumers + 1
      end
    end
    if consumers > 0 and providers == 0 then
      list[#list + 1] = { group_key = key, level = "critical", kind = "no_provider" }
    elseif consumers > 0 and prov_active == 0 then
      list[#list + 1] = { group_key = key, level = "critical", kind = "providers_disabled", count = providers }
    end
  end
  storage.alerts = list
  return list
end

--- Pick a still-valid consumer station entity to anchor an alert icon on.
local function anchor_entity(g)
  for _, rec in ipairs(g.stations) do
    if rec.mode == "unload" and rec.entity and rec.entity.valid then return rec.entity end
  end
  for _, rec in ipairs(g.stations) do
    if rec.entity and rec.entity.valid then return rec.entity end
  end
  return nil
end

--- Recompute + push native custom alerts to every player.
function alerts.refresh_all()
  local list = alerts.compute()
  local groups = cache.groups()
  for _, player in pairs(game.connected_players) do
    for _, a in ipairs(list) do
      local g = groups[a.group_key]
      local target = g and anchor_entity(g)
      if target then
        local icon
        if g.kind == "station" then
          icon = { type = "entity", name = "train-stop" }
        else
          icon = { type = g.kind, name = g.proto } -- SignalID (item/fluid/...)
        end
        player.add_custom_alert(target, icon,
          { "tod.alert-" .. a.kind, "[img=" .. g.sprite .. "]", a.count or 0 }, true)
      end
    end
  end
end

--- How many alerts are active right now (for the dashboard badge).
function alerts.count()
  return storage.alerts and #storage.alerts or 0
end

return alerts
