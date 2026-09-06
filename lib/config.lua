-- Loads config/settings.json, falling back to config/settings.example.json.
--
-- The `tracks` array does double duty on purpose: the same entry supplies the
-- instrument slug for stem naming and the isMic flag that suppresses between-
-- take chatter in gap detection. Both answer one question — what is this
-- track, musically — so splitting them would mean maintaining the lineup twice.

local json = require("lib.util.json")

local M = {}

function M.defaults()
  return {
    sessionsRoot = "~/Music/RehearsalSessions",
    render = { format = "opus", bitrateKbps = 128, stems = true },
    detection = {
      frameRateHz = 20,
      floorPercentile = 10,
      liveMarginDb = 12,
      liveMinFraction = 0.02,
      micWeight = 0.35,
      gapThresholdDb = 30,
      minGapSec = 4.0,
      minTakeSec = 30.0,
      padSec = 0.5,
      presenceMinFraction = 0.05,
      mergeGapSec = 0.05,
      minLevelDb = -140,
      ensembleRatio = 0.5,
      minEnsemble = 0,
      snapToMeasure = false,
    },
    tracks = {},
    songs = {},
  }
end

-- dkjson tags every decoded table with a __jsontype of 'array' or 'object' in
-- its metatable; trust that when present. A hand-built Lua table (as in
-- M.defaults() or a test) carries no such tag, so fall back to the #t > 0
-- heuristic — which cannot distinguish an empty array from an empty object,
-- but nothing hand-built here needs that distinction.
local function is_array(t)
  if type(t) ~= "table" then return false end
  local mt = getmetatable(t)
  if mt and mt.__jsontype then return mt.__jsontype == "array" end
  return #t > 0
end

-- Recursive merge. Arrays are replaced wholesale, never merged element-wise:
-- merging them would make removing a track rule impossible.
function M.merge(base, override)
  if type(override) ~= "table" then
    if override == nil then return base end
    return override
  end
  if is_array(override) then return override end

  local out = {}
  for k, v in pairs(base) do out[k] = v end
  for k, v in pairs(override) do
    if type(v) == "table" and type(base[k]) == "table" then
      out[k] = M.merge(base[k], v)
    else
      out[k] = v
    end
  end
  return out
end

-- Guards against the raw Lua tracebacks that a hand-edited config produces
-- deep inside liveness.classify or match_track — errors an operator has no
-- context for. Not a schema library: just enough to name the bad key or
-- track index and point at the file to fix.
function M.validate(cfg)
  local where = "check config/settings.json"
  for key in pairs(M.defaults().detection) do
    local v = cfg.detection and cfg.detection[key]
    if key == "snapToMeasure" then
      if type(v) ~= "boolean" then
        error(string.format("detection.%s must be true/false (%s)", key, where))
      end
    elseif type(v) ~= "number" then
      error(string.format("detection.%s is missing or not a number (%s)", key, where))
    end
  end
  for i, rule in ipairs(cfg.tracks or {}) do
    if type(rule.match) ~= "string" then
      error(string.format("tracks[%d] is missing a string 'match' (%s)", i, where))
    end
    if type(rule.slug) ~= "string" then
      error(string.format("tracks[%d] is missing a string 'slug' (%s)", i, where))
    end
  end
end

function M.expand_path(path, home)
  home = home or os.getenv("HOME") or ""
  local rest = path:match("^~/(.*)$")
  if rest then return home .. "/" .. rest end
  return path
end

-- Exact name match first, then substring, both case-insensitive, in rule order.
-- A fuzzy pass is deliberately absent here: it needs operator confirmation,
-- which belongs in the panel (milestone 3), not in a silent loader.
function M.match_track(name, rules)
  local lowered = name:lower()
  for _, rule in ipairs(rules) do
    if lowered == rule.match:lower() then return rule end
  end
  for _, rule in ipairs(rules) do
    if lowered:find(rule.match:lower(), 1, true) then return rule end
  end
  return nil
end

-- read_file(path) -> string|nil, injected so this is testable without disk.
-- Returns the merged config and whether it fell back to the example.
function M.load(dir, read_file)
  local settings = read_file(dir .. "/config/settings.json")
  local used_example = false
  if not settings then
    settings = read_file(dir .. "/config/settings.example.json")
    used_example = true
  end
  if not settings then
    error("no config found in " .. dir .. "/config/")
  end
  local parsed, _, err = json.decode(settings)
  if not parsed then
    error("config is not valid JSON: " .. tostring(err))
  end
  local cfg = M.merge(M.defaults(), parsed)
  M.validate(cfg)
  return cfg, used_example
end

return M
