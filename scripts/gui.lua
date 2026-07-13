-- ---------------------------------------------------------------------------
-- scripts/gui.lua
-- ---------------------------------------------------------------------------
-- Owns the top-left button and the dashboard window. Builds the widget tree,
-- opens/closes/refreshes it, and routes every GUI event by element-name prefix.
-- It delegates all row layout to rendering.lua and all mutations to statistics.
--
-- Because it uses vanilla styles (frame / subheader / list_box_item / tables)
-- the window automatically matches whichever UI theme the player picked,
-- including dark mode.
-- ---------------------------------------------------------------------------

local mod_gui    = require("mod-gui")          -- __core__/lualib/mod-gui
local cache      = require("scripts.cache")
local rendering  = require("scripts.rendering")
local statistics = require("scripts.statistics")
local heatmap    = require("scripts.heatmap")
local alerts     = require("scripts.alerts")

local gui = {}

local WINDOW      = "tod_window"
local ROWS_TABLE  = "tod_rows"
local BUTTON      = "tod_open_button"
local N_COLS      = 8 -- resource, load, unload, stations, present, waiting, disabled, wait

-- Top-left button -----------------------------------------------------------

function gui.ensure_button(player)
  local flow = mod_gui.get_button_flow(player)
  if flow[BUTTON] then return end
  flow.add({
    type    = "sprite-button",
    name    = BUTTON,
    style   = mod_gui.button_style,
    sprite  = "item/locomotive",
    tooltip = { "tod.button-tooltip" },
  })
end

-- Window build --------------------------------------------------------------

local FILTER_KEYS = {
  { key = "load_only",     loc = "filter-load-only" },
  { key = "unload_only",   loc = "filter-unload-only" },
  { key = "hide_healthy",  loc = "filter-hide-healthy" },
  { key = "only_queues",   loc = "filter-only-queues" },
  { key = "only_disabled", loc = "filter-only-disabled" },
}

local function build_titlebar(frame, ui)
  local bar = frame.add({ type = "flow", name = "tod_titlebar", direction = "horizontal" })
  bar.drag_target = frame
  bar.style.horizontal_spacing = 8
  local title = bar.add({ type = "label", caption = { "tod.title" }, style = "frame_title" })
  title.drag_target = frame
  local subtitle = bar.add({ type = "label", name = "tod_subtitle", style = "subheader_semibold_label" })
  subtitle.drag_target = frame
  -- No-provider alert count badge (blank when there are none).
  local alert_badge = bar.add({ type = "label", name = "tod_alert_badge" })
  alert_badge.style.font = "default-bold"
  alert_badge.style.font_color = { 0.91, 0.40, 0.30 }
  alert_badge.drag_target = frame
  local heatmap_badge = bar.add({ type = "label", name = "tod_heatmap_badge" })
  heatmap_badge.style.font = "default-bold"
  heatmap_badge.drag_target = frame
  local filler = bar.add({ type = "empty-widget", style = "draggable_space_header" })
  filler.style.horizontally_stretchable = true
  filler.style.height = 24
  filler.drag_target = frame
  bar.add({ type = "sprite-button", name = "tod_close", style = "frame_action_button",
            sprite = "utility/close", hovered_sprite = "utility/close_black", tooltip = { "gui.close-instruction" } })
end

local function build_toolbar(frame, ui)
  local toolbar = frame.add({ type = "frame", name = "tod_toolbar", style = "tod_toolbar_frame", direction = "horizontal" })

  -- Sort dropdown
  toolbar.add({ type = "label", caption = { "tod.sort-label" } })
  local items, selected = {}, 1
  for i, key in ipairs(rendering.SORT_ORDER) do
    items[i] = rendering.SORT_LOCALE[key]
    if key == ui.sort then selected = i end
  end
  toolbar.add({ type = "drop-down", name = "tod_sort", items = items, selected_index = selected })

  toolbar.add({ type = "line", direction = "vertical" })

  -- Congestion heatmap toggle (draws coloured circles on the map).
  toolbar.add({ type = "checkbox", name = "tod_heatmap",
                caption = { "tod.filter-heatmap" }, tooltip = { "tod.tt-heatmap" },
                state = heatmap.is_enabled(frame.player_index) })
  toolbar.add({
    type = "sprite-button",
    name = "tod_heatmap_focus",
    style = "tool_button",
    sprite = "utility/map",
    tooltip = { "tod.tt-heatmap-focus" },
  })

  local legend = toolbar.add({ type = "flow", name = "tod_heatmap_legend", direction = "horizontal" })
  legend.style.horizontal_spacing = 4
  local cool = legend.add({ type = "label", caption = { "tod.heatmap-legend-cool" } })
  cool.style.font_color = { 0.42, 0.80, 0.45 }
  local warm = legend.add({ type = "label", caption = { "tod.heatmap-legend-warm" } })
  warm.style.font_color = { 0.90, 0.73, 0.30 }
  local hot = legend.add({ type = "label", caption = { "tod.heatmap-legend-hot" } })
  hot.style.font_color = { 0.86, 0.34, 0.30 }

  toolbar.add({ type = "line", direction = "vertical" })

  -- Filter checkboxes
  for _, f in ipairs(FILTER_KEYS) do
    toolbar.add({ type = "checkbox", name = "tod_filter__" .. f.key,
                  caption = { "tod." .. f.loc }, state = ui.filters[f.key] })
  end

  local spacer = toolbar.add({ type = "empty-widget" })
  spacer.style.horizontally_stretchable = true

  -- Search
  local search = toolbar.add({ type = "textfield", name = "tod_search", text = ui.search })
  search.style.width = 160
