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
if not adapter.read_file(manifest) then
  log("No manifest at %s -- render this session first.", manifest)
  return
end

-- Output goes to a file the poller tails rather than down a pipe -- see
-- `adapters/background` for why, and for the shell quoting.
--
-- `-u` matters: Python buffers stdout in blocks when it is not a terminal, so
-- without it the file fills 8KB at a time and the progress lines arrive in
-- lumps long after the files they describe.
local log_path = session.outputDir .. "/.upload.log"
local command = string.format("%s -u %s --manifest %s --api %s",
  background.quote(repo_dir .. "/.venv/bin/python"),
  background.quote(repo_dir .. "/tools/ingest/upload.py"),
  background.quote(manifest), background.quote(api))

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
