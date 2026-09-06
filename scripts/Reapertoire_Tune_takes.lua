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
local timeline = require("lib.timeline")

-- ReaImGui's binding moved over its lifetime: 0.10 ships a Lua shim inside the
-- extension and reaches it via ImGui_GetBuiltinPath, 0.9 shipped that shim as a
-- separate ReaPack file, and older versions exposed only flat reaper.ImGui_*
-- functions. Try them in that order rather than assuming a version.
local ImGui
do
  if reaper.ImGui_GetBuiltinPath then
    local ok, mod = pcall(function()
      package.path = package.path .. ";" .. reaper.ImGui_GetBuiltinPath() .. "/?.lua"
      return require("imgui")("0.10")
    end)
    if ok then ImGui = mod end
  end

  if not ImGui then
    local shim = reaper.GetResourcePath() .. "/Scripts/ReaTeam Extensions/API/imgui.lua"
    local f = io.open(shim, "r")
    if f then
      f:close()
      local ok, mod = pcall(function() return dofile(shim)("0.9") end)
      if ok then ImGui = mod end
    end
  end

  -- Flat API: present through 0.10, though no longer the documented route.
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
local foreign, clashes = {}, {}
local status = ""

local function collect()
  local tracks, items = adapter.collect(
    sel_start, sel_stop, detection.frameRateHz, cfg.tracks)
  input.tracks = tracks
  input.items = items
  classified = pipeline.classify(input)
end

-- Which detected takes would collide with a region the operator made. Computed
-- up front so the clash is visible while tuning, not a surprise on Create.
local function recheck_clashes()
  foreign = regions.foreign()
  clashes = {}
  for i, take in ipairs(detected.takes) do
    clashes[i] = timeline.first_overlap(take, foreign)
  end
end

local function redetect()
  detected = pipeline.detect(classified, input)
  recheck_clashes()
end

-- Re-reads peaks for whatever the time selection now is. This is the expensive
-- path, so it is only reached once the selection has stopped moving.
local function reload()
  local s, e = adapter.time_selection()
  if not s then return false end
  sel_start, sel_stop = s, e
  input.sel_start, input.sel_stop = s, e
  collect()
  redetect()
  return true
end

collect()
redetect()

-- Following the time selection: poll it each frame, but wait for it to settle
-- before re-reading peaks. Reloading mid-drag would stall the panel on every
-- mouse move, and a long selection takes seconds to read.
local SETTLE_SEC = 0.4
local pending, pending_since = nil, 0
local reload_next_frame = false
local no_selection = false

local function poll_selection()
  local cur_start, cur_stop = adapter.time_selection()
  if not cur_start then
    no_selection = true
    pending = nil
    return
  end
  no_selection = false

  local same_as_loaded =
    math.abs(cur_start - sel_start) < 1e-6 and math.abs(cur_stop - sel_stop) < 1e-6
  if same_as_loaded then
    pending = nil
    return
  end

  local same_as_pending = pending
    and math.abs(cur_start - pending.start) < 1e-6
    and math.abs(cur_stop - pending.stop) < 1e-6

  if not same_as_pending then
    pending = { start = cur_start, stop = cur_stop }
    pending_since = reaper.time_precise()
  elseif reaper.time_precise() - pending_since >= SETTLE_SEC then
    pending = nil
    -- Draw the notice this frame, reload at the start of the next one, so the
    -- panel does not appear frozen during the read.
    reload_next_frame = true
  end
end

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
  if reload_next_frame then
    reload_next_frame = false
    reload()
    status = ""
  end
  poll_selection()

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

    if reload_next_frame then
      ImGui.Text(ctx, "Selection changed - re-reading peaks...")
    elseif pending then
      ImGui.Text(ctx, "Selection changing...")
    elseif no_selection then
      ImGui.Text(ctx, "No time selection - showing the last range analysed")
    end

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

    local n_clashes = 0
    for _ in pairs(clashes) do n_clashes = n_clashes + 1 end

    local span = span_seconds()
    ImGui.Text(ctx, string.format(
      "%d takes   %.0f%% of %d covered span%s",
      #detected.takes,
      span > 0 and (100 * covered_seconds() / span) or 0,
      #detected.covered_spans,
      #detected.covered_spans == 1 and "" or "s"))

    if n_clashes > 0 then
      ImGui.Text(ctx, string.format(
        "%d would be skipped -- they overlap regions you made yourself",
        n_clashes))
    end

    if ImGui.Button(ctx, "Create regions") then
      local made, skipped = regions.replace(
        detected.takes,
        function(_, i) return string.format("Take %d", i) end,
        0)
      if #skipped == 0 then
        status = string.format("Wrote %d regions", made)
      else
        local names = {}
        for _, s2 in ipairs(skipped) do
          names[#names + 1] = string.format("%d overlaps \"%s\"", s2.index, s2.clash.name)
        end
        status = string.format("Wrote %d regions, skipped %d: %s",
          made, #skipped, table.concat(names, ", "))
      end
      recheck_clashes()
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Clear regions") then
      local gone = regions.clear()
      status = string.format("Removed %d regions", gone)
      recheck_clashes()
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Save thresholds") then save_thresholds() end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Reload selection") then
      if reload() then status = "Reloaded" else status = "No time selection" end
    end

    if status ~= "" then ImGui.Text(ctx, status) end

    ImGui.Separator(ctx)

    if ImGui.BeginChild(ctx, "takes", 0, 0) then
      for i, t in ipairs(detected.takes) do
        local clash = clashes[i]
        ImGui.Text(ctx, string.format("%2d  %9s  %6.0fs  %s%s",
          i, mmss(t.start), t.stop - t.start,
          table.concat(t.instruments, ", "),
          clash and string.format("   [skipped: overlaps \"%s\"]", clash.name) or ""))
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
