-- ---------------------------------------------------------------------------
-- scripts/throughput.lua
-- ---------------------------------------------------------------------------
-- Per-resource-group throughput history: how many trains were served (departed
-- a platform) in each of the last N minutes. Feeds the "Throughput · last 10
-- min" graph in the dashboard.
--
-- Cost model: O(1) per train departure (increment a counter) plus one cheap
-- roll every 3600 ticks (once a minute). No polling, no map scans — it rides
-- the same on_train_changed_state signal the average-wait tracker already uses.
--
-- Schema:  storage.throughput[group_key] = { series = { m-9 .. m0 }, current }
--   series  : ring buffer of WINDOW ints, oldest first, newest last
--   current : trains served so far in the minute currently in progress
-- ---------------------------------------------------------------------------

local throughput = {}

local WINDOW = 10 -- minutes of history to keep

function throughput.init()
  storage.throughput = storage.throughput or {}
end

local function bucket(group_key)
  local t = storage.throughput[group_key]
  if not t then
    t = { series = {}, current = 0 }
    for i = 1, WINDOW do t.series[i] = 0 end
    storage.throughput[group_key] = t
  end
  return t
end

--- Count one served train for a group (called on train departure).
function throughput.record(group_key)
  if not group_key then return end
  bucket(group_key).current = bucket(group_key).current + 1
end

--- Advance every group's ring buffer by one minute. Call on on_nth_tick(3600).
function throughput.roll()
  for _, t in pairs(storage.throughput or {}) do
    table.insert(t.series, t.current)
    t.current = 0
    while #t.series > WINDOW do table.remove(t.series, 1) end
  end
end

--- Raw series (array of WINDOW ints) for a group, or nil if untracked yet.
function throughput.series(group_key)
  local t = storage.throughput and storage.throughput[group_key]
  return t and t.series or nil
end

--- Convenience roll-up: average per minute + peak minute over the window.
function throughput.summary(group_key)
  local s = throughput.series(group_key)
  if not s or #s == 0 then return 0, 0 end
  local sum, peak = 0, 0
  for _, v in ipairs(s) do
    sum = sum + v
    if v > peak then peak = v end
  end
  return sum / #s, peak
end

--- Drop history for a group that no longer exists (called from discovery).
function throughput.forget(group_key)
  if storage.throughput then storage.throughput[group_key] = nil end
end

return throughput
