-- ---------------------------------------------------------------------------
-- scripts/heatmap.lua
-- ---------------------------------------------------------------------------
-- Congestion heatmap drawn directly on the MAP (the Factorio-native form of a
-- heatmap) using the rendering API: one coloured, filled circle per station,
-- tinted by the SUPPLY GAP (statistics.lua congestion). Cool = trains flowing
-- or already waiting; hot = starved, a long gap until the next train arrives.
-- Disabled stations render grey (not part of the supply picture).
--
-- It is per-player and opt-in (toggled from the dashboard toolbar), only drawn
-- for stations on the surface the player is currently viewing, and redrawn on
-- the same once-per-second stats tick. When off, all render objects are
-- destroyed so it costs nothing.
--
-- Schema:  storage.heatmap = { players = { [player_index] = { enabled, objs } } }
--   objs : array of LuaRenderObject to destroy on clear/redraw
-- ---------------------------------------------------------------------------

local cache = require("scripts.cache")

local heatmap = {}

function heatmap.init()
  storage.heatmap = storage.heatmap or { players = {} }
end

local function state_for(player_index)
  local p = storage.heatmap.players[player_index]
  if not p then p = { enabled = false, objs = {} }; storage.heatmap.players[player_index] = p end
  return p
end

--- Cool -> hot colour ramp: green (flowing/supplied) -> amber -> red (starved).
local function heat_color(t)
  t = math.max(0, math.min(1, t))
  local S = { { 0.29, 0.59, 0.35 }, { 0.88, 0.70, 0.23 }, { 0.82, 0.28, 0.24 } }
  local a, b, f
  if t <= 0.5 then a, b, f = S[1], S[2], t / 0.5 else a, b, f = S[2], S[3], (t - 0.5) / 0.5 end
  return {
    r = a[1] + (b[1] - a[1]) * f,
    g = a[2] + (b[2] - a[2]) * f,
    b = a[3] + (b[3] - a[3]) * f,
    a = 0.60,
  }
end

--- Destroy all render objects for a player.
local function clear(p)
  for _, obj in ipairs(p.objs) do
    if obj.valid then obj.destroy() end
  end
  p.objs = {}
end

function heatmap.is_enabled(player_index)
  return state_for(player_index).enabled
end

--- Draw (or redraw) the heatmap for one player on their current surface.
function heatmap.redraw(player)
  local p = state_for(player.index)
  clear(p)
  if not p.enabled then return end
  local surface = player.surface
  cache.each_station(function(_, rec)
    local e = rec.entity
    if e.surface ~= surface then return end
    local color
    if rec.stats and rec.stats.disabled then
      color = { r = 0.5, g = 0.5, b = 0.5, a = 0.45 } -- grey: out of the supply picture
    else
      color = heat_color((rec.stats and rec.stats.congestion) or 0)
    end
    p.objs[#p.objs + 1] = rendering.draw_circle({
      color         = color,
      radius        = 2.2,
      filled        = true,
      target        = e.position,
      surface       = surface,
      players       = { player },
      draw_on_ground = true,
    })
  end)
end

--- Turn the heatmap on/off for a player.
function heatmap.set(player, enabled)
  local p = state_for(player.index)
  p.enabled = enabled
  heatmap.redraw(player)
end

--- Refresh every player who has the heatmap enabled (called each stats tick).
function heatmap.refresh_all()
  for _, player in pairs(game.connected_players) do
    if heatmap.is_enabled(player.index) then heatmap.redraw(player) end
  end
end

return heatmap
