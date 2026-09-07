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

if how == "ambiguous" then
  local names = {}
  for _, s in ipairs(candidates) do names[#names + 1] = s.label or s.id end
  log("This selection spans %d sessions (%s).", #candidates, table.concat(names, ", "))
  log("Narrow it to one rehearsal and run again.")
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
    heldAt = date .. "T" .. (guess_time or "00:00") .. ":00",
    label = label ~= "" and label or "session",
    range = { start = sel_start, stop = sel_stop },
    takes = {},
  }
else
  session.range.start = math.min(session.range.start, sel_start)
  session.range.stop = math.max(session.range.stop, sel_stop)
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

local root = config.expand_path(cfg.sessionsRoot)
local out_dir = session.outputDir or (root .. "/" .. session_lib.folder_name(session))
session.outputDir = out_dir

log("Rendering %d take%s to %s", #rows, #rows == 1 and "" or "s", out_dir)

local rendered = {}
for i, row in ipairs(rows) do
  local folder = string.format("%s/%02d-%s-%s", out_dir, i, text.slug(row.song), text.slug(row.label))
  reaper.RecursiveCreateDirectory(folder, 0)

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
    } }
    rendered[#rendered + 1] = row
    log("  %2d  %-24s %s (%.1f MB)", i, row.song,
      path:match("([^/\\]+)$"), (bytes or 0) / 1048576)
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
