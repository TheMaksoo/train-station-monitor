-- ---------------------------------------------------------------------------
-- scripts/statistics.lua
-- ---------------------------------------------------------------------------
-- Computes the "health" numbers shown in the dashboard. Runs once per second
-- (on_nth_tick 60), NOT per tick, and only touches cached entities — so cost
-- scales with station count, not map size.
--
-- Queue detection (best-effort, in order of reliability)
-- ------------------------------------------------------
--   1. entity.get_stopped_train()  -> a train is physically AT the stop.
--   2. entity.trains_count         -> trains that have this stop as a schedule
--                                     target (dispatched / en route / queued).
--   3. on_train_changed_state feed -> we tag trains sitting in `wait_station`
--                                     or `destination_full` for this stop, which
--                                     lets us count "waiting" without scanning.
--
-- The API does not hand us a literal queue length, so "waiting" = trains
-- targeting the stop that are NOT the one currently being served, bucketed to
-- 0 / 1 / 2 / 3+ exactly as the spec requests. If a future API exposes rail
-- block occupancy we can refine detect_queue() in ONE place.
-- ---------------------------------------------------------------------------

local cache = require("scripts.cache")
local throughput = require("scripts.throughput")

local statistics = {}

local WAIT_SAMPLE_WINDOW = 20 -- keep the last N served-train wait samples
local GAP_FULL_SEC = 90       -- a supply gap of 90s to the next train == fully starved (hot)

--- Is a train stop disabled right now (by circuit, limit 0, or by us)?
local function is_disabled(rec)
  local e = rec.entity
  if rec.disabled_by_mod then return true end
  -- trains_limit == 0 (from a circuit condition or a manual set) means no train
  -- will ever be dispatched here → effectively disabled.
  local ok, limit = pcall(function() return e.trains_limit end)
  if ok and limit == 0 then return true end
  -- A control behaviour with an unsatisfied enable condition also disables it.
  local cb = e.get_control_behavior()
  if cb and cb.valid then
    local ok2, disabled = pcall(function()
      return cb.disabled -- true when circuit condition currently disables it
    end)
    if ok2 and disabled then return true end
  end
  return false
end

local NO_LIMIT = 4294967295 -- trains_limit sentinel meaning "no limit set"

local function count_table_values(t)
  local n = 0
  for _, v in pairs(t or {}) do
    if type(v) == "number" then
      n = n + v
    elseif type(v) == "table" then
      n = n + (tonumber(v.amount or v.count or v.quantity) or 0)
    end
  end
  return n
end

local function content_quantity(value)
  if type(value) == "number" then return value end
  if type(value) == "table" then
    return tonumber(value.amount or value.count or value.quantity) or 0
  end
  return tonumber(value) or 0
end

