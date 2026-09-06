-- adapters/regions.lua
-- Creates and replaces the regions this tool owns, without ever touching one
-- the operator made themselves.
--
-- Ownership is tracked by GUID in project ExtState rather than by name or
-- position: names change when takes are named, and positions change on every
-- re-tune. A GUID survives both, and survives the project being saved and
-- reopened, so a second tuning session still knows which regions are its own.

local M = {}

local EXT_SECTION = "reapertoire"
local EXT_KEY = "region_guids"

-- Enumeration index differs from the user-visible region number, and the
-- delete and GUID calls want different ones, so both are collected here.
local function each_region(fn)
  local i = 0
  while true do
    local retval, isrgn, pos, rgnend, name, num = reaper.EnumProjectMarkers3(0, i)
    if retval == 0 then break end
    if isrgn then
      if fn(i, num, pos, rgnend, name) == false then return end
    end
    i = i + 1
  end
end

local function guid_at(enum_index)
  local ok, guid = reaper.GetSetProjectInfo_String(
    "MARKER_GUID:" .. enum_index, "", false)
  if ok and guid ~= "" then return guid end
  return nil
end

local function load_owned()
  local _, csv = reaper.GetProjExtState(0, EXT_SECTION, EXT_KEY)
  local owned = {}
  if csv and csv ~= "" then
    for guid in csv:gmatch("[^,]+") do owned[guid] = true end
  end
  return owned
end

local function save_owned(list)
  reaper.SetProjExtState(0, EXT_SECTION, EXT_KEY, table.concat(list, ","))
end

-- Removes every region this tool previously created. Returns how many went.
function M.clear(undo_label)
  local owned = load_owned()
  if next(owned) == nil then
    reaper.SetProjExtState(0, EXT_SECTION, EXT_KEY, "")
    return 0
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  -- Collect first, delete after: deleting while enumerating shifts the indices
  -- underneath the enumeration.
  local doomed = {}
  each_region(function(enum_index, num)
    local guid = guid_at(enum_index)
    if guid and owned[guid] then doomed[#doomed + 1] = num end
  end)

  for i = #doomed, 1, -1 do
    reaper.DeleteProjectMarker(0, doomed[i], true)
  end

  reaper.SetProjExtState(0, EXT_SECTION, EXT_KEY, "")
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock(undo_label or "Reapertoire: clear regions", -1)

  return #doomed
end

-- Replaces this tool's regions with one per take. `takes` are
-- { start, stop, instruments }; `name_of(take, index)` supplies each name.
-- Returns how many were created.
function M.replace(takes, name_of, color)
  M.clear("Reapertoire: replace regions")

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local guids = {}
  for i, take in ipairs(takes) do
    local num = reaper.AddProjectMarker2(
      0, true, take.start, take.stop, name_of(take, i), -1, color or 0)
    -- AddProjectMarker2 returns the user-visible number; the GUID lookup wants
    -- the enumeration index, so it has to be found by matching.
    each_region(function(enum_index, n)
      if n == num then
        local guid = guid_at(enum_index)
        if guid then guids[#guids + 1] = guid end
        return false
      end
    end)
  end

  save_owned(guids)

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Reapertoire: create regions", -1)

  return #guids, #takes
end

-- How many regions this tool currently believes it owns.
function M.owned_count()
  local n = 0
  for _ in pairs(load_owned()) do n = n + 1 end
  return n
end

return M
