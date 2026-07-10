-- ---------------------------------------------------------------------------
-- scripts/rendering.lua
-- ---------------------------------------------------------------------------
-- The "view logic": given the grouped snapshot + a player's UI state, produce
-- the sorted / filtered list, and build the row widgets into a table. It holds
-- NO state of its own and never registers events — gui.lua owns the widgets
-- and wiring, rendering.lua just fills them. This split keeps layout separate
-- from behaviour so either can change independently.
-- ---------------------------------------------------------------------------

local cache = require("scripts.cache")
local throughput = require("scripts.throughput")

local rendering = {}

-- Sorting -------------------------------------------------------------------
-- Each sorter returns a comparator over group records. Add a key here + a
-- locale string + a dropdown item and a new sort mode exists everywhere.
rendering.SORT_ORDER = {
  "waiting", "saturated", "idle", "alpha", "stations", "disabled", "resource",
}
rendering.SORT_LOCALE = {
  waiting   = { "tod.sort-waiting" },
  saturated = { "tod.sort-saturated" },
  idle      = { "tod.sort-idle" },
  alpha     = { "tod.sort-alpha" },
  stations  = { "tod.sort-stations" },
  disabled  = { "tod.sort-disabled" },
  resource  = { "tod.sort-resource" },
}

local function station_total(g) return g.load + g.unload end
local function idle_count(g)     return station_total(g) - g.present - g.disabled end