local function push_content_part(parts, fallback_type, raw_name, raw_value)
  local part_type = fallback_type
  local name = raw_name
  local value = raw_value

  if type(raw_name) == "table" then
    part_type = raw_name.type or part_type
    name = raw_name.name
  end
  if type(raw_value) == "table" then
    part_type = raw_value.type or part_type
    if not name then name = raw_value.name end
    value = raw_value.count or raw_value.amount or raw_value.quantity
  end

  local count = content_quantity(value)
  if count <= 0 then return end
  if type(name) ~= "string" or name == "" then return end
  if part_type ~= "fluid" then part_type = "item" end

  parts[#parts + 1] = { type = part_type, name = name, count = count }
end

local function collect_content_parts(contents, fallback_type)
  local parts = {}
  for key, value in pairs(contents or {}) do
    if type(key) == "string" or type(key) == "table" then
      push_content_part(parts, fallback_type, key, value)
    elseif type(value) == "table" then
      push_content_part(parts, fallback_type, value.name or value.signal or value.prototype, value)
    end
  end
  return parts
end

local function best_content_icon(train)
  if not (train and train.valid) then return nil end

  local ok_items, items = pcall(function() return train.get_contents() end)
  items = ok_items and items or {}
  local ok_fluids, fluids = pcall(function() return train.get_fluid_contents() end)
  fluids = ok_fluids and fluids or {}

  local parts = collect_content_parts(items, "item")
  local fluid_parts = collect_content_parts(fluids, "fluid")
  for _, p in ipairs(fluid_parts) do parts[#parts + 1] = p end
  if #parts == 0 then return nil end

  table.sort(parts, function(a, b) return a.count > b.count end)

  local best = parts[1]

  local summary = {}
  local top_icons = {}
  for i = 1, math.min(2, #parts) do
    local part = parts[i]
    summary[#summary + 1] = string.format("%s x %d", part.name, part.count)
    top_icons[#top_icons + 1] = { type = part.type, name = part.name, count = part.count }
  end

  return {
    icon = { type = best.type, name = best.name },
    icons = top_icons,
    summary = table.concat(summary, " · "),
    total = count_table_values(items) + count_table_values(fluids),
    total_items = count_table_values(items),
    total_fluids = count_table_values(fluids),
  }
end

--- Gather raw metrics for one station.
-- @return present(bool), waiting(int), qcap(int|nil), disabled(bool)
--   present : a train is physically being served at the platform
--   waiting : trains queued behind it (targeting - served)
--   qcap    : how many trains CAN wait = train_limit - 1 (the platform slot);
--             nil when the stop has no train limit set
local function station_metrics(rec)
  local e = rec.entity
  local disabled = is_disabled(rec)

  local present = e.get_stopped_train() ~= nil

  -- trains_count = trains whose current schedule targets this stop.
  local ok, targeting = pcall(function() return e.trains_count end)
  targeting = ok and targeting or (present and 1 or 0)

  local waiting = targeting - (present and 1 or 0)
  if waiting < 0 then waiting = 0 end

  local ok2, limit = pcall(function() return e.trains_limit end)
  local qcap
  if ok2 and limit and limit > 0 and limit < NO_LIMIT then
    qcap = math.max(limit - 1, waiting) -- capacity to WAIT (excludes platform)
  end

  return present, waiting, qcap, disabled
end

--- Refresh one station's stats block in place.
-- Saturation semantics: a FULL queue is GOOD (the stop is well supplied), so
-- saturation runs 0 (starved) .. 1 (fully saturated). State is one of:
--   disabled | saturated | filling | serving | idle
local function refresh_station(rec)
  local present, waiting, qcap, disabled = station_metrics(rec)
  local sat = qcap and qcap > 0 and (waiting / qcap) or (waiting > 0 and 1 or 0)

  local state
  if disabled then state = "disabled"
  elseif sat >= 1 and waiting > 0 then state = "saturated"
  elseif waiting > 0 then state = "filling"
  elseif present then state = "serving"
  else state = "idle" end

  rec.stats.present    = present
  rec.stats.waiting    = waiting
  rec.stats.qcap       = qcap or 0
  rec.stats.saturation = sat
  rec.stats.disabled   = disabled
  rec.stats.state      = state
  -- congestion (supply gap) is assigned per-group in refresh_all, since it
  -- depends on the group's throughput history.
end

--- Public: recompute every station, then rebuild the grouped view + roll-ups.
function statistics.refresh_all()
  cache.each_station(function(_, rec)
    refresh_station(rec)

    local ok_train, train = pcall(function() return rec.entity.get_stopped_train() end)
    train = ok_train and train or nil
    if rec.mode == "load" and train and train.valid then
      local contents = best_content_icon(train)
      rec.stats.train_icon = contents and contents.icon or nil
      rec.stats.train_icons = contents and contents.icons or nil
      rec.stats.train_contents = contents and contents.summary or nil
      rec.stats.train_contents_total = contents and contents.total or 0
      rec.stats.train_contents_items = contents and contents.total_items or 0
      rec.stats.train_contents_fluids = contents and contents.total_fluids or 0
    else
      rec.stats.train_icon = nil
      rec.stats.train_icons = nil
      rec.stats.train_contents = nil
      rec.stats.train_contents_total = 0
      rec.stats.train_contents_items = 0
      rec.stats.train_contents_fluids = 0
    end
  end)

  local groups = cache.rebuild_groups()
  for _, g in pairs(groups) do
    local wait_total, wait_n = 0, 0
    for _, rec in ipairs(g.stations) do
      if rec.stats.disabled then
        g.disabled = g.disabled + 1
      else
        if rec.stats.present then g.present = g.present + 1 end
        g.waiting = g.waiting + (rec.stats.waiting or 0)
        g.qcap    = g.qcap    + (rec.stats.qcap or 0)
      end
      if (rec.wait.avg or 0) > 0 then
        wait_total = wait_total + rec.wait.avg
        wait_n = wait_n + 1
      end
    end
    -- Group saturation = total trains waiting / total slots that can wait.
    g.saturation = g.qcap > 0 and (g.waiting / g.qcap) or 0
    g.wait_avg = wait_n > 0 and (wait_total / wait_n) or 0

    -- Congestion = SUPPLY GAP: estimated seconds until the next train arrives.
    -- Fewer trains is worse. If trains are already waiting the gap is 0 (well
    -- supplied); otherwise it's the mean inter-arrival time from throughput
    -- (60 / trains-per-minute). No throughput and no queue = starved (hot).
    local tpm = select(1, throughput.summary(g.group_key)) -- trains/min (avg)
    local gap
    if g.waiting > 0 then gap = 0
    elseif tpm > 0.05 then gap = 60 / tpm
    else gap = math.huge end
    g.gap = gap
    g.congestion = (gap == math.huge) and 1 or math.min(1, gap / GAP_FULL_SEC)

    -- Push the score down to each station for the map heatmap. A station with
    -- its own queue is locally supplied (0); otherwise it inherits the group gap.
    for _, rec in ipairs(g.stations) do
      if rec.stats.disabled then
        rec.stats.congestion = 0
      elseif (rec.stats.waiting or 0) > 0 then
        rec.stats.congestion = 0
      else
        rec.stats.congestion = g.congestion
      end
    end
  end
  return groups
end

-- Average-wait tracking -----------------------------------------------------
-- Fed by on_train_changed_state (see events.lua). We record the tick a train
-- entered `wait_station` for a stop, and when it leaves we push the delta as a
-- sample. This is O(1) per state change — no polling.

--- Called when a train enters the "arrived / waiting" state at a stop.
function statistics.mark_arrival(rec, tick)
  rec.wait.last_arrival_tick = tick
end

--- Called when a train departs; records how long it waited.
function statistics.mark_departure(rec, tick)
  local t0 = rec.wait.last_arrival_tick
  if not t0 then return end
  local delta = tick - t0
  rec.wait.last_arrival_tick = nil
  local s = rec.wait.samples
  s[#s + 1] = delta
  while #s > WAIT_SAMPLE_WINDOW do table.remove(s, 1) end
  local sum = 0
  for _, v in ipairs(s) do sum = sum + v end
  rec.wait.avg = sum / #s
end

-- Station controls (mutations triggered from the GUI) -----------------------

--- Toggle a station enabled/disabled by manipulating its train limit. We save
--- the previous limit so re-enabling restores the player's intended value.
function statistics.set_enabled(rec, enabled)
  local e = rec.entity
  if not (e and e.valid) then return end
  if enabled then
    if rec.disabled_by_mod then
      e.trains_limit = rec.saved_limit or nil -- nil = "no limit"
      rec.disabled_by_mod = false
      rec.saved_limit = nil
    end
  else
    if not rec.disabled_by_mod then
      rec.saved_limit = e.trains_limit
      e.trains_limit = 0
      rec.disabled_by_mod = true
    end
  end
  refresh_station(rec)
end

return statistics
