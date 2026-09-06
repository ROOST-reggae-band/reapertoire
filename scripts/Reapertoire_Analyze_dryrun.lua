-- scripts/Reapertoire_Analyze_dryrun.lua
-- Milestone 1 deliverable. Reports what it found and writes nothing to the
-- project: no regions, no markers, no sidecar.

local script_path = ({ reaper.get_action_context() })[2]
local repo_dir = script_path:match("^(.*)[/\\]scripts[/\\][^/\\]*$")
package.path = repo_dir .. "/?.lua;" .. repo_dir .. "/?/init.lua;" .. package.path

local adapter = require("adapters.reaper_api")
local config = require("lib.config")
local pipeline = require("lib.pipeline")
local report = require("lib.report")

reaper.ClearConsole()

local ok, cfg, used_example = pcall(config.load, repo_dir, adapter.read_file)
if not ok then
  adapter.log("Configuration problem:")
  adapter.log("  %s", tostring(cfg))
  adapter.log("Edit config/settings.json and run again.")
  return
end

if used_example then
  adapter.log("No config/settings.json found -- using the tracked example. "
    .. "Copy it to config/settings.json and edit it for your session.")
end

local sel_start, sel_stop = adapter.time_selection()
if not sel_start then
  adapter.log("No time selection. Select a range and run again.")
  return
end

local d = cfg.detection
local tracks, items = adapter.collect(sel_start, sel_stop, d.frameRateHz, cfg.tracks)

local analyzed = pipeline.analyze({
  tracks = tracks,
  items = items,
  sel_start = sel_start,
  sel_stop = sel_stop,
  detection = d,
})

-- A live track with no instrument mapping means a new mic or DI appeared and
-- config/settings.json needs a line. A mapped track absent from the session is
-- normal and says nothing.
local warnings = {}
for _, track in ipairs(analyzed.tracks) do
  if track.live and not track.slug then
    warnings[#warnings + 1] = "unmapped live track: " .. track.name
      .. " -- add a rule to config/settings.json"
  end
end

local text = report.render({
  sel_start = sel_start,
  sel_stop = sel_stop,
  rate = d.frameRateHz,
  tracks = analyzed.tracks,
  covered_spans = analyzed.covered_spans,
  takes = analyzed.takes,
  warnings = warnings,
  opts = d,
})

adapter.log("%s", text)

local out_path = reaper.GetProjectPath() .. "/reapertoire-dryrun.txt"
local f = io.open(out_path, "w")
if f then
  f:write(text)
  f:close()
  adapter.log("Report written to %s", out_path)
else
  adapter.log("Could not write the report to %s", out_path)
end