local SORTERS = {
  -- Default "waiting" now means LEAST saturated first (the stops that need
  -- attention because trains aren't arriving); "saturated" is the inverse.
  waiting   = function(a, b) return (a.saturation or 0) < (b.saturation or 0) end,
  saturated = function(a, b) return (a.saturation or 0) > (b.saturation or 0) end,
  idle      = function(a, b) return idle_count(a) > idle_count(b) end,
  alpha     = function(a, b) return a.proto < b.proto end,
  stations  = function(a, b) return station_total(a) > station_total(b) end,
  disabled  = function(a, b) return a.disabled > b.disabled end,
  resource  = function(a, b) return a.proto < b.proto end,
}

-- Filtering -----------------------------------------------------------------
local function passes_filters(g, ui)
  local f = ui.filters
  if f.load_only     and g.load   == 0 then return false end
  if f.unload_only   and g.unload == 0 then return false end
  if f.only_disabled and g.disabled == 0 then return false end
  if f.only_queues   and g.waiting  == 0 then return false end
  if f.hide_healthy  and (g.saturation or 0) >= 1 then return false end -- hide fully-saturated
  if ui.search ~= "" then
    local needle = string.lower(ui.search)
    if not string.find(string.lower(g.proto), needle, 1, true) then return false end
  end
  return true
end

--- Build the ordered, filtered array of group records for a player.
function rendering.visible_groups(ui)
  local list = {}
  for _, g in pairs(cache.groups()) do
    if passes_filters(g, ui) then list[#list + 1] = g end
  end
  table.sort(list, SORTERS[ui.sort] or SORTERS.waiting)
  return list
end

-- Health colour -------------------------------------------------------------
-- Saturation vocabulary shared by group + station rows. A FULL queue is GOOD:
-- the stop is well supplied, so the scale runs starved(grey) -> saturated(green).
local COLORS = {
  saturated = { 0.55, 0.82, 0.42 }, -- green   fully supplied (best)
  filling   = { 0.76, 0.81, 0.35 }, -- lime    queue building up
  partial   = { 0.95, 0.73, 0.28 }, -- amber   lightly filled
  serving   = { 0.36, 0.70, 0.69 }, -- teal    train being served, empty queue
  idle      = { 0.62, 0.64, 0.68 }, -- grey    starved / nothing waiting
  disabled  = { 0.55, 0.40, 0.72 }, -- purple  off
}
rendering.COLORS = COLORS

--- Map a saturation ratio (0..1+) to a colour.
local function sat_color(r)
  if r <= 0    then return COLORS.idle end
  if r >= 1    then return COLORS.saturated end
  if r >= 0.5  then return COLORS.filling end
  return COLORS.partial
end

local function group_color(g)
  if g.disabled > 0 and g.disabled == station_total(g) then return COLORS.disabled end
  local r = g.saturation or 0
  if r > 0 then return sat_color(r) end
  if g.present > 0 then return COLORS.serving end
  return COLORS.idle
end

--- State -> colour for a single station record.
local function station_color(rec)
  local s = rec.stats
  if s.disabled then return COLORS.disabled end
  if (s.waiting or 0) > 0 then return sat_color(s.saturation or 0) end
  if s.present then return COLORS.serving end
  return COLORS.idle
end

local function has_sprite(signal)
  if type(signal) ~= "table" or type(signal.type) ~= "string" or type(signal.name) ~= "string" then return false end
  local ok, exists = pcall(function()
    if signal.type == "item" then
      return prototypes and prototypes.item and prototypes.item[signal.name] ~= nil
    elseif signal.type == "fluid" then
      return prototypes and prototypes.fluid and prototypes.fluid[signal.name] ~= nil
    end
    return false
  end)
  return ok and exists
end

local function signal_sprite(signal)
  if has_sprite(signal) then
    return signal.type .. "/" .. signal.name
  end
  return "entity/train-stop"
end

-- Row construction ----------------------------------------------------------

--- Numeric cell with an optional tooltip and colour.
local function num_cell(parent, name, value, tooltip, color)
  local lbl = parent.add({ type = "label", name = name, caption = tostring(value), tooltip = tooltip })
  if color then lbl.style.font_color = color end
  lbl.style.width = 64
  lbl.style.horizontal_align = "center"
  return lbl
end

--- Build one resource group row (the collapsed, always-visible line).
-- element names carry the group_key so gui.lua's single click handler can route
-- without maintaining a separate lookup table.
local function build_group_row(tbl, g, ui)
  local expanded = ui.expanded[g.group_key] and true or false

  -- Resource cell = expander button (icon + name), acts as the row toggle.
  local toggle = tbl.add({
    type    = "button",
    name    = "tod_group__" .. g.group_key,
    style   = "list_box_item",
    tooltip = { "tod.tt-resource" },
  })
  toggle.style.horizontally_stretchable = true
  toggle.style.horizontal_align = "left"
  local flow = toggle.add({ type = "flow", direction = "horizontal", ignored_by_interaction = true })
  flow.style.vertical_align = "center"
  flow.add({ type = "label", caption = expanded and "▾ " or "▸ " })
  flow.add({ type = "sprite", sprite = g.sprite })
  local nm = flow.add({ type = "label", caption = " " .. g.proto })
  nm.style.font = "default-semibold"

  num_cell(tbl, nil, g.load,     { "tod.tt-load" })
  num_cell(tbl, nil, g.unload,   { "tod.tt-unload" })
  num_cell(tbl, nil, station_total(g), { "tod.tt-stations" })
  num_cell(tbl, nil, g.present,  { "tod.tt-value-present", g.present, station_total(g) }, COLORS.serving)
  -- Saturation cell: "waiting/capacity" coloured by how full the group's queues are.
  num_cell(tbl, nil, (g.waiting or 0) .. "/" .. (g.qcap or 0),
           { "tod.tt-value-saturation", g.waiting or 0, g.qcap or 0 }, group_color(g))
  num_cell(tbl, nil, g.disabled, { "tod.tt-value-disabled", g.disabled, station_total(g) }, g.disabled > 0 and COLORS.disabled or nil)

  -- Optional average wait (mm:ss). Hidden value 0 shows as "–".
  local wait_txt = g.wait_avg > 0 and string.format("%d:%02d", math.floor(g.wait_avg / 3600), math.floor((g.wait_avg % 3600) / 60)) or "–"
  num_cell(tbl, nil, wait_txt, { "tod.tt-wait-time" })
end

--- Build the expanded child list for a group: one line per station with the
--- three control buttons (zoom / show-train / enable-disable).
local function build_station_children(tbl, g)
  for _, rec in ipairs(g.stations) do
    local color = station_color(rec)
    local mode_color = rec.mode == "load" and { 0.55, 0.82, 0.42 } or { 0.95, 0.73, 0.28 }
    local state_color = color
    local state_name = rec.stats.state or "idle"
    local station_icon = rec.mode == "load" and rec.stats.train_icon or nil

    -- Col 1: card-like station identity block.
    local cell = tbl.add({ type = "frame", style = "subheader_frame", direction = "horizontal" })
    cell.style.left_padding = 14
    cell.style.right_padding = 10
    cell.style.top_padding = 4
    cell.style.bottom_padding = 4
    cell.style.horizontally_stretchable = true
    local card = cell.add({ type = "flow", direction = "horizontal" })
    card.style.vertical_align = "center"
    card.style.horizontally_stretchable = true
    card.style.horizontal_spacing = 8
    local icon = card.add({ type = "sprite", sprite = signal_sprite(station_icon) })
    icon.style.minimal_width = 20
    icon.style.minimal_height = 20
    local text = card.add({ type = "flow", direction = "vertical" })
    text.style.vertical_spacing = 0
    text.style.horizontally_stretchable = true
    local row = text.add({ type = "flow", direction = "horizontal" })
    row.style.vertical_align = "center"
    row.style.horizontal_spacing = 6
    local dot = row.add({ type = "label", caption = "●" })
    dot.style.font_color = color
    local nm = row.add({ type = "label", caption = rec.name })
    nm.style.font = "default-semibold"
    nm.style.single_line = true
    nm.style.maximal_width = 360
    local meta = text.add({ type = "flow", direction = "horizontal" })
    meta.style.horizontal_spacing = 6
    local mode_badge = meta.add({ type = "label", caption = rec.mode == "load" and "LOAD" or "UNLOAD" })
    mode_badge.style.font = "default-semibold"
    mode_badge.style.font_color = mode_color
    local state_badge = meta.add({ type = "label", caption = rec.stats.disabled and "OFF" or string.upper(state_name) })
    state_badge.style.font = "default-semibold"
    state_badge.style.font_color = state_color
    if rec.mode == "load" and rec.stats.train_icons then
      for _, sig in ipairs(rec.stats.train_icons) do
        local chip = meta.add({ type = "flow", direction = "horizontal" })
        chip.style.horizontal_spacing = 2
        chip.add({ type = "sprite", sprite = signal_sprite(sig) })
        local qty = chip.add({ type = "label", caption = tostring(sig.count) })
        qty.style.font_color = { 0.76, 0.79, 0.86 }
      end
    end
    if rec.mode == "load" and rec.stats.train_contents then
      local contents_badge = meta.add({ type = "label", caption = rec.stats.train_contents })
      contents_badge.style.font_color = { 0.70, 0.84, 0.58 }
      contents_badge.style.font = "default"
      contents_badge.tooltip = { "tod.tt-train-contents", rec.stats.train_contents_total or 0,
        rec.stats.train_contents_items or 0, rec.stats.train_contents_fluids or 0 }
    end

    -- Col 2: per-station controls.
    local ctl = tbl.add({ type = "flow", direction = "horizontal" })
    ctl.style.horizontal_align = "left"
    ctl.add({ type = "sprite-button", name = "tod_zoom__"  .. rec.unit_number, style = "tod_control_button", sprite = "utility/search_icon", tooltip = { "tod.tt-zoom" } })
    ctl.add({ type = "sprite-button", name = "tod_train__" .. rec.unit_number, style = "tod_control_button", sprite = "item/locomotive", tooltip = { "tod.tt-show-train" } })
    ctl.add({ type = "sprite-button", name = "tod_toggle__".. rec.unit_number, style = "tod_control_button", sprite = rec.stats.disabled and "utility/play" or "utility/stop", tooltip = { "tod.tt-toggle-enabled" } })

    -- Col 3: state label.
    local state_cap = ({
      saturated = { "tod.station-saturated" },
      filling   = { "tod.station-filling" },
      serving   = { "tod.station-present" },
      idle      = { "tod.station-idle" },
      disabled  = { "tod.station-disabled" },
    })[rec.stats.state] or { "tod.station-idle" }
    local span = tbl.add({ type = "label", caption = state_cap })
    span.style.font_color = state_color
    span.style.font = rec.stats.disabled and "default" or "default-semibold"

    -- Col 4: saturation bar + "waiting/capacity" — how many ARE and CAN wait.
    local sat = tbl.add({ type = "flow", direction = "horizontal" })
    sat.style.vertical_align = "center"
    sat.style.horizontal_spacing = 4
    if rec.stats.disabled then
      local off = sat.add({ type = "label", caption = "OFF" })
      off.style.font_color = COLORS.disabled
    else
      local bar = sat.add({ type = "progressbar", value = math.min(1, rec.stats.saturation or 0) })
      bar.style.width = 60
      bar.style.color = color
      local lbl = sat.add({ type = "label",
        caption = (rec.stats.waiting or 0) .. "/" .. (rec.stats.qcap or 0),
        tooltip = { "tod.tt-value-saturation", rec.stats.waiting or 0, rec.stats.qcap or 0 } })
      lbl.style.font_color = color
    end

    -- Pad remaining columns to keep the 8-column grid aligned.
    for _ = 1, 4 do tbl.add({ type = "empty-widget" }) end
  end
end

--- Build the throughput graph row shown at the top of an expanded group.
-- Renders the 10-minute history as a strip of mini bars (one per minute) plus
-- an avg/peak summary. The mockup shows the full-height vertical bar design;
-- Factorio's GUI has no native vertical bar chart, so each minute is a thin
-- progressbar scaled to the window peak.
local function build_chart_row(tbl, g)
  local avg, peak = throughput.summary(g.group_key)
  local series = throughput.series(g.group_key) or {}

  local cell = tbl.add({ type = "flow", direction = "horizontal" })
  cell.style.left_padding = 22
  cell.style.vertical_align = "center"
  cell.style.horizontal_spacing = 8

  local summary = cell.add({ type = "label",
    caption = { "tod.throughput-summary", string.format("%.1f", avg), math.floor(peak) },
    tooltip = { "tod.tt-throughput" } })
  summary.style.font = "default-semibold"
  summary.style.font_color = COLORS.serving

  local bars = cell.add({ type = "flow", direction = "horizontal" })
  bars.style.horizontal_spacing = 2
  for _, v in ipairs(series) do
    local b = bars.add({ type = "progressbar", value = peak > 0 and (v / peak) or 0 })
    b.style.width = 12
    b.style.color = COLORS.saturated
  end

  for _ = 1, 7 do tbl.add({ type = "empty-widget" }) end
end

--- Populate the rows table from scratch for a player.
function rendering.populate(rows_table, ui)
  rows_table.clear()
  local groups = rendering.visible_groups(ui)
  if #groups == 0 then
    -- (caller shows the empty-state label; nothing to add here)
    return 0
  end
  for _, g in ipairs(groups) do
    build_group_row(rows_table, g, ui)
    if ui.expanded[g.group_key] then
      build_chart_row(rows_table, g)
      build_station_children(rows_table, g)
    end
  end
  return #groups
end

return rendering
