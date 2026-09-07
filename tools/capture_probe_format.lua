-- tools/capture_probe_format.lua
-- Records the project's current render format as the one to use for analysis
-- probes.
--
-- RENDER_FORMAT is an opaque base64 blob, so the reliable way to obtain the
-- configuration for a given format is to set it in REAPER's render dialog and
-- read back what REAPER wrote. Probes are decoded by ffmpeg and analysed at
-- 11 kHz mono, so an uncompressed format is wanted: nothing is gained by
-- encoding them and the encode is pure cost.

local script_path = ({ reaper.get_action_context() })[2]
local repo_dir = REAPERTOIRE_DIR or script_path:match("^(.*)[/\\]tools[/\\][^/\\]*$")
package.path = repo_dir .. "/?.lua;" .. repo_dir .. "/?/init.lua;" .. package.path

local adapter = require("adapters.reaper_api")

local function log(fmt, ...)
  reaper.ShowConsoleMsg(string.format(fmt .. "\n", ...))
end

reaper.ClearConsole()

local _, format = reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT", "", false)
if not format or format == "" then
  log("This project has no render format set.")
  log("Open File > Render, choose WAV, close with Save settings, run this again.")
  return
end

local answer = reaper.MB(
  "Store the project's CURRENT render format as the probe format?\n\n" ..
  "Set File > Render to WAV first -- probes are decoded and analysed at\n" ..
  "11 kHz mono, so encoding them to MP3 or Opus is pure cost.\n\n" ..
  "Your normal render format is unaffected.",
  "Reapertoire - capture probe format", 1)
if answer ~= 1 then return end

local path = repo_dir .. "/config/settings.json"
local raw = adapter.read_file(path)
if not raw then
  log("Could not read %s", path)
  return
end

-- Substituted textually rather than decoded and re-encoded: a JSON round trip
-- through a Lua table loses key order, and this is a file the operator edits.
local escaped = format:gsub("%%", "%%%%")
local updated, replaced = raw:gsub('("probeFormat"%s*:%s*)"[^"]*"', '%1"' .. escaped .. '"', 1)
if replaced == 0 then
  updated, replaced = raw:gsub('("recognition"%s*:%s*{)',
    '%1\n    "probeFormat": "' .. escaped .. '",', 1)
end
if replaced == 0 then
  log("Could not find a recognition block in config/settings.json.")
  log("Add one containing \"probeFormat\": \"\" and run this again.")
  return
end

local tmp = path .. ".tmp"
local f = io.open(tmp, "w")
if not f then
  log("Could not write %s", path)
  return
end
f:write(updated)
f:close()
if not os.rename(tmp, path) then
  os.remove(tmp)
  log("Could not replace %s", path)
  return
end

log("Probe format stored (%d characters).", #format)
log("Probes will now render in this format instead of your normal one.")
