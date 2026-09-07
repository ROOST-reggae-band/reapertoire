-- scripts/Reapertoire_Render.lua
-- Renders the named takes in the current time selection, and writes the
-- manifest and session sidecar beside them.
--
-- Only named takes are rendered. A region still carrying a "Take 3" placeholder
-- is one nobody identified, and rendering it would produce a file nothing can
-- be said about.

if reaper.set_action_options then reaper.set_action_options(1 | 2) end

local script_path = ({ reaper.get_action_context() })[2]
local repo_dir = REAPERTOIRE_DIR or script_path:match("^(.*)[/\\]scripts[/\\][^/\\]*$")
package.path = repo_dir .. "/?.lua;" .. repo_dir .. "/?/init.lua;" .. package.path

local adapter = require("adapters.reaper_api")
local regions = require("adapters.regions")
local render = require("adapters.render")
local config = require("lib.config")
local songs_lib = require("lib.songs")
local naming = require("lib.naming")
local session_lib = require("lib.session")
local manifest_lib = require("lib.manifest")
local json = require("lib.util.json")
local text = require("lib.util.text")

local function log(fmt, ...)
  reaper.ShowConsoleMsg(string.format(fmt .. "\n", ...))
end

reaper.ClearConsole()

local ok, cfg = pcall(config.load, repo_dir, adapter.read_file)
if not ok then
  log("Configuration problem:\n  %s", tostring(cfg))
  return
end

local sel_start, sel_stop = adapter.time_selection()
if not sel_start then
  log("No time selection. Select the rehearsal to render and run again.")
  return
end

if not render.format_configured() then
  log("This project has no render format set.")
  log("Open File > Render, choose the format you want (Opus 128k is a good")
  log("default), close the dialog with Save settings, then run this again.")
  return
end

-- ------------------------------------------------------------- the sidecar

-- Beside the .rpp, not in the media folder: it describes the project's
-- rehearsals, and it must survive the media folder being cleaned out.
local _, project_file = reaper.EnumProjects(-1)
if not project_file or project_file == "" then
  log("Save the project first -- the session record is stored beside the .rpp.")
  return
end
local project_dir = project_file:match("^(.*)[/\\][^/\\]*$")
local sidecar_path = project_dir .. "/" .. session_lib.FILENAME

local doc = session_lib.decode(adapter.read_file(sidecar_path))
local found, how, candidates = session_lib.find(doc, sel_start, sel_stop)

local function describe(list)
  local names = {}
  for _, s in ipairs(list) do
    names[#names + 1] = string.format("%s (%s)", s.label or s.id,
      (s.heldAt or "undated"):sub(1, 10))
  end
  return table.concat(names, ", ")
end

if how == "ambiguous" then
  log("This selection covers %d sessions: %s", #candidates, describe(candidates))
  log("Narrow it to one rehearsal and run again.")
  return
end

if how == "partial" then
  -- Rehearsals sit end to end, so a few seconds of overlap is a near miss
  -- rather than a match. Filing takes under the neighbouring session silently
  -- is worse than stopping.
  log("This selection only clips the edge of: %s", describe(candidates))
  log("It is not enough overlap to call it the same rehearsal, and not")
  log("obviously a different one either.")
  log("Either extend the selection over that session, or move it clear of it.")
  return
end

local session = found

if how == "new" then
  -- Pre-fill the date from a source filename in range: REAPER's recorded names
  -- carry YYMMDD_HHMM, which survives the file being copied in a way mtime
  -- does not.
  local guess_date, guess_time
  for ti = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, ti)
    for ii = 0, reaper.CountTrackMediaItems(track) - 1 do
      local item = reaper.GetTrackMediaItem(track, ii)
      local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      if pos + len > sel_start and pos < sel_stop then
        local take = reaper.GetActiveTake(item)
        if take and not reaper.TakeIsMIDI(take) then
          local src = reaper.GetMediaItemTake_Source(take)
          local d, t = session_lib.date_from_filename(
            reaper.GetMediaSourceFileName(src))
          if d and (not guess_date or d < guess_date) then
            guess_date, guess_time = d, t
          end
        end
      end
    end
  end

  local got, csv = reaper.GetUserInputs("New session", 3,
    "Date (YYYY-MM-DD),Label,Kind (rehearsal/concert/session),extrawidth=180",
    (guess_date or "") .. "," .. "," .. "rehearsal")
  if not got then return end

  local date, label, kind = csv:match("^([^,]*),([^,]*),([^,]*)$")
  if not date or date == "" then
    log("A date is required -- it is how the session is identified downstream.")
    return
  end

  session = {
    id = reaper.genGuid(""),
    kind = (kind ~= "" and kind) or "rehearsal",
    heldAt = session_lib.iso8601(date, guess_time),
    label = label ~= "" and label or "session",
    range = { start = sel_start, stop = sel_stop },
    takes = {},
  }
