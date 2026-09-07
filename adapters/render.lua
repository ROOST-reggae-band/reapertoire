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

-- Observed rather than documented: the reference says "&2=stems only", but a
-- project set to master mix reads 16 and one set to selected-tracks-stems reads
-- 19, i.e. bits 1 and 2 together. Setting 2 alone renders the master mix.
local MODE_BITS = 3
local MODE_MASTER = 0
local MODE_STEMS = 3

-- The rest of the mask is the operator's (bit 16 = mono media to mono files,
-- and so on), so only the mode bits are ever changed.
local function with_mode(mode)
  local current = reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", 0, false)
  return (math.floor(current) & ~MODE_BITS) | mode
end

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

-- Renders one file per given track in a single pass. REAPER's stems-only mode
-- writes a file per selected track, which beats one render pass per instrument.
--
-- `tracks` are { media_track, slug }. Returns a map of slug to path, plus a
-- list of slugs whose file never appeared.
function M.stems(dir, tracks, start_time, stop_time, log)
  log = log or function() end
  if #tracks == 0 then return {}, {} end
  if not M.format_configured() then
    return {}, {}, "no render format configured in this project"
  end

  -- Start from an empty directory. A previous run's stems linger otherwise,
  -- and a slug that disappears from the mapping would leave a stale file
  -- claiming to be part of this take.
  do
    local existing, idx = {}, 0
    while true do
      local name = reaper.EnumerateFiles(dir, idx)
      if not name then break end
      existing[#existing + 1] = dir .. "/" .. name
      idx = idx + 1
    end
    for _, path in ipairs(existing) do os.remove(path) end
  end

  local saved = snapshot()

  -- Track selection is the operator's, so it is restored along with everything
  -- else however the render goes.
  local was_selected = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local t = reaper.GetTrack(0, i)
    was_selected[i] = reaper.IsTrackSelected(t)
    reaper.SetTrackSelected(t, false)
  end

  -- The master track is not part of CountTracks, so the loop above never
  -- reaches it. Left selected it renders as a stem called Master, duplicating
  -- the master mix inside the stems folder.
  local master = reaper.GetMasterTrack(0)
  local master_was_selected = reaper.IsTrackSelected(master)
  reaper.SetTrackSelected(master, false)

  for _, entry in ipairs(tracks) do
    if entry.media_track then
      reaper.SetTrackSelected(entry.media_track, true)
    else
      log("      no REAPER track behind slug %s", tostring(entry.slug))
    end
  end

  local selected = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local t = reaper.GetTrack(0, i)
    if reaper.IsTrackSelected(t) then
      local _, n = reaper.GetSetMediaTrackInfo_String(t, "P_NAME", "", false)
      selected[#selected + 1] = n
    end
  end
  log("      selected for stems: %s", #selected > 0 and table.concat(selected, ", ") or "NONE")

  reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 0, true)
  reaper.GetSetProjectInfo(0, "RENDER_STARTPOS", start_time, true)
  reaper.GetSetProjectInfo(0, "RENDER_ENDPOS", stop_time, true)
  reaper.GetSetProjectInfo(0, "RENDER_TAILFLAG", 0, true)
  reaper.GetSetProjectInfo(0, "RENDER_ADDTOPROJ", 0, true)
  reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", with_mode(MODE_STEMS), true)
  reaper.GetSetProjectInfo_String(0, "RENDER_FILE", dir, true)
  reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", "$track", true)

  local applied = reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", 0, false)
  log("      RENDER_SETTINGS=%d (mode bits %d = stems)", applied, applied & MODE_BITS)

  reaper.Main_OnCommand(RENDER_ACTION, 0)

  local produced, idx = {}, 0
  while true do
    local name = reaper.EnumerateFiles(dir, idx)
    if not name then break end
    produced[#produced + 1] = name
    idx = idx + 1
  end
  log("      files produced: %s", #produced > 0 and table.concat(produced, ", ") or "NONE")

  for i = 0, reaper.CountTracks(0) - 1 do
    reaper.SetTrackSelected(reaper.GetTrack(0, i), was_selected[i] or false)
  end
  reaper.SetTrackSelected(master, master_was_selected)
  restore(saved)

  -- Files land under the track's name; the manifest wants the instrument slug,
  -- so each is renamed once found.
  local written, missing = {}, {}
  for _, entry in ipairs(tracks) do
    local found
    for _, ext in ipairs({ "opus", "ogg", "mp3", "wav", "flac", "m4a", "aiff" }) do
      local candidate = string.format("%s/%s.%s", dir, entry.name, ext)
      if M.file_info(candidate) then
        local target = string.format("%s/%s.%s", dir, entry.slug, ext)
        if candidate == target then
          found = candidate
        elseif candidate:lower() == target:lower() then
          -- Case-only rename on a case-insensitive filesystem: "Bass.mp3" and
          -- "bass.mp3" are the same file, so removing the target first deletes
          -- the source. Go via a third name.
          local staging = target .. ".renaming"
          if os.rename(candidate, staging) and os.rename(staging, target) then
            found = target
          else
            os.rename(staging, candidate)
            found = M.file_info(candidate) and candidate or nil
          end
        else
          os.remove(target)
          if os.rename(candidate, target) then found = target else found = candidate end
        end
        break
      end
    end
    if found then written[entry.slug] = found else missing[#missing + 1] = entry.slug end
  end

  -- This directory is created per take and holds only the stems asked for, so
  -- anything else in it came from the render and is not wanted -- a stray
  -- Master duplicating the master mix, most likely.
  local keep = {}
  for _, path in pairs(written) do keep[path:lower()] = true end
  local index = 0
  local strays = {}
  while true do
    local name = reaper.EnumerateFiles(dir, index)
    if not name then break end
    local full = dir .. "/" .. name
    if not keep[full:lower()] then strays[#strays + 1] = full end
    index = index + 1
  end
  for _, path in ipairs(strays) do os.remove(path) end

  return written, missing
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
  -- Explicit: the project may be left in stems mode from a previous pass, and
  -- this one must produce the master mix.
  reaper.GetSetProjectInfo(0, "RENDER_SETTINGS",
    settings_mask or with_mode(MODE_MASTER), true)
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
