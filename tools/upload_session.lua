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

-- Single-quoted, the only quoting /bin/sh guarantees: everything inside is
-- literal, and an embedded quote is closed, escaped and reopened. Lua's %q is
-- Lua's escaping, not the shell's, and differs on exactly the characters a
-- path is most likely to contain.
local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

-- Output goes to a file the poller tails rather than down a pipe. `read("*a")`
-- on a pipe waits for the process to EXIT, and REAPER is single-threaded, so
-- the whole DAW froze for the length of the upload -- minutes on a session of
-- a few hundred megabytes -- and every line of output arrived at once, after
-- it no longer told anyone anything.
local log_path = session.outputDir .. "/.upload.log"
os.remove(log_path)

-- `-u` matters: Python buffers stdout in blocks when it is not a terminal, so
-- without it the file fills 8KB at a time and the progress lines arrive in
-- lumps long after the files they describe.
local DONE = "__reapertoire_done "
local command = string.format(
  "%s -u %s --manifest %s --api %s >%s 2>&1; echo %s$? >>%s",
  shell_quote(repo_dir .. "/.venv/bin/python"),
  shell_quote(repo_dir .. "/tools/ingest/upload.py"),
  shell_quote(manifest), shell_quote(api),
  shell_quote(log_path), shell_quote(DONE), shell_quote(log_path))

-- REAPER does not inherit a login shell, so this runs through one; `&` detaches
-- it so os.execute returns straight away and the UI stays alive.
os.execute(string.format("/bin/sh -lc %s &", shell_quote(command)))

log("Uploading %s", manifest)
log("REAPER stays usable -- this window fills in as files go up.")

-- Tails the log, printing only what is new. Deferred rather than looped: a
-- loop here would block the UI exactly as `read("*a")` did.
local shown = 0
local function poll()
  local handle = io.open(log_path, "r")
  if handle then
    handle:seek("set", shown)
    local fresh = handle:read("*a") or ""
    handle:close()
    if #fresh > 0 then
      shown = shown + #fresh
      local finished = fresh:match(DONE .. "(%d+)")
      if finished then
        fresh = fresh:gsub(DONE .. "%d+%s*", "")
      end
      if #fresh > 0 then reaper.ShowConsoleMsg(fresh) end
      if finished then
        log("\n%s", finished == "0" and "Upload finished."
          or string.format("Upload failed (exit %s). The log is at %s",
            finished, log_path))
        return
      end
    end
  end
  reaper.defer(poll)
end

poll()
