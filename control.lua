-- ---------------------------------------------------------------------------
-- control.lua  (runtime entry point)
-- ---------------------------------------------------------------------------
-- This file is intentionally tiny. Its only job is to load the modules and
-- hand off ALL event registration to scripts/events.lua. Keeping the wiring in
-- one place (instead of scattering script.on_event calls across modules) is the
-- core of the "no global spaghetti" architecture:
--
--   parser      -> pure functions, no state          (scripts/parser.lua)
--   cache       -> owns the storage schema            (scripts/cache.lua)
--   discovery   -> keeps the cache in sync with events(scripts/discovery.lua)
--   statistics  -> computes queue / health numbers    (scripts/statistics.lua)
--   gui         -> builds & owns the window widgets    (scripts/gui.lua)
--   rendering   -> sort / filter / row construction    (scripts/rendering.lua)
--   events      -> the ONLY place that calls on_event  (scripts/events.lua)
--
-- Modules never require() each other in a cycle: events depends on everything,
-- everything else depends only on cache + parser + statistics.
-- ---------------------------------------------------------------------------

local events = require("scripts.events")

events.register()
