-- adapters/reaper_api.lua
-- The only file in this project permitted to touch the `reaper` global.
-- Everything under lib/ receives plain arrays so it can be tested on the CLI.

local frames_util = require("lib.util.frames")
local config = require("lib.config")
local peaks = require("lib.util.peaks")

local M = {}

function M.log(fmt, ...)
  reaper.ShowConsoleMsg(string.format(fmt .. "\n", ...))
end

function M.read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local contents = f:read("*a")
  f:close()
  return contents
end

function M.script_dir()
  local _, filename = reaper.get_action_context()
  return filename:match("^(.*)[/\\][^/\\]*$")
end

function M.time_selection()
  local start, stop = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  if stop <= start then return nil, nil end
  return start, stop
end

-- Fills `frames` for one take. Positions with no media are left untouched, so
-- the caller's `false` initialisation stands: a hard cut must never read as 0.
local function read_take_peaks(take, item_start, item_stop, sel_start, rate, frames)
  local source = reaper.GetMediaItemTake_Source(take)
  local channels = reaper.GetMediaSourceNumChannels(source)
  if channels < 1 then return end

  local n = math.max(1, frames_util.count(item_start, item_stop, rate))

  local buf = reaper.new_array(channels * n * 2)
  buf.clear()

  -- `starttime` is PROJECT time -- verified empirically, see
  -- docs/notes/reascript-findings.md. Not source time, so D_STARTOFFS is not
  -- added; D_PLAYRATE needs no compensation either, because a project-time
  -- read already reflects the take as placed on the timeline.
  --
  -- Reading outside this item's extent returns a full buffer of zeros with no
  -- error, indistinguishable from a silent room. That is why the caller clamps
  -- to item bounds and leaves every other frame `false`.
  local retval = reaper.GetMediaItemTake_Peaks(
    take, rate, item_start, channels, n, 0, buf)
  local returned = retval & 0xfffff
  if returned < 1 then return end

  local db = peaks.to_db(buf.table(), returned, channels)

  for f = 1, returned do
    local absolute_time = item_start + (f - 1) / rate
    local index = frames_util.index_of(absolute_time, sel_start, rate)
    if index >= 1 and index <= #frames then
      local existing = frames[index]
      if existing == false or db[f] > existing then frames[index] = db[f] end
    end
  end
end

-- Returns tracks (with dense frame arrays) and the flattened item extents.
function M.collect(sel_start, sel_stop, rate, track_rules)
  local n_frames = frames_util.count(sel_start, sel_stop, rate)
  local tracks, all_items = {}, {}

  for ti = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, ti)
    local _, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
    local rule = config.match_track(name, track_rules)

    local frames = {}
    for i = 1, n_frames do frames[i] = false end

    local items = {}
    for ii = 0, reaper.CountTrackMediaItems(track) - 1 do
      local item = reaper.GetTrackMediaItem(track, ii)
      local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      local item_start = math.max(pos, sel_start)
      local item_stop = math.min(pos + len, sel_stop)
      if item_stop > item_start then
        items[#items + 1] = { start = item_start, stop = item_stop }
        all_items[#all_items + 1] = { start = item_start, stop = item_stop }
        local take = reaper.GetActiveTake(item)
        if take and not reaper.TakeIsMIDI(take) then
          local playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
          if math.abs(playrate - 1.0) > 1e-6 then
            -- Project-time reads absorb playrate, so peak timing stays correct;
            -- flag it anyway, because a stretched item in a rehearsal recording
            -- is almost certainly an accident.
            M.log("NOTE: track '%s' item at %.2f has playrate %.3f.",
              name, pos, playrate)
          end
          read_take_peaks(take, item_start, item_stop, sel_start, rate, frames)
        end
      end
    end

    tracks[#tracks + 1] = {
      -- Carried so the renderer can select this track later; nothing under
      -- lib/ ever touches it.
      media_track = track,
      guid = reaper.GetTrackGUID(track),
      name = name,
      slug = rule and rule.slug or nil,
      is_mic = rule and rule.isMic or false,
      items = items,
      frames = frames,
    }
  end

  return tracks, all_items
end

return M
