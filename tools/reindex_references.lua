-- tools/reindex_references.lua
-- Rebuilds the song-recognition reference library from every named take that
-- has been rendered.
--
-- Run it after rendering. Recognition can only suggest songs it has references
-- for, so a session's takes do not help until they are indexed -- and the
-- library is derived data, rebuilt from the manifests, so this is always safe
-- to run.

local script_path = ({ reaper.get_action_context() })[2]
local repo_dir = REAPERTOIRE_DIR or script_path:match("^(.*)[/\\]tools[/\\][^/\\]*$")
package.path = repo_dir .. "/?.lua;" .. repo_dir .. "/?/init.lua;" .. package.path

local adapter = require("adapters.reaper_api")
local config = require("lib.config")
local recognise = require("adapters.recognise")

local function log(fmt, ...)
  reaper.ShowConsoleMsg(string.format(fmt .. "\n", ...))
end

reaper.ClearConsole()

local ok, cfg = pcall(config.load, repo_dir, adapter.read_file)
if not ok then
  log("Configuration problem:\n  %s", tostring(cfg))
  return
end

if not recognise.available(repo_dir) then
  log("Recognition is not set up. Run ./bin/setup-recognise in the repo.")
  return
end

local root = config.expand_path(cfg.sessionsRoot)
local references = root .. "/" .. recognise.REFERENCES

log("Reading every named take under %s ...", root)
local summary, err = recognise.index(repo_dir, root, references)
if not summary then
  log("Failed: %s", tostring(err))
  return
end

log("")
local total = summary.total or 0
if total == 0 then
  log("No named takes have been rendered yet, so there is nothing to index.")
  log("Name some takes and render them first.")
  return
end

local songs = {}
for title, count in pairs(summary.songs or {}) do
  songs[#songs + 1] = string.format("%s (%d)", title, count)
end
table.sort(songs)

log("Indexed %d take%s across %d song%s:",
  total, total == 1 and "" or "s", #songs, #songs == 1 and "" or "s")
for _, line in ipairs(songs) do log("  %s", line) end
log("")
log("Written to %s", references)
