-- scripts/Reapertoire.lua
-- One entry point for everything, so the toolbar needs a single button.
--
-- The tools are loaded with dofile rather than run through the action list,
-- which means they never need to be registered as separate actions and there
-- are no command IDs to keep in step.

local script_path = ({ reaper.get_action_context() })[2]
local repo_dir = script_path:match("^(.*)[/\\]scripts[/\\][^/\\]*$")

-- No separators: whether gfx.showmenu counts them in the returned index is
-- version-dependent, and getting it wrong silently launches the wrong tool.
local ITEMS = {
  { label = "Create take regions",               file = "scripts/Reapertoire_Tune_takes.lua" },
  { label = "Name takes",                        file = "scripts/Reapertoire_Name_takes.lua" },
  { label = "Render named takes",                file = "scripts/Reapertoire_Render.lua" },
  { label = "Upload session to the library",     file = "tools/upload_session.lua" },
  { label = "Rebuild recognition index",         file = "tools/reindex_references.lua" },
  { label = "Edit sessions",                     file = "scripts/Reapertoire_Edit_sessions.lua" },
  { label = "Mark session spans on the timeline", file = "tools/mark_session_spans.lua" },
  { label = "Debug: analyse without writing anything", file = "scripts/Reapertoire_Analyze_dryrun.lua" },
  { label = "Debug: capture tuning fixture",     file = "tools/capture_fixture.lua" },
  { label = "Debug: show render settings",       file = "tools/probe_render.lua" },
  { label = "Debug: capture probe format",       file = "tools/capture_probe_format.lua" },
}

local labels = {}
for _, item in ipairs(ITEMS) do labels[#labels + 1] = item.label end

-- gfx is the only way to raise a popup at the mouse from a plain ReaScript. The
-- window is never shown: it exists for the duration of the menu and no longer.
gfx.init("", 0, 0, 0, 0, 0)
gfx.x, gfx.y = gfx.mouse_x, gfx.mouse_y
local choice = gfx.showmenu(table.concat(labels, "|"))
gfx.quit()

if choice and choice > 0 then
  local item = ITEMS[choice]
  if item and item.file then
    local path = repo_dir .. "/" .. item.file
    local f = io.open(path, "r")
    if not f then
      reaper.MB("Not found:\n" .. path, "Reapertoire", 0)
      return
    end
    f:close()
    -- dofile'd scripts see THIS file's path from get_action_context, so hand
    -- them the repo root explicitly rather than letting them derive a wrong one.
    REAPERTOIRE_DIR = repo_dir
    dofile(path)
  end
end
