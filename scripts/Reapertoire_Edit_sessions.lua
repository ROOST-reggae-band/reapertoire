-- scripts/Reapertoire_Edit_sessions.lua
-- Edits the rehearsal records this project holds.
--
-- A session is created once, from a three-field prompt at render time, and was
-- never editable afterwards: a mistyped date stayed mistyped, every rehearsal
-- was labelled "session", and venue and notes -- both of which the library
-- accepts and shows -- could not be set at all, because nothing wrote them.
--
-- Deleting removes the RECORD. The rendered audio and its manifest stay where
-- they are; nothing here ever costs anybody a rehearsal.

if reaper.set_action_options then reaper.set_action_options(1 | 2) end

local script_path = ({ reaper.get_action_context() })[2]
local repo_dir = REAPERTOIRE_DIR or script_path:match("^(.*)[/\\]scripts[/\\][^/\\]*$")
package.path = repo_dir .. "/?.lua;" .. repo_dir .. "/?/init.lua;" .. package.path

local adapter = require("adapters.reaper_api")
local session_lib = require("lib.session")
local time = require("lib.util.time")

local ImGui
do
  if reaper.ImGui_GetBuiltinPath then
    local ok, mod = pcall(function()
      package.path = package.path .. ";" .. reaper.ImGui_GetBuiltinPath() .. "/?.lua"
      return require("imgui")("0.10")
    end)
    if ok then ImGui = mod end
  end
  if not ImGui and reaper.ImGui_CreateContext then
    ImGui = setmetatable({}, {
      __index = function(_, k) return reaper["ImGui_" .. k] end,
    })
  end
  if not ImGui then
    reaper.MB("ReaImGui is not installed.", "Reapertoire", 0)
    return
  end
end

-- ReaImGui exposes enum values as accessor functions in some versions and as
-- plain numbers in others. Resolve once rather than assuming either.
local ENUM = setmetatable({}, {
  __index = function(t, name)
    local v = ImGui[name]
    if type(v) == "function" then v = v() end
    rawset(t, name, v)
    return v
  end,
})

local _, project_file = reaper.EnumProjects(-1)
if not project_file or project_file == "" then
  reaper.MB("Save the project first -- the session record is stored beside the .rpp.",
    "Reapertoire", 0)
  return
end
local sidecar_path = project_file:match("^(.*)[/\\][^/\\]*$") .. "/" .. session_lib.FILENAME

-- ------------------------------------------------------------------- state

local doc, view, selected = nil, {}, 1
local status = ""
local confirming_delete = nil   -- the id awaiting a second press
local edits = {}                -- the selected session's fields, as typed

