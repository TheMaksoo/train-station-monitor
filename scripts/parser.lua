-- ---------------------------------------------------------------------------
-- scripts/parser.lua
-- ---------------------------------------------------------------------------
-- PURE, STATELESS name parsing. No storage, no game access, no side effects —
-- which makes it trivially unit-testable and safe to call from anywhere.
--
-- It turns a train-stop name into a structured descriptor:
--
--   "[img=item/iron-plate] Load"    -> {kind="item",  proto="iron-plate", mode="load",   ...}
--   "[img=item=copper-plate] Unload"-> {kind="item",  proto="copper-plate", mode="unload",...}
--   "[img=fluid/crude-oil] Load"    -> {kind="fluid", proto="crude-oil",  mode="load",   ...}
--
-- The GROUPING KEY is the resource itself ("item/iron-plate"); Load vs Unload
-- is stored separately because the dashboard shows them as two columns of one
-- resource row, not two separate rows.
--
-- Anything that doesn't match (e.g. a plain "Depot" stop) returns nil and is
-- simply ignored by the rest of the mod.
-- ---------------------------------------------------------------------------

local parser = {}

-- Recognised operation modes. Extend this table to support more verbs later
-- (e.g. "fuel", "clean") without touching any other module.
local MODE_PATTERNS = {
  load   = "^%s*load%s*$",
  unload = "^%s*unload%s*$",
}

--- Detect the operation mode from the text that follows the [img] tag.
-- @param rest string   text after the icon, e.g. " Load" or " Unload #2"
-- @return string|nil    "load", "unload", or nil if not recognised
local function detect_mode(rest)
  local lower = string.lower(rest or "")
  for mode, pattern in pairs(MODE_PATTERNS) do
    if string.match(lower, pattern) then return mode end
  end
  -- Loose fallback: the word appears somewhere in the label (handles suffixes
  -- like "Load 1", "Iron Unload", etc.) without matching "Unload" as "load".
  if string.find(lower, "unload", 1, true) then return "unload" end
  if string.find(lower, "load",   1, true) then return "load" end
  return nil
end

--- Parse a full station name into a descriptor, or nil if it isn't a
--- resource station this dashboard cares about.
-- @param name string   the train-stop backer_name
-- @return table|nil
function parser.parse(name)
  if type(name) ~= "string" or name == "" then return nil end

  -- Primary: rich-text icon tag format  [img=item/iron-plate] Load
  local inner, rest = string.match(name, "%[img=([^%]]+)%](.*)")
  if inner then
    local kind, proto = string.match(inner, "^([%w%-_]+)[/=]([%w%-_]+)")
    if kind and proto then
      local mode = detect_mode(rest)
      if mode then
        return {
          kind      = kind,
          proto     = proto,
          mode      = mode,
          group_key = kind .. "/" .. proto,
          sprite    = kind .. "/" .. proto,
        }
      end
    end
  end

  -- Fallback: plain station names like "Load [41]" or "Unload [2]"
  -- Detect mode from anywhere in the name, strip [N] suffixes, use remainder as group.
  local mode = detect_mode(name)
  if not mode then return nil end

  -- Remove [N] bracket numbers and the mode word, trim whitespace.
  local clean = name
  clean = string.gsub(clean, "%[%d+%]", "")          -- strip [41], [2] etc.
  clean = string.gsub(clean, "%s*[Ll]oad%s*", " ")   -- strip Load/load
  clean = string.gsub(clean, "%s*[Uu]nload%s*", " ") -- strip Unload/unload
  clean = string.match(clean, "^%s*(.-)%s*$")        -- trim

  local proto     = (clean ~= "") and clean or (mode == "load" and "load-station" or "unload-station")
  local group_key = "station/" .. proto

  return {
    kind      = "station",
    proto     = proto,
    mode      = mode,
    group_key = group_key,
    sprite    = "item/train-stop",
  }
end

--- Convenience: is this a name we track at all?
function parser.is_tracked(name)
  return parser.parse(name) ~= nil
end

return parser