else
  session.range.start = math.min(session.range.start, sel_start)
  session.range.stop = math.max(session.range.stop, sel_stop)
  -- Sessions recorded before offsets were written get one now, from the date
  -- already stored rather than from today.
  session.heldAt = session_lib.with_offset(session.heldAt)
end

-- --------------------------------------------------------------- the takes

local songs = songs_lib.load(cfg)
local rows = {}
for _, r in ipairs(regions.all()) do
  if r.start < sel_stop and sel_start < r.stop then
    local song, label = naming.parse(r.name, songs)
    if song then
      rows[#rows + 1] = {
        guid = r.guid, start = r.start, stop = r.stop,
        song = song, note = (label and naming.take_number(label) == nil) and label or nil,
      }
    end
  end
end
table.sort(rows, function(a, b) return a.start < b.start end)
naming.renumber(rows)

if #rows == 0 then
  log("No named takes in the selection. Name them first, then render.")
  return
end

-- Which instruments actually play on each take. Free to compute here, where the
-- audio and the project are both to hand, and impossible to reconstruct from
-- the rendered mix afterwards.
log("Reading levels to work out which instruments play on each take...")
local pipeline = require("lib.pipeline")
local presence = require("lib.presence")
local peaks_lib = require("lib.peaks")
local frames_util = require("lib.util.frames")

local detection = cfg.detection
local rate = detection.frameRateHz
local collected, items = adapter.collect(sel_start, sel_stop, rate, cfg.tracks)
local classified = pipeline.classify({
  tracks = collected, items = items,
  sel_start = sel_start, sel_stop = sel_stop, detection = detection,
})
local detect_opts = pipeline.detection_opts(detection)
for _, row in ipairs(rows) do
  row.instruments = presence.instruments_in(
    classified.tracks, row, sel_start, rate, detect_opts)
end

