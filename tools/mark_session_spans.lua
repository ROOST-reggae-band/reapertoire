-- tools/mark_session_spans.lua
-- Marks where each rehearsal sits on the project timeline.
--
-- One project holds many rehearsals appended end to end, and nothing in the
-- arrange view says where one stops and the next begins -- the takes are
-- visible, the rehearsal they belong to is not. This writes a pair of markers
-- per session, from the sidecar that already records those ranges.
--
-- Re-runnable: it replaces its own markers rather than adding another set.

local script_path = ({ reaper.get_action_context() })[2]
local repo_dir = REAPERTOIRE_DIR or script_path:match("^(.*)[/\\]tools[/\\][^/\\]*$")
package.path = repo_dir .. "/?.lua;" .. repo_dir .. "/?/init.lua;" .. package.path

local adapter = require("adapters.reaper_api")
local markers = require("adapters.markers")
local session_lib = require("lib.session")
local time = require("lib.util.time")

local function log(fmt, ...)
  reaper.ShowConsoleMsg(string.format(fmt .. "\n", ...))
end

reaper.ClearConsole()

local _, project_file = reaper.EnumProjects(-1)
if not project_file or project_file == "" then
  log("Save the project first -- the session record is stored beside the .rpp.")
  return
end

local sidecar = project_file:match("^(.*)[/\\][^/\\]*$") .. "/" .. session_lib.FILENAME
local doc = session_lib.decode(adapter.read_file(sidecar))

if #doc.sessions == 0 then
  local removed = markers.clear("Reapertoire: clear session markers")
  log("No rehearsals recorded for this project yet.")
  if removed > 0 then log("Removed %d marker%s from a previous run.",
    removed, removed == 1 and "" or "s") end
  log("Tune and render a session first; the record is written then.")
  return
end

-- Sorted so the console reads down the timeline, which is how the markers will
-- be met in the arrange view.
local ordered = {}
for _, s in ipairs(doc.sessions) do ordered[#ordered + 1] = s end
table.sort(ordered, function(a, b)
  return ((a.range or {}).start or 0) < ((b.range or {}).start or 0)
end)

local wanted, described, skipped = {}, {}, 0
for _, s in ipairs(ordered) do
  local pair = session_lib.span_markers(s)
  if #pair == 0 then
    skipped = skipped + 1
  else
    for _, marker in ipairs(pair) do wanted[#wanted + 1] = marker end
    described[#described + 1] = string.format("  %s to %s  %s",
      time.hms(pair[1].at), time.hms(pair[2].at), pair[1].name)
  end
end

-- REAPER's own orange-ish marker colour, set explicitly so these read as one
-- family rather than inheriting whatever the theme gives an uncoloured marker.
local COLOR = reaper.ColorToNative(224, 152, 64) | 0x1000000

local placed = markers.replace(wanted, COLOR, "Reapertoire: show session spans")

log("Marked %d rehearsal%s (%d marker%s):",
  #described, #described == 1 and "" or "s", placed, placed == 1 and "" or "s")
for _, line in ipairs(described) do log("%s", line) end
if skipped > 0 then
  log("\n%d session%s had no recorded range and were left unmarked.",
    skipped, skipped == 1 and "" or "s")
end
log("\nRun again after rendering to update them; it replaces rather than adds.")