-- Sorted down the timeline, which is the order they will be met in the arrange
-- view and the order the span markers appear in.
local function rebuild_view()
  view = {}
  for _, s in ipairs(doc.sessions or {}) do view[#view + 1] = s end
  table.sort(view, function(a, b)
    return ((a.range or {}).start or 0) < ((b.range or {}).start or 0)
  end)
  if selected > #view then selected = #view end
  if selected < 1 then selected = 1 end
end

-- The typed fields are held apart from the record so an edit can be abandoned,
-- and so a half-typed date never reaches the session.
local function load_edits()
  local s = view[selected]
  if not s then edits = {}; return end
  edits = {
    date = (s.heldAt or ""):sub(1, 10),
    label = s.label or "",
    kind = s.kind or "rehearsal",
    venue = s.venue or "",
    notes = s.notes or "",
  }
end

local function reload()
  doc = session_lib.decode(adapter.read_file(sidecar_path))
  rebuild_view()
  load_edits()
  confirming_delete = nil
end

reload()

local function save()
  local tmp = sidecar_path .. ".tmp"
  local handle = io.open(tmp, "w")
  if not handle then
    status = "Could not write " .. sidecar_path
    return false
  end
  handle:write(session_lib.encode(doc))
  handle:close()
  -- Renamed over the original rather than written in place: a crash midway
  -- through leaves the old record intact instead of half a file.
  os.rename(tmp, sidecar_path)
  return true
end

local function apply()
  local s = view[selected]
  if not s then return end
  local problems = session_lib.update(s, edits)
  if #problems > 0 then
    status = table.concat(problems, "  |  ")
    return
  end
  if save() then
    rebuild_view()
    load_edits()
    status = string.format("Saved %s", s.label or s.id)
  end
end

local function delete_selected()
  local s = view[selected]
  if not s then return end
  local label = s.label or s.id
  if session_lib.remove(doc, s.id) and save() then
    rebuild_view()
    load_edits()
    status = string.format(
      '"%s" removed from the record. Its rendered files are untouched.', label)
  end
  confirming_delete = nil
end

-- ---------------------------------------------------------------------- loop

local ctx = ImGui.CreateContext("Reapertoire sessions")

local function frame()
  ImGui.SetNextWindowSize(ctx, 900, 480, ENUM.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, "Reapertoire - sessions", true)
  if visible then
    ImGui.Text(ctx, string.format("%d rehearsal%s recorded in this project",
      #view, #view == 1 and "" or "s"))
    if status ~= "" then ImGui.Text(ctx, status) end
    ImGui.Separator(ctx)

    ImGui.BeginGroup(ctx)
    if ImGui.BeginChild(ctx, "sessions", -420, -34) then
      for i, s in ipairs(view) do
        local range = s.range or {}
        local shown = string.format("%s %-14s %s  %d take%s",
          (s.heldAt or "undated"):sub(1, 10), s.label or "(unlabelled)",
          range.start and time.hms(range.start) or "?",
          session_lib.take_count(s), session_lib.take_count(s) == 1 and "" or "s")
        if ImGui.Selectable(ctx, shown, i == selected) then
          selected = i
          load_edits()
          confirming_delete = nil
          status = ""
        end
      end
      ImGui.EndChild(ctx)
    end
    ImGui.EndGroup(ctx)

    ImGui.SameLine(ctx)

    ImGui.BeginGroup(ctx)
    if ImGui.BeginChild(ctx, "detail", 0, -34) then
      local s = view[selected]
      if s then
        local changed

        changed, edits.date = ImGui.InputText(ctx, "date (YYYY-MM-DD)", edits.date)
        changed, edits.label = ImGui.InputText(ctx, "label", edits.label)

        -- A combo rather than a text field: the server takes exactly these
        -- three and rejects anything else with a 422 part-way through an
        -- upload, which is a long way from where the typo happened.
        if ImGui.BeginCombo(ctx, "kind", edits.kind) then
          for _, kind in ipairs(session_lib.KINDS) do
            if ImGui.Selectable(ctx, kind, kind == edits.kind) then
              edits.kind = kind
            end
          end
          ImGui.EndCombo(ctx)
        end

        changed, edits.venue = ImGui.InputText(ctx, "venue", edits.venue)
        changed, edits.notes = ImGui.InputText(ctx, "notes", edits.notes)

        ImGui.Separator(ctx)
        local range = s.range or {}
        if range.start and range.stop then
          ImGui.Text(ctx, string.format("Spans %s to %s  (%.0f min)",
            time.hms(range.start), time.hms(range.stop),
            (range.stop - range.start) / 60))
        else
          ImGui.Text(ctx, "No recorded range -- it will not be marked on the timeline.")
        end
        ImGui.Text(ctx, string.format("%d take%s rendered",
          session_lib.take_count(s), session_lib.take_count(s) == 1 and "" or "s"))
        ImGui.Text(ctx, s.outputDir or "(not rendered yet)")
      else
        ImGui.Text(ctx, "No rehearsals recorded yet.")
        ImGui.Text(ctx, "Tune and render a session first; the record is written then.")
      end
      ImGui.EndChild(ctx)
    end
    ImGui.EndGroup(ctx)

    ImGui.Separator(ctx)
    if ImGui.Button(ctx, "Apply") then apply() end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Reload") then reload(); status = "Reloaded" end

    local s = view[selected]
    if s then
      ImGui.SameLine(ctx)
      if confirming_delete == s.id then
        if ImGui.Button(ctx, "Really delete the record?") then delete_selected() end
        ImGui.SameLine(ctx)
        if ImGui.Button(ctx, "Cancel") then confirming_delete = nil end
        ImGui.SameLine(ctx)
        ImGui.Text(ctx, "The rendered audio stays on disk.")
      elseif ImGui.Button(ctx, "Delete this session") then
        confirming_delete = s.id
      end
    end

    ImGui.End(ctx)
  end

  if open then reaper.defer(frame) end
end

reaper.defer(frame)
