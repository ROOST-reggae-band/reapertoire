-- adapters/markers.lua
-- The point markers this tool owns: one pair per rehearsal, delimiting where
-- it sits on the timeline.
--
-- Markers rather than regions, deliberately. The region lane already carries
-- one region per take; a second kind interleaved among them makes the lane
-- unreadable, and every path that reads regions -- the naming panel offering
-- takes to name, the render collecting them -- would have to learn to ignore
-- them. A marker is invisible to all of it: `EnumProjectMarkers3` reports
-- `isrgn` false, and a marker is not a media item, so neither region reading
-- nor take detection can see one.
--
-- Ownership is tracked by position in project ExtState, not by name: a marker
-- carries no GUID the way a region does, and names are the one thing an
-- operator might edit.

local M = {}

local EXT_SECTION = "reapertoire"
local EXT_KEY = "session_marker_positions"

-- Positions are stored to the millisecond. Comparing floats for equality would
-- fail on a value that has been through a string and back, which is exactly
-- what ExtState does to it.
local function key_for(position)
  return string.format("%.3f", position)
end

local function load_owned()
  local _, csv = reaper.GetProjExtState(0, EXT_SECTION, EXT_KEY)
  local owned = {}
  if csv and csv ~= "" then
    for at in csv:gmatch("[^,]+") do owned[at] = true end
  end
  return owned
end

local function each_marker(fn)
  local i = 0
  while true do
    local retval, isrgn, pos, _, name, num = reaper.EnumProjectMarkers3(0, i)
    if retval == 0 then break end
    if not isrgn then fn(num, pos, name) end
    i = i + 1
  end
end

-- Removes the markers this tool placed, leaving the operator's own alone.
function M.clear(undo_label)
  local owned = load_owned()
  if next(owned) == nil then return 0 end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  -- Collected first, deleted after: deleting while enumerating shifts the
  -- indices underneath the enumeration.
  local doomed = {}
  each_marker(function(num, pos)
    if owned[key_for(pos)] then doomed[#doomed + 1] = num end
  end)
  for i = #doomed, 1, -1 do
    reaper.DeleteProjectMarker(0, doomed[i], false)
  end

  reaper.SetProjExtState(0, EXT_SECTION, EXT_KEY, "")
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock(undo_label or "Reapertoire: clear session markers", -1)
  return #doomed
end

-- Replaces this tool's markers with `markers`, an array of { at, name }.
--
-- Replace rather than add: running the action twice must leave the project
-- looking the same as running it once, the way re-rendering does.
function M.replace(markers, color, undo_label)
  M.clear(undo_label)

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local placed = {}
  for _, marker in ipairs(markers) do
    -- Index 0 lets REAPER assign the next free number rather than colliding
    -- with a marker the operator numbered themselves.
    reaper.AddProjectMarker2(0, false, marker.at, 0, marker.name, -1, color or 0)
    placed[#placed + 1] = key_for(marker.at)
  end

  reaper.SetProjExtState(0, EXT_SECTION, EXT_KEY, table.concat(placed, ","))
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock(undo_label or "Reapertoire: show session spans", -1)
  return #placed
end

return M
