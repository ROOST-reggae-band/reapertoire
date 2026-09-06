-- scripts/Reapertoire_Tune_takes.lua
-- Interactive take detection: drag the thresholds, watch the takes change,
-- write regions when it looks right.
--
-- Peaks are read once when the panel opens -- that is the slow part. Detection
-- re-runs on cached frames whenever a slider moves, which is why this can be
-- live at all.

local script_path = ({ reaper.get_action_context() })[2]
local repo_dir = script_path:match("^(.*)[/\\]scripts[/\\][^/\\]*$")
package.path = repo_dir .. "/?.lua;" .. repo_dir .. "/?/init.lua;" .. package.path

local adapter = require("adapters.reaper_api")
local regions = require("adapters.regions")
local config = require("lib.config")
local pipeline = require("lib.pipeline")

-- ReaImGui exposes a flat reaper.ImGui_* API in older versions and a namespaced
-- shim in newer ones. Bind whichever is present rather than guessing.
local ImGui
do
  local shim = reaper.GetResourcePath() .. "/Scripts/ReaTeam Extensions/API/imgui.lua"
  local f = io.open(shim, "r")
  if f then
    f:close()
    local ok, mod = pcall(function() return dofile(shim)("0.9") end)
    if ok then ImGui = mod end
  end
  if not ImGui and reaper.ImGui_CreateContext then
    ImGui = setmetatable({}, {
      __index = function(_, k) return reaper["ImGui_" .. k] end,
    })
  end
  if not ImGui then
    reaper.MB(
      "ReaImGui is not installed.\n\n" ..
      "Extensions > ReaPack > Browse packages, filter for ReaImGui, install\n" ..
      '"ReaImGui: ReaScript binding for Dear ImGui", then restart REAPER.',
      "Reapertoire", 0)
    return
  end
end

-- ---------------------------------------------------------------- load state

local ok, cfg = pcall(config.load, repo_dir, adapter.read_file)
if not ok then
  reaper.MB("Configuration problem:\n\n" .. tostring(cfg) ..
    "\n\nEdit config/settings.json and run again.", "Reapertoire", 0)
  return
end

local sel_start, sel_stop = adapter.time_selection()
if not sel_start then
  reaper.MB("No time selection. Select a range and run again.", "Reapertoire", 0)
  return
end

local detection = {}
for k, v in pairs(cfg.detection) do detection[k] = v end

local input = {
  tracks = nil,
  items = nil,
  sel_start = sel_start,
  sel_stop = sel_stop,
  detection = detection,
}

local classified, detected
local status = ""

local function collect()
  local tracks, items = adapter.collect(
    sel_start, sel_stop, detection.frameRateHz, cfg.tracks)
  input.tracks = tracks
  input.items = items
  classified = pipeline.classify(input)
end

local function redetect()
  detected = pipeline.detect(classified, input)
end

collect()
redetect()

-- ------------------------------------------------------------------ helpers

local function mmss(t)
  local rel = t - sel_start
  local m = math.floor(rel / 60)
  return string.format("%d:%05.2f", m, rel - m * 60)
end

local function live_tracks()
  local out = {}
  for _, t in ipairs(classified.tracks) do
    if t.live then out[#out + 1] = t end
  end
  return out
end

local function covered_seconds()
  local n = 0
  for _, t in ipairs(detected.takes) do n = n + (t.stop - t.start) end
  return n
end

local function span_seconds()
  local n = 0
  for _, s in ipairs(detected.covered_spans) do n = n + (s.stop - s.start) end
  return n
end

local function save_thresholds()
  local path = repo_dir .. "/config/settings.json"
  local raw = adapter.read_file(path)
  if not raw then
    status = "Could not read config/settings.json"
    return
  end
  -- Substituted textually rather than decoded and re-encoded: a JSON round
  -- trip through a Lua table loses key order, and this is a file the operator
  -- hand-edits. Only the three numbers this panel owns are touched.
  local updated = raw
  local missing = {}
  for key, value in pairs({
    gapThresholdDb = detection.gapThresholdDb,
    minGapSec = detection.minGapSec,
    minTakeSec = detection.minTakeSec,
  }) do
    local pattern = '("' .. key .. '"%s*:%s*)[%-%d%.eE+]+'
    local replaced
    updated, replaced = updated:gsub(pattern, "%1" .. string.format("%.10g", value), 1)
    if replaced == 0 then missing[#missing + 1] = key end
  end

  if #missing > 0 then
    status = "Not found in settings.json: " .. table.concat(missing, ", ")
    return
  end

  local tmp = path .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then
    status = "Could not write config/settings.json"
    return
  end
  f:write(updated)
  f:close()
  -- rename over an existing file is atomic here, so the config is never absent
  local ok_rename, err = os.rename(tmp, path)
  if not ok_rename then
    os.remove(tmp)
    status = "Could not replace settings.json: " .. tostring(err)
    return
  end
  status = "Thresholds saved to config/settings.json"
end

-- ---------------------------------------------------------------------- loop

local ctx = ImGui.CreateContext("Reapertoire")

local function frame()
  local visible, open = ImGui.Begin(ctx, "Reapertoire - tune takes", true)
  if visible then
    local live = live_tracks()
    ImGui.Text(ctx, string.format(
      "Selection %s   %d of %d tracks live",
      mmss(sel_stop), #live, #classified.tracks))

    local names = {}
    for _, t in ipairs(live) do
      names[#names + 1] = string.format("%s %.0f", t.name, t.floor_db or 0)
    end
    ImGui.Text(ctx, table.concat(names, "   "))

    ImGui.Separator(ctx)

    local changed = false
    local c, v

    c, v = ImGui.SliderDouble(ctx, "gapThresholdDb", detection.gapThresholdDb, 5, 50, "%.0f")
    if c then detection.gapThresholdDb = v; changed = true end

    c, v = ImGui.SliderDouble(ctx, "minGapSec", detection.minGapSec, 1, 15, "%.1f")
    if c then detection.minGapSec = v; changed = true end

    c, v = ImGui.SliderDouble(ctx, "minTakeSec", detection.minTakeSec, 0, 120, "%.0f")
    if c then detection.minTakeSec = v; changed = true end

    if changed then redetect() end

    ImGui.Separator(ctx)

    local span = span_seconds()
    ImGui.Text(ctx, string.format(
      "%d takes   %.0f%% of %d covered span%s",
      #detected.takes,
      span > 0 and (100 * covered_seconds() / span) or 0,
      #detected.covered_spans,
      #detected.covered_spans == 1 and "" or "s"))

    if ImGui.Button(ctx, "Create regions") then
      local made = regions.replace(
        detected.takes,
        function(_, i) return string.format("Take %d", i) end,
        0)
      status = string.format("Wrote %d regions", made)
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Clear regions") then
      local gone = regions.clear()
      status = string.format("Removed %d regions", gone)
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Save thresholds") then save_thresholds() end

    if status ~= "" then ImGui.Text(ctx, status) end

    ImGui.Separator(ctx)

    if ImGui.BeginChild(ctx, "takes", 0, 0) then
      for i, t in ipairs(detected.takes) do
        ImGui.Text(ctx, string.format("%2d  %9s  %6.0fs  %s",
          i, mmss(t.start), t.stop - t.start,
          table.concat(t.instruments, ", ")))
      end
      ImGui.EndChild(ctx)
    end

    ImGui.End(ctx)
  end

  if open then
    reaper.defer(frame)
  elseif ImGui.DestroyContext then
    ImGui.DestroyContext(ctx)
  end
end

reaper.defer(frame)