-- Which REAPER track carries each instrument, for the stem pass.
--
-- Folder parents are excluded: they sum their children, so a stem rendered from
-- one duplicates audio already captured by the individual mics. A rule may also
-- opt a track out explicitly, for a submix fed by sends, which looks like any
-- other track.
local track_for_slug = {}
local excluded = {}
for _, t in ipairs(classified.tracks) do
  if t.live and t.slug and t.media_track then
    local rule = config.match_track(t.name, cfg.tracks)
    if t.is_folder then
      excluded[#excluded + 1] = t.name .. " (folder)"
    elseif rule and rule.stem == false then
      excluded[#excluded + 1] = t.name .. " (stem: false)"
    else
      track_for_slug[t.slug] = t
    end
  end
end
if #excluded > 0 then
  log("Not rendering stems for: %s", table.concat(excluded, ", "))
end

local root = config.expand_path(cfg.sessionsRoot)
local out_dir = session.outputDir or (root .. "/" .. session_lib.folder_name(session))
session.outputDir = out_dir

-- Always confirm. Rendering writes files, can take minutes, and the session it
-- files them under is inferred -- so the inference gets shown before anything
-- happens rather than discovered afterwards.
local summary = {
  string.format("%s: %s", how == "new" and "New session" or "Existing session",
    session.label or session.id),
  string.format("Date: %s", (session.heldAt or "?"):sub(1, 10)),
  string.format("Folder: %s", out_dir),
  "",
  string.format("%d named take%s will be rendered.", #rows, #rows == 1 and "" or "s"),
  (cfg.render and cfg.render.stems)
    and "Master, peaks and per-instrument stems for each."
    or "Master and peaks for each.",
}
if how == "existing" then
  summary[#summary + 1] = ""
  summary[#summary + 1] = "Takes already rendered for this session will be replaced."
end

if reaper.MB(table.concat(summary, "\n"), "Reapertoire - render", 1) ~= 1 then
  log("Cancelled.")
  return
end

log("Rendering %d take%s to %s", #rows, #rows == 1 and "" or "s", out_dir)

local rendered = {}
for i, row in ipairs(rows) do
  local folder = string.format("%s/%02d-%s-%s", out_dir, i, text.slug(row.song), text.slug(row.label))
  reaper.RecursiveCreateDirectory(folder, 0)

  local srate, channels = render.output_format()
  local path, err = render.take(folder, "master", row.start, row.stop)
  if not path then
    log("  %2d  %-24s FAILED: %s", i, row.song, tostring(err))
  else
    local bytes = render.file_info(path)
    row.assets = { {
      kind = "master",
      tier = "lossy",
      format = path:match("%.(%w+)$"),
      path = path,
      bytes = bytes,
      sha256 = render.sha256(path),
      durationMs = math.floor((row.stop - row.start) * 1000 + 0.5),
      sampleRate = srate > 0 and srate or nil,
      channels = channels > 0 and channels or nil,
    } }
    log("  %2d  %-24s %s (%.1f MB)  %s", i, row.song,
      path:match("([^/\\]+)$"), (bytes or 0) / 1048576,
      table.concat(row.instruments or {}, ", "))

    -- Peaks, from level data already in hand. A browser would have to download
    -- and decode the whole file to draw the same picture.
    local i0, i1 = frames_util.range_of(row, sel_start, rate, classified.n_frames)
    local peaks_path = folder .. "/peaks.json"
    local pf = io.open(peaks_path, "w")
    if pf then
      pf:write(json.encode(peaks_lib.folded(classified.tracks, i0, i1)))
      pf:close()
      row.assets[#row.assets + 1] = {
        kind = "peaks", tier = "lossy", format = "json",
        path = peaks_path, bytes = render.file_info(peaks_path),
        sha256 = render.sha256(peaks_path),
      }
    end

    -- Stems, only for instruments actually played on this take. An absent
    -- player must not produce a silent file.
    if cfg.render and cfg.render.stems then
      local wanted = {}
      for _, slug in ipairs(row.instruments or {}) do
        local t = track_for_slug[slug]
        if t then wanted[#wanted + 1] = { media_track = t.media_track, slug = slug, name = t.name } end
      end
      log("      stems wanted: %d of %d instruments have a mapped live track",
        #wanted, #(row.instruments or {}))
      if #wanted > 0 then
        local stem_dir = folder .. "/stems"
        reaper.RecursiveCreateDirectory(stem_dir, 0)
        local written, missing = render.stems(stem_dir, wanted, row.start, row.stop, log)
        local n = 0
        for slug, stem_path in pairs(written) do
          n = n + 1
          row.assets[#row.assets + 1] = {
            kind = "stem", instrument = slug, tier = "lossy",
            format = stem_path:match("%.(%w+)$"), path = stem_path,
            bytes = render.file_info(stem_path), sha256 = render.sha256(stem_path),
            durationMs = math.floor((row.stop - row.start) * 1000 + 0.5),
            sampleRate = srate > 0 and srate or nil,
            channels = channels > 0 and channels or nil,
          }
        end
        log("      %d stem%s%s", n, n == 1 and "" or "s",
          #missing > 0 and (" (missing: " .. table.concat(missing, ", ") .. ")") or "")
      end
    end

    rendered[#rendered + 1] = row
  end
end

-- ------------------------------------------------------------ the manifest

local manifest = manifest_lib.build(session, rendered)
local problems = manifest_lib.problems(manifest)

local manifest_path = out_dir .. "/manifest.json"
local f = io.open(manifest_path, "w")
if f then
  f:write(json.encode(manifest, { indent = true }))
  f:close()
  log("Manifest written to %s", manifest_path)
else
  log("Could not write %s", manifest_path)
end

session_lib.merge_takes(session, manifest.takes)
session_lib.upsert(doc, session)

local tmp = sidecar_path .. ".tmp"
local sf = io.open(tmp, "w")
if sf then
  sf:write(session_lib.encode(doc))
  sf:close()
  os.rename(tmp, sidecar_path)
  log("Session record updated: %s", sidecar_path)
else
  log("Could not write %s", sidecar_path)
end

if #problems > 0 then
  log("")
  log("Worth fixing before this goes anywhere:")
  for _, p in ipairs(problems) do log("  %s", p) end
end
