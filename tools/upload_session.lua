-- tools/upload_session.lua
-- Pushes the current session's rendered takes to the library server.
--
-- The work is done by tools/ingest/upload.py, which needs no DAW: the manifest
-- holds every fact the API asks for. This is only the convenience of running it
-- from the same menu as everything else.

local script_path = ({ reaper.get_action_context() })[2]
local repo_dir = REAPERTOIRE_DIR or script_path:match("^(.*)[/\\]tools[/\\][^/\\]*$")
package.path = repo_dir .. "/?.lua;" .. repo_dir .. "/?/init.lua;" .. package.path

local adapter = require("adapters.reaper_api")
local config = require("lib.config")
local session_lib = require("lib.session")
local manifest_lib = require("lib.manifest")
local json = require("lib.util.json")
local background = require("adapters.background")

local function log(fmt, ...)
  reaper.ShowConsoleMsg(string.format(fmt .. "\n", ...))
end

reaper.ClearConsole()

local ok, cfg = pcall(config.load, repo_dir, adapter.read_file)
if not ok then
  log("Configuration problem:\n  %s", tostring(cfg))
  return
end

local api = cfg.ingest and cfg.ingest.api
if not api or api == "" then
  log("No ingest API configured.")
  log('Add {"ingest": {"api": "https://.../api/ingest/v1"}} to config/settings.json.')
  return
end

local sel_start, sel_stop = adapter.time_selection()
if not sel_start then
  log("No time selection. Select the rehearsal to upload and run again.")
  return
end

local _, project_file = reaper.EnumProjects(-1)
if not project_file or project_file == "" then
  log("Save the project first.")
  return
end
local sidecar = project_file:match("^(.*)[/\\][^/\\]*$") .. "/" .. session_lib.FILENAME
local doc = session_lib.decode(adapter.read_file(sidecar))
local session, how = session_lib.find(doc, sel_start, sel_stop)

if how ~= "existing" or not session.outputDir then
  log("No rendered session covers this selection. Render it first.")
  return
end

local manifest = session.outputDir .. "/manifest.json"
local manifest_raw = adapter.read_file(manifest)
if not manifest_raw then
  log("No manifest at %s -- render this session first.", manifest)
  return
end

-- The sidecar owns what a rehearsal IS -- its kind, date, label, venue, notes
-- -- and the manifest carries a copy so it stays self-contained for a push
-- from anywhere. Refreshed here, at the one moment the copy has to be true,
-- because the alternative was a full re-render: hours of re-encoding audio
-- that had not changed, to correct a venue.
local metadata_changed = false
do
  local parsed = json.decode(manifest_raw)
  if manifest_lib.refresh_event(parsed, session) then
    local encoded = json.encode(parsed, { indent = true })
    if encoded ~= manifest_raw then
      local tmp = manifest .. ".tmp"
      local handle = io.open(tmp, "w")
      if handle then
        handle:write(encoded)
        handle:close()
        -- Renamed over the original: a crash midway leaves the manifest
        -- intact rather than half a file, with the audio still on disk and
        -- nothing describing it.
        os.rename(tmp, manifest)
        metadata_changed = true
        log("Refreshed the manifest from the session record.")
      else
        log("Could not update %s -- uploading it as it stands.", manifest)
      end
    end
  else
    log("The manifest belongs to a different session; uploading it as it stands.")
  end
end

-- Asked only when the local record actually differs from what was last sent,
-- which is the only moment the question means anything. The library ignores a
-- re-post's metadata unless told otherwise, precisely so a routine re-run
-- cannot revert a correction somebody made there -- so overwriting has to be
-- somebody saying yes, not a default.
local update_metadata = false
if metadata_changed then
  local answer = reaper.MB(
    "This rehearsal's details have changed since it was last uploaded.\n\n" ..
    "Overwrite the library's copy with the local record?\n" ..
    "(kind, title, date, venue and notes -- takes and audio are unaffected)\n\n" ..
    "No uploads the audio without touching them.",
    "Reapertoire - overwrite metadata?", 3)
  if answer == 2 then return end       -- cancel
  update_metadata = answer == 6        -- yes
end

-- Output goes to a file the poller tails rather than down a pipe -- see
-- `adapters/background` for why, and for the shell quoting.
--
-- `-u` matters: Python buffers stdout in blocks when it is not a terminal, so
-- without it the file fills 8KB at a time and the progress lines arrive in
-- lumps long after the files they describe.
local log_path = session.outputDir .. "/.upload.log"
local command = string.format("%s -u %s --manifest %s --api %s%s",
  background.quote(repo_dir .. "/.venv/bin/python"),
  background.quote(repo_dir .. "/tools/ingest/upload.py"),
  background.quote(manifest), background.quote(api),
  update_metadata and " --update-metadata" or "")

log("Uploading %s", manifest)
log("REAPER stays usable -- this window fills in as files go up.")

background.run(command, log_path,
  function(text) reaper.ShowConsoleMsg(text) end,
  function(ok, code)
    if ok then
      log("\nUpload finished.")
    else
      log("\nUpload failed (exit %d). The log is at %s", code, log_path)
    end
  end)
