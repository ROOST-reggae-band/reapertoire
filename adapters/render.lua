-- adapters/render.lua
-- Renders one take at a time to its own file.
--
-- Not the region render matrix: that renders every region in the project, which
-- is wrong the moment one .rpp holds several rehearsals, and it cannot vary its
-- track set per region, which per-take stems will need.
--
-- The render format is whatever the project is already set to. Reproducing
-- REAPER's format configuration from a script means synthesising an opaque
-- base64 blob; reading the one the operator chose in the render dialog is both
-- simpler and lets them pick any format REAPER supports.

local M = {}

-- File: Render project, using the most recent render settings (no dialog).
local RENDER_ACTION = 41824

local NUMERIC_KEYS = {
  "RENDER_BOUNDSFLAG", "RENDER_STARTPOS", "RENDER_ENDPOS",
  "RENDER_SETTINGS", "RENDER_CHANNELS", "RENDER_SRATE",
  "RENDER_TAILFLAG", "RENDER_ADDTOPROJ",
}
local STRING_KEYS = { "RENDER_FILE", "RENDER_PATTERN" }

-- The operator's own render settings are project state they may care about, so
-- they are put back exactly as found however the render goes.
local function snapshot()
  local saved = { numeric = {}, strings = {} }
  for _, key in ipairs(NUMERIC_KEYS) do
    saved.numeric[key] = reaper.GetSetProjectInfo(0, key, 0, false)
  end
  for _, key in ipairs(STRING_KEYS) do
    local _, value = reaper.GetSetProjectInfo_String(0, key, "", false)
    saved.strings[key] = value
  end
  return saved
end

local function restore(saved)
  for key, value in pairs(saved.numeric) do
    reaper.GetSetProjectInfo(0, key, value, true)
  end
  for key, value in pairs(saved.strings) do
    reaper.GetSetProjectInfo_String(0, key, value, true)
  end
end

-- Whether the project has a usable render format configured.
function M.format_configured()
  local _, fmt = reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT", "", false)
  return fmt ~= nil and fmt ~= ""
end

-- What the rendered files will actually be, so the manifest can state it rather
-- than guess. RENDER_SRATE is 0 when the project rate is being used, and
-- PROJECT_SRATE only applies when PROJECT_SRATE_USE is set -- otherwise the
-- rate is the audio device's.
function M.output_format()
  local srate = reaper.GetSetProjectInfo(0, "RENDER_SRATE", 0, false)
  if srate == 0 then
    if reaper.GetSetProjectInfo(0, "PROJECT_SRATE_USE", 0, false) ~= 0 then
      srate = reaper.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false)
    else
      local _, device_rate = reaper.GetAudioDeviceInfo("SRATE")
      srate = tonumber(device_rate) or 0
    end
  end
  local channels = reaper.GetSetProjectInfo(0, "RENDER_CHANNELS", 0, false)
  return math.floor(srate), math.floor(channels)
end

function M.file_info(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local bytes = f:seek("end")
  f:close()
  return bytes
end

-- sha256 via the system tool: Lua has no digest, and shelling out beats
-- vendoring an implementation for a file that may be tens of megabytes.
function M.sha256(path)
  local pipe = io.popen(string.format("shasum -a 256 %q 2>/dev/null", path))
  if not pipe then return nil end
  local out = pipe:read("*a")
  pipe:close()
  return out and out:match("^(%x+)") or nil
end

-- Renders [start, stop) to `dir/filename`. `filename` carries no extension --
-- REAPER appends whatever the configured format uses.
--
-- Returns the path actually written, or nil and a reason.
function M.take(dir, filename, start_time, stop_time, settings_mask)
  if not M.format_configured() then
    return nil, "no render format configured in this project"
  end

  local saved = snapshot()

  reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 0, true) -- custom time bounds
  reaper.GetSetProjectInfo(0, "RENDER_STARTPOS", start_time, true)
  reaper.GetSetProjectInfo(0, "RENDER_ENDPOS", stop_time, true)
  reaper.GetSetProjectInfo(0, "RENDER_TAILFLAG", 0, true)   -- no tail past the take
  reaper.GetSetProjectInfo(0, "RENDER_ADDTOPROJ", 0, true)  -- do not import the result
  if settings_mask then
    reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", settings_mask, true)
  end
  reaper.GetSetProjectInfo_String(0, "RENDER_FILE", dir, true)
  reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", filename, true)

  reaper.Main_OnCommand(RENDER_ACTION, 0)

  restore(saved)

  -- The extension depends on the configured format, so the file is found by
  -- looking for what appeared rather than by assuming one.
  local base = dir .. "/" .. filename
  for _, ext in ipairs({ "opus", "ogg", "mp3", "wav", "flac", "m4a", "aiff" }) do
    local candidate = base .. "." .. ext
    if M.file_info(candidate) then return candidate end
  end
  if M.file_info(base) then return base end

  return nil, "render produced no file at " .. base .. ".*"
end

return M
