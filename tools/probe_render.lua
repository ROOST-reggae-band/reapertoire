-- tools/probe_render.lua
-- Prints the project's current render settings.
--
-- RENDER_SETTINGS is a bitmask whose documented values did not match observed
-- behaviour, so the reliable way to learn the number for a given mode is to set
-- that mode in the render dialog and read back what REAPER wrote.

local function log(fmt, ...)
  reaper.ShowConsoleMsg(string.format(fmt .. "\n", ...))
end

reaper.ClearConsole()

local settings = reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", 0, false)
log("RENDER_SETTINGS   = %d", settings)
log("  mode bits (&3)  = %d  -> %s", settings & 3,
  (settings & 3) == 3 and "selected tracks (stems)"
  or (settings & 3) == 0 and "master mix"
  or "mixed/unknown")
log("  bit 8  (&8)     = %s  (use render matrix)",
  (settings & 8) ~= 0 and "SET" or "clear")
log("  bit 32 (&32)    = %s  (selected media items)",
  (settings & 32) ~= 0 and "set" or "clear")
log("")
log("RENDER_BOUNDSFLAG = %d", reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 0, false))
log("RENDER_CHANNELS   = %d", reaper.GetSetProjectInfo(0, "RENDER_CHANNELS", 0, false))
log("RENDER_SRATE      = %d", reaper.GetSetProjectInfo(0, "RENDER_SRATE", 0, false))

local _, pattern = reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", "", false)
local _, file = reaper.GetSetProjectInfo_String(0, "RENDER_FILE", "", false)
log("RENDER_PATTERN    = %q", pattern or "")
log("RENDER_FILE       = %q", file or "")

local _, fmt = reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT", "", false)
log("RENDER_FORMAT     = %s", (fmt and fmt ~= "") and (#fmt .. " chars") or "EMPTY")
log("")
log("Set Source in the render dialog to what you want, close it with")
log("\"Save settings\", then run this again and compare the numbers.")
