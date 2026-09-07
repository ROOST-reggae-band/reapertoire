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
local ENUM = setmetatable({}, {
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

local rows = {}          -- every region in the project
local view = {}          -- the filtered subset actually shown
local selected = 1       -- indexes `view`, not `rows`
local limit_to_selection = true
local only_ours = false
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
      owned = r.owned,
      song = song,
      note = note,
    }
  end
  table.sort(rows, function(a, b) return a.start < b.start end)
end

load_rows()

-- A project holds many rehearsals, so the default is the regions inside the
-- current time selection. Without a selection the limit is inert rather than
-- hiding everything.
local function rebuild_view()
  local sel_start, sel_stop = adapter.time_selection()
  view = {}
  for _, row in ipairs(rows) do
    local in_selection = true
    if limit_to_selection and sel_start then
      in_selection = row.start < sel_stop and sel_start < row.stop
    end
    if in_selection and (not only_ours or row.owned) then
      view[#view + 1] = row
    end
  end
  if selected > #view then selected = #view end
  if selected < 1 then selected = 1 end

  -- Take numbers count within a session, not across the project. One project
  -- holds many rehearsals, so numbering over everything would give the same
  -- song a take number in the forties.
  naming.renumber(view)
end

local function unnamed_after(from)
  for i = from, #view do
    if not view[i].song then return i end
  end
  for i = 1, #view do
    if not view[i].song then return i end
  end
  return nil
end

local function seek_and_play(row)
  reaper.SetEditCurPos(row.start, true, true)
  local playing = reaper.GetPlayState() & 1 == 1
  if not playing then reaper.OnPlayButton() end
end

-- Clearing is explicit rather than implied by an absent song: a region the
-- tuner named "Take 3" and nobody has touched should keep that name, while one
-- the operator deliberately cleared should lose it.
local function clear_row(row)
  row.song = nil
  row.note = nil
  row.cleared = true
  naming.renumber(view)
end

local function apply_names()
  local written = 0
  for _, row in ipairs(view) do
    local name = naming.region_name(row)
    if row.cleared and not name then name = "" end
    if name and name ~= row.original then
      if regions.rename(row, name) then
        row.original = name
        row.cleared = nil
        written = written + 1
      end
    end
  end
  if written == 0 then
    status = "Nothing to write - no name differed from what the region already has"
  else
    status = string.format("Renamed %d region%s", written, written == 1 and "" or "s")
  end
end

load_rows()
rebuild_view()

local guids_ok = regions.guids_available()

-- ---------------------------------------------------------------------- loop

local ctx = ImGui.CreateContext("Reapertoire naming")

local function frame()
  -- FirstUseEver, so the size is a starting point and not re-imposed every
  -- frame; resizing the window has to stick.
  ImGui.SetNextWindowSize(ctx, 1000, 560, ENUM.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, "Reapertoire - name takes", true)
  if visible then
    rebuild_view()

    local named = 0
    for _, r in ipairs(view) do if r.song then named = named + 1 end end
    ImGui.Text(ctx, string.format("%d of %d regions shown - %d named, %d to go",
      #view, #rows, named, #view - named))

    local c1, v1 = ImGui.Checkbox(ctx, "limit to time selection", limit_to_selection)
    if c1 then limit_to_selection = v1; selected = 1 end
    ImGui.SameLine(ctx)
    local c2, v2 = ImGui.Checkbox(ctx, "only regions I created", only_ours)
    if c2 then only_ours = v2; selected = 1 end
    if not guids_ok then
      ImGui.Text(ctx,
        'This project does not answer region GUID lookups, so "only regions I '
        .. 'created" cannot tell them apart. Renaming is unaffected.')
    end

    if status ~= "" then ImGui.Text(ctx, status) end
    ImGui.Separator(ctx)

    -- Arrow keys move the selection wherever focus is, so the hands never have
    -- to leave the filter box.
    if ImGui.IsKeyPressed(ctx, ENUM.Key_DownArrow) then
      selected = math.min(#view, selected + 1); query = ""
      if view[selected] then seek_and_play(view[selected]) end
    elseif ImGui.IsKeyPressed(ctx, ENUM.Key_UpArrow) then
      selected = math.max(1, selected - 1); query = ""
      if view[selected] then seek_and_play(view[selected]) end
    end

    local row = view[selected]

    -- Left: the takes. Right: what to do with the selected one. Reserving the
    -- bottom strip keeps the action buttons on screen however long the list is.
    if ImGui.BeginChild(ctx, "takes", -360, -34) then
      for i, r in ipairs(view) do
        local marker = (i == selected) and ">" or " "
        local shown
        if r.song then
          shown = naming.region_name(r)
        elseif r.cleared then
          shown = "-- to be cleared --"
        elseif r.original and r.original ~= "" then
          -- A region carrying the tuner's "Take 3" placeholder has a name but
          -- no song. Show it, but never let it read as named.
          shown = "? " .. r.original
        else
          shown = "? (unnamed)"
        end
        if ImGui.Selectable(ctx, string.format("%s %2d  %9s  %5.0fs  %s",
          marker, i, mmss(r.start), r.stop - r.start, shown), i == selected) then
          selected = i
          query = ""
          seek_and_play(r)
        end
      end
      ImGui.EndChild(ctx)
    end

    ImGui.SameLine(ctx)

    if ImGui.BeginChild(ctx, "detail", 0, -34) then
      if row then
        ImGui.Text(ctx, string.format("Take %d of %d", selected, #view))
        ImGui.Text(ctx, string.format("%s   %.0f s", mmss(row.start), row.stop - row.start))
        ImGui.Text(ctx, row.song or "(no song yet)")
        ImGui.Separator(ctx)

        if focus_filter then ImGui.SetKeyboardFocusHere(ctx); focus_filter = false end
        local changed, q = ImGui.InputText(ctx, "filter", query)
        if changed then query = q end

        local hits = songs_lib.filter(songs, query)

        -- Enter accepts the top match and jumps to the next unnamed take: type
        -- two letters, press Enter, repeat.
        if ImGui.IsKeyPressed(ctx, ENUM.Key_Enter)
          or ImGui.IsKeyPressed(ctx, ENUM.Key_KeypadEnter) then
          if hits[1] then
            row.song = hits[1].title
            row.cleared = nil
            naming.renumber(view)
            query = ""
            local next_row = unnamed_after(selected + 1)
            if next_row then
              selected = next_row
              seek_and_play(view[selected])
            end
            focus_filter = true
          end
        end

        for i, song in ipairs(hits) do
          if i > 10 then break end
          local marker = (i == 1) and "> " or "  "
          if ImGui.Selectable(ctx, marker .. song.title, i == 1) then
            row.song = song.title
            row.cleared = nil
            naming.renumber(view)
            query = ""
          end
        end

        if query ~= "" and #hits == 0 then
          if ImGui.Button(ctx, 'Add "' .. query .. '" as a new song') then
            local added = songs_lib.add(songs, query)
            row.song = added.title
            row.cleared = nil
            naming.renumber(view)
            query = ""
          end
        end

        ImGui.Separator(ctx)

        local note_changed, note = ImGui.InputText(ctx, "note", row.note or "")
        if note_changed then
          row.note = note ~= "" and note or nil
          naming.renumber(view)
        end
        ImGui.Text(ctx, "blank = take number")

        if ImGui.Button(ctx, "Clear this name") then clear_row(row) end
        if row.cleared then ImGui.Text(ctx, "(will be cleared on Apply)") end
      elseif #rows == 0 then
        ImGui.Text(ctx, "No regions in this project.")
        ImGui.Text(ctx, "Create some with the tuning panel.")
      else
        ImGui.Text(ctx, "No regions match the current filters.")
      end
      ImGui.EndChild(ctx)
    end

    ImGui.Separator(ctx)

    if ImGui.Button(ctx, "Apply names to regions") then apply_names() end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Reload regions") then
      load_rows(); rebuild_view(); status = "Reloaded"
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Stop") then reaper.OnStopButton() end

    ImGui.End(ctx)
  end

  if open then reaper.defer(frame) end
end

reaper.defer(frame)
