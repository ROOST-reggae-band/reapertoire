-- scripts/Reapertoire_Name_takes.lua
-- Names the regions in the project: pick a song per take, a few keystrokes each.
--
-- Works off regions rather than detection output, so naming survives closing
-- the project. Reopening parses the existing names back apart and carries on
-- from wherever it stopped.

if reaper.set_action_options then reaper.set_action_options(1 | 2) end

local script_path = ({ reaper.get_action_context() })[2]
-- REAPERTOIRE_DIR is set when this runs via the launcher, which dofiles
-- us and would otherwise have us derive the path from ITS location.
local repo_dir = REAPERTOIRE_DIR or script_path:match("^(.*)[/\\]scripts[/\\][^/\\]*$")
package.path = repo_dir .. "/?.lua;" .. repo_dir .. "/?/init.lua;" .. package.path

local adapter = require("adapters.reaper_api")
local regions = require("adapters.regions")
local config = require("lib.config")
local songs_lib = require("lib.songs")
local naming = require("lib.naming")
local text = require("lib.util.text")

local function mmss(t)
  local m = math.floor(t / 60)
  return string.format("%d:%05.2f", m, t - m * 60)
end

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
local KEY = setmetatable({}, {
  __index = function(t, name)
    local v = ImGui[name]
    if type(v) == "function" then v = v() end
    rawset(t, name, v)
    return v
  end,
})

local ok, cfg = pcall(config.load, repo_dir, adapter.read_file)
if not ok then
  reaper.MB("Configuration problem:\n\n" .. tostring(cfg), "Reapertoire", 0)
  return
end

local songs = songs_lib.load(cfg)

-- ----------------------------------------------------------------- the rows

local rows = {}
local selected = 1
local query = ""
local status = ""
local focus_filter = false

-- Reads every region in the project into a row, parsing any name this tool
-- could have written back into song and label.
local function load_rows()
  rows = {}
  for _, r in ipairs(regions.all()) do
    local song, label = naming.parse(r.name, songs)
    local note = nil
    if label and naming.take_number(label) == nil then note = label end
    rows[#rows + 1] = {
      guid = r.guid,
      num = r.num,
      start = r.start,
      stop = r.stop,
      original = r.name,
      song = song,
      note = note,
    }
  end
  table.sort(rows, function(a, b) return a.start < b.start end)
  naming.renumber(rows)
end

load_rows()

local function unnamed_after(from)
  for i = from, #rows do
    if not rows[i].song then return i end
  end
  for i = 1, #rows do
    if not rows[i].song then return i end
  end
  return nil
end

local function seek_and_play(row)
  reaper.SetEditCurPos(row.start, true, true)
  local playing = reaper.GetPlayState() & 1 == 1
  if not playing then reaper.OnPlayButton() end
end

local function apply_names()
  naming.renumber(rows)
  local written = 0
  for _, row in ipairs(rows) do
    local name = naming.region_name(row)
    if name and name ~= row.original then
      if regions.rename(row.guid, name) then
        row.original = name
        written = written + 1
      end
    end
  end
  status = string.format("Renamed %d region%s", written, written == 1 and "" or "s")
end

-- ---------------------------------------------------------------------- loop

local ctx = ImGui.CreateContext("Reapertoire naming")

local function frame()
  local visible, open = ImGui.Begin(ctx, "Reapertoire - name takes", true)
  if visible then
    local named = 0
    for _, r in ipairs(rows) do if r.song then named = named + 1 end end
    ImGui.Text(ctx, string.format("%d regions, %d named, %d to go",
      #rows, named, #rows - named))

    if status ~= "" then ImGui.Text(ctx, status) end
    ImGui.Separator(ctx)

    -- Keyboard: move between rows without leaving the filter box.
    if ImGui.IsKeyPressed(ctx, KEY.Key_DownArrow) then
      selected = math.min(#rows, selected + 1); query = ""
      if rows[selected] then seek_and_play(rows[selected]) end
    elseif ImGui.IsKeyPressed(ctx, KEY.Key_UpArrow) then
      selected = math.max(1, selected - 1); query = ""
      if rows[selected] then seek_and_play(rows[selected]) end
    end

    local row = rows[selected]
    if row then
      ImGui.Text(ctx, string.format("Take %d of %d   %s   %.0f s   %s",
        selected, #rows, mmss(row.start),
        row.stop - row.start, row.song or "(unnamed)"))

      if focus_filter then ImGui.SetKeyboardFocusHere(ctx); focus_filter = false end
      local changed, q = ImGui.InputText(ctx, "filter", query)
      if changed then query = q end

      local hits = songs_lib.filter(songs, query)

      -- Enter accepts the top match and moves to the next unnamed row, which is
      -- the whole point: type two letters, press Enter, repeat.
      if ImGui.IsKeyPressed(ctx, KEY.Key_Enter)
        or ImGui.IsKeyPressed(ctx, KEY.Key_KeypadEnter) then
        if hits[1] then
          row.song = hits[1].title
          naming.renumber(rows)
          query = ""
          local next_row = unnamed_after(selected + 1)
          if next_row then
            selected = next_row
            seek_and_play(rows[selected])
          end
          focus_filter = true
        end
      end

      for i, song in ipairs(hits) do
        if i > 8 then break end
        local marker = (i == 1) and "> " or "  "
        if ImGui.Selectable(ctx, marker .. song.title, i == 1) then
          row.song = song.title
          naming.renumber(rows)
          query = ""
        end
      end

      if query ~= "" and #hits == 0 then
        if ImGui.Button(ctx, 'Add "' .. query .. '" as a new song') then
          local added = songs_lib.add(songs, query)
          row.song = added.title
          naming.renumber(rows)
          query = ""
        end
      end

      local note_changed, note = ImGui.InputText(ctx, "note (blank = take number)",
        row.note or "")
      if note_changed then
        row.note = note ~= "" and note or nil
        naming.renumber(rows)
      end
    else
      ImGui.Text(ctx, "No regions in this project. Create some with the tuning panel.")
    end

    ImGui.Separator(ctx)

    if ImGui.Button(ctx, "Apply names to regions") then apply_names() end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Reload regions") then load_rows(); status = "Reloaded" end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Stop") then reaper.OnStopButton() end

    ImGui.Separator(ctx)

    if ImGui.BeginChild(ctx, "rows", 0, 0) then
      for i, r in ipairs(rows) do
        local marker = (i == selected) and ">" or " "
        local shown = naming.region_name(r) or "(unnamed)"
        if ImGui.Selectable(ctx, string.format("%s %2d  %9s  %6.0fs  %s",
          marker, i, mmss(r.start), r.stop - r.start, shown), i == selected) then
          selected = i
          query = ""
          seek_and_play(r)
        end
      end
      ImGui.EndChild(ctx)
    end

    ImGui.End(ctx)
  end

  if open then reaper.defer(frame) end
end

reaper.defer(frame)