end

local function build_header(container)
  local head = container.add({ type = "table", name = "tod_header", column_count = N_COLS })
  head.style.column_alignments[1] = "left"
  local cols = {
    { "tod.col-resource",  nil },
    { "tod.col-load",      "tod.tt-load" },
    { "tod.col-unload",    "tod.tt-unload" },
    { "tod.col-stations",  "tod.tt-stations" },
    { "tod.col-present",   "tod.tt-present" },
    { "tod.col-saturation","tod.tt-saturation" },
    { "tod.col-disabled",  "tod.tt-disabled" },
    { "tod.col-wait-time", "tod.tt-wait-time" },
  }
  for i, c in ipairs(cols) do
    local lbl = head.add({ type = "label", caption = { c[1] }, tooltip = c[2] and { c[2] } or nil })
    lbl.style.font = "default-bold"
    if i > 1 then lbl.style.width = 64; lbl.style.horizontal_align = "center" end
    if i == 1 then lbl.style.minimal_width = 320 end
  end
end

--- Build the whole window fresh. Returns the frame.
function gui.build_window(player)
  local ui = cache.ui(player.index)
  local frame = player.gui.screen.add({ type = "frame", name = WINDOW,
    style = "tod_dashboard_frame", direction = "vertical" })
  frame.auto_center = true

  build_titlebar(frame, ui)
  build_toolbar(frame, ui)

  -- Column header (kept outside the scroll pane so it stays pinned).
  local head_holder = frame.add({ type = "frame", style = "subheader_frame", direction = "vertical" })
  head_holder.style.horizontally_stretchable = true
  build_header(head_holder)

  -- Scrollable rows.
  local scroll = frame.add({ type = "scroll-pane", name = "tod_scroll", style = "tod_rows_scroll" })
  scroll.style.horizontally_stretchable = true
  local rows = scroll.add({ type = "table", name = ROWS_TABLE, column_count = N_COLS })
  rows.style.horizontal_spacing = 6
  rows.style.vertical_spacing = 4
  rows.style.column_alignments[1] = "left"

  -- Empty-state label (toggled by refresh).
  local empty = scroll.add({ type = "label", name = "tod_empty", caption = { "tod.empty" } })
  empty.style.single_line = false
  empty.style.top_padding = 12
  empty.style.minimal_width = 600

  player.opened = frame
  return frame
end

-- Open / close / refresh ----------------------------------------------------

function gui.get_window(player)
  return player.gui.screen[WINDOW]
end

function gui.open(player)
  local ui = cache.ui(player.index)
  if gui.get_window(player) then gui.close(player) end
  gui.build_window(player)
  ui.open = true
  gui.refresh(player)
end

function gui.close(player)
  local w = gui.get_window(player)
  if w then w.destroy() end
  cache.ui(player.index).open = false
end

function gui.toggle(player)
  if gui.get_window(player) then gui.close(player) else gui.open(player) end
end

