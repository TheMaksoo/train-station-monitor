-- ---------------------------------------------------------------------------
-- scripts/events.lua
-- ---------------------------------------------------------------------------
-- The ONE place that talks to script.on_event / on_nth_tick. Everything else
-- exposes plain functions; this module wires them to the game. If you want to
-- know "what makes this mod tick", read this file top to bottom.
--
-- Cadence
--   * world changes (build/mine/rename/clone) -> instant, event-filtered
--   * train state changes                      -> instant, feeds avg-wait
--   * statistics + GUI repaint                 -> once per second (nth_tick 60)
-- The map is never scanned per tick.
-- ---------------------------------------------------------------------------

local cache      = require("scripts.cache")
local discovery  = require("scripts.discovery")
local statistics = require("scripts.statistics")
local throughput = require("scripts.throughput")
local heatmap    = require("scripts.heatmap")
local alerts     = require("scripts.alerts")
local gui        = require("scripts.gui")
local parser     = require("scripts.parser")

local events = {}

-- Entity filter reused for every build/remove event that supports filtering.
local STOP_FILTER = { { filter = "type", type = "train-stop" } }

-- Lifecycle -----------------------------------------------------------------

local function on_init()
  cache.init()
  throughput.init()
  heatmap.init()
  alerts.init()
  discovery.rescan_all()          -- back-fill any pre-existing stops
  for _, p in pairs(game.players) do gui.ensure_button(p) end
end

local function on_configuration_changed()
  cache.init()
  throughput.init()
  heatmap.init()
  alerts.init()
  discovery.rescan_all()          -- re-sync after add/update/remove of mods
  for _, p in pairs(game.players) do gui.ensure_button(p) end
end

local function on_player_created(event)
  gui.ensure_button(game.get_player(event.player_index))
end

-- Per-second refresh --------------------------------------------------------

local function on_second()
  statistics.refresh_all()        -- recompute cached stats + grouped view
  alerts.refresh_all()            -- raise/refresh no-provider alerts
  gui.refresh_all_open()          -- repaint only windows that are open
  heatmap.refresh_all()           -- redraw map overlay for players who enabled it
end

-- Train state -> avg-wait feed ----------------------------------------------

local function on_train_changed_state(event)
  local train = event.train
  if not (train and train.valid) then return end
  local states = defines.train_state
  -- When a train is parked and waiting at a stop, mark arrival; when it starts
  -- moving again (on_the_path / arrive), mark departure. O(1), no polling.
  local stop = train.station
  if not (stop and stop.valid and stop.unit_number) then return end
  local rec = cache.get_station(stop.unit_number)
  if not rec then return end

  if train.state == states.wait_station or train.state == states.wait_signal then
    statistics.mark_arrival(rec, event.tick or game.tick)
  elseif event.old_state == states.wait_station then
    statistics.mark_departure(rec, event.tick or game.tick)
    throughput.record(rec.group_key) -- one train served -> throughput graph
  end
end

-- Toggle input / shortcut ---------------------------------------------------

local function on_toggle_input(event)
  gui.toggle(game.get_player(event.player_index))
end

local function on_lua_shortcut(event)
  if event.prototype_name ~= "tod-toggle-dashboard" then return end
  gui.toggle(game.get_player(event.player_index))
end

-- Registration --------------------------------------------------------------

function events.register()
  script.on_init(on_init)
  script.on_configuration_changed(on_configuration_changed)
  script.on_event(defines.events.on_player_created, on_player_created)

  -- Discovery: build / revive / cloned
  script.on_event(defines.events.on_built_entity,        discovery.on_built,  STOP_FILTER)
  script.on_event(defines.events.on_robot_built_entity,  discovery.on_built,  STOP_FILTER)
  script.on_event(defines.events.on_space_platform_built_entity, discovery.on_built, STOP_FILTER)
  script.on_event(defines.events.script_raised_built,    discovery.on_built,  STOP_FILTER)
  script.on_event(defines.events.script_raised_revive,   discovery.on_built,  STOP_FILTER)
  script.on_event(defines.events.on_entity_cloned,       discovery.on_cloned, STOP_FILTER)

  -- Discovery: mine / die / destroy
  script.on_event(defines.events.on_player_mined_entity, discovery.on_removed, STOP_FILTER)
  script.on_event(defines.events.on_robot_mined_entity,  discovery.on_removed, STOP_FILTER)
  script.on_event(defines.events.on_space_platform_mined_entity, discovery.on_removed, STOP_FILTER)
  script.on_event(defines.events.on_entity_died,         discovery.on_removed, STOP_FILTER)
  script.on_event(defines.events.script_raised_destroy,  discovery.on_removed, STOP_FILTER)

  -- Rename cannot be event-filtered; discovery gates on entity.type.
  script.on_event(defines.events.on_entity_renamed,      discovery.on_renamed)

  -- Train state feed for average-wait tracking.
  script.on_event(defines.events.on_train_changed_state, on_train_changed_state)

  -- GUI interaction.
  script.on_event(defines.events.on_gui_click,             gui.on_click)
  script.on_event(defines.events.on_gui_selection_state_changed, gui.on_selection)
  script.on_event(defines.events.on_gui_checked_state_changed,   gui.on_checked)
  script.on_event(defines.events.on_gui_text_changed,      gui.on_text)
  script.on_event(defines.events.on_gui_closed, function(e)
    if e.element and e.element.valid and e.element.name == "tod_window" then
      gui.close(game.get_player(e.player_index))
    end
  end)

  -- Keybind toggle.
  script.on_event("tod-toggle-dashboard", on_toggle_input)
  script.on_event(defines.events.on_lua_shortcut, on_lua_shortcut)

  -- The only periodic work: statistics + repaint once per second, and the
  -- throughput ring buffer rolls once per minute.
  script.on_nth_tick(60, on_second)
  script.on_nth_tick(3600, throughput.roll)
end

return events
