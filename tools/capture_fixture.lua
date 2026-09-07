-- tools/capture_fixture.lua
-- Dumps the frame energies of the current time selection to a JSON fixture, so
-- threshold experiments run on the command line in under a second instead of
-- requiring a round trip through REAPER.
--
-- Name fixtures for the SCENARIO, never for the band or the songs: they are
-- committed to an open-source repository.
--
-- Run from REAPER's action list with a time selection made.

local script_path = ({ reaper.get_action_context() })[2]
-- REAPERTOIRE_DIR is set when this runs via the launcher, which dofiles
-- us and would otherwise have us derive the path from ITS location.
local repo_dir = REAPERTOIRE_DIR or script_path:match("^(.*)[/\\]tools[/\\][^/\\]*$")
package.path = repo_dir .. "/?.lua;" .. repo_dir .. "/?/init.lua;" .. package.path

local adapter = require("adapters.reaper_api")
local config = require("lib.config")
local json = require("lib.util.json")

reaper.ClearConsole()

local ok, cfg = pcall(config.load, repo_dir, adapter.read_file)
if not ok then
  adapter.log("Configuration problem:")
  adapter.log("  %s", tostring(cfg))
  return
end

local rate = cfg.detection.frameRateHz

local sel_start, sel_stop = adapter.time_selection()
if not sel_start then
  adapter.log("No time selection. Select a range and run again.")
  return
end

local got, name = reaper.GetUserInputs(
  "Capture fixture", 1,
  "Scenario name (no band or song names),extrawidth=220",
  "full-band")
if not got then return end

name = name:gsub("[^%w%-]", "-")

adapter.log("Reading peaks over %.1f s at %d Hz...", sel_stop - sel_start, rate)

local tracks, items = adapter.collect(sel_start, sel_stop, rate, cfg.tracks)

-- Only tracks holding media are worth storing. A session commonly carries
-- dozens of empty tracks, and an all-`false` array costs as much to serialise
-- as a real one while telling the detector nothing.
local kept = {}
for _, track in ipairs(tracks) do
  local has_media = false
  for _, v in ipairs(track.frames) do
    if v ~= false then has_media = true break end
  end
  if has_media then
    -- One decimal is far finer than any threshold distinguishes, and it keeps
    -- the file to a size worth committing.
    local rounded = {}
    for i, v in ipairs(track.frames) do
      -- Written long-hand on purpose: `(v == false) and false or expr` always
      -- evaluates expr, because Lua's and/or idiom cannot carry a false value.
      if v == false then
        rounded[i] = false
      else
        rounded[i] = math.floor(v * 10 + 0.5) / 10
      end
    end
    kept[#kept + 1] = {
      name = track.name,
      slug = track.slug,
      isMic = track.is_mic,
      frames = rounded,
    }
  end
end

local fixture = {
  selStart = sel_start,
  selStop = sel_stop,
  rate = rate,
  tracks = kept,
  items = items,
  -- Fill these in by ear before committing: they are what the regression test
  -- asserts against.
  expected = { spanCount = 0, takeCount = 0 },
}

local path = repo_dir .. "/test/fixtures/fixture-" .. name .. ".json"
local f = io.open(path, "w")
if not f then
  adapter.log("Could not write %s", path)
  return
end
f:write(json.encode(fixture))
f:close()

local frame_count = 0
for _, t in ipairs(kept) do frame_count = frame_count + #t.frames end

adapter.log("Wrote %s", path)
adapter.log("  %d tracks with media (of %d), %d frames each, %d values total",
  #kept, #tracks, #kept > 0 and #kept[1].frames or 0, frame_count)
adapter.log("")
adapter.log("Now count the real run-throughs by ear and set expected.takeCount")
adapter.log("in that file. That number is what the tuning is measured against.")