--- Repaint rows + subtitle for one open window. Cheap enough to call every
--- second; only rebuilds the rows table, never the whole frame.
function gui.refresh(player)
  local w = gui.get_window(player)
  if not w then return end
  local ui = cache.ui(player.index)

  local rows = w.tod_scroll[ROWS_TABLE]
  local count = rendering.populate(rows, ui)

  local empty = w.tod_scroll.tod_empty
  empty.visible = (count == 0)
  if count == 0 then
    -- distinguish "nothing built" from "everything filtered out"
    empty.caption = (cache.station_count() == 0) and { "tod.empty" } or { "tod.empty-filtered" }
  end

  local groups = cache.groups()
  local ng = 0; for _ in pairs(groups) do ng = ng + 1 end
  w.tod_titlebar.tod_subtitle.caption = { "tod.subtitle", ng, cache.station_count() }
  local na = alerts.count()
  w.tod_titlebar.tod_alert_badge.caption = na > 0 and { "tod.alerts-badge", na } or ""
  local titlebar = w.tod_titlebar
  if titlebar and titlebar.valid then
    local heatmap_badge = titlebar.tod_heatmap_badge
    if not (heatmap_badge and heatmap_badge.valid) then
      heatmap_badge = titlebar.add({ type = "label", name = "tod_heatmap_badge" })
      heatmap_badge.style.font = "default-bold"
    end
    local hm = heatmap.is_enabled(player.index)
    heatmap_badge.caption = hm and { "tod.heatmap-on" } or { "tod.heatmap-off" }
    heatmap_badge.style.font_color = hm and { 0.55, 0.82, 0.42 } or { 0.62, 0.64, 0.68 }
  end
end

--- Refresh every player who has the window open (called after a stats tick).
function gui.refresh_all_open()
  for _, player in pairs(game.connected_players) do
    if gui.get_window(player) then gui.refresh(player) end
  end
end

-- Event routing -------------------------------------------------------------
-- One handler, dispatched by element-name prefix. gui element names encode
-- their argument (group_key or unit_number) after a "__" separator.

local function split(name)
  local prefix, arg = string.match(name, "^(.-)__(.+)$")
  return prefix or name, arg
end

function gui.on_click(event)
  local el = event.element
  if not (el and el.valid) then return end
  local player = game.get_player(event.player_index)
  local ui = cache.ui(event.player_index)
  local prefix, arg = split(el.name)

  if el.name == BUTTON or el.name == "tod_open_button" then
    gui.toggle(player); return
  elseif el.name == "tod_close" then
    gui.close(player); return
  elseif prefix == "tod_group" then
    ui.expanded[arg] = not ui.expanded[arg]
    gui.refresh(player); return
  elseif prefix == "tod_zoom" then
    local rec = cache.get_station(tonumber(arg))
    if rec and rec.entity.valid then
      player.opened = rec.entity
    end
    return
  elseif prefix == "tod_train" then
    local rec = cache.get_station(tonumber(arg))
    if rec and rec.entity.valid then
      local train = rec.entity.get_stopped_train()
      if train and train.front_stock then
        player.opened = train.front_stock
      else
        player.create_local_flying_text({ text = { "tod.station-idle" }, position = rec.entity.position })
      end
    end
    return
  elseif prefix == "tod_toggle" then
    local rec = cache.get_station(tonumber(arg))
    if rec then
      statistics.set_enabled(rec, rec.stats.disabled) -- flip
      gui.refresh(player)
    end
    return
  elseif el.name == "tod_heatmap_focus" then
    if not heatmap.is_enabled(player.index) then
      heatmap.set(player, true)
    end
    local target = heatmap.focus_hotspot(player)
    if target and target.valid then
      player.opened = target
    else
      player.create_local_flying_text({ text = { "tod.heatmap-no-hotspot" }, position = player.position })
    end
    return
  end
end

function gui.on_selection(event)
  local el = event.element
  if not (el and el.valid) then return end
  local player = game.get_player(event.player_index)
  local ui = cache.ui(event.player_index)
  if el.name == "tod_sort" then
    ui.sort = rendering.SORT_ORDER[el.selected_index] or "waiting"
    gui.refresh(player)
  end
end

function gui.on_checked(event)
  local el = event.element
  if not (el and el.valid) then return end
  local prefix, key = split(el.name)
  if el.name == "tod_heatmap" then
    local player = game.get_player(event.player_index)
    heatmap.set(player, el.state)
    gui.refresh(player)
    return
  end
  if prefix == "tod_filter" then
    local player = game.get_player(event.player_index)
    cache.ui(event.player_index).filters[key] = el.state
    gui.refresh(player)
  end
end

function gui.on_text(event)
  local el = event.element
  if not (el and el.valid) then return end
  if el.name == "tod_search" then
    local player = game.get_player(event.player_index)
    cache.ui(event.player_index).search = el.text
    gui.refresh(player)
  end
end

return gui
