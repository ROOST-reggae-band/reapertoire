-- tools/probe_peaks.lua
-- Run from REAPER's Actions list. Select ONE media item first.
-- Prints what GetMediaItemTake_Peaks actually does, so the adapter can be
-- written against observed behaviour rather than assumed behaviour.

local function log(fmt, ...)
  reaper.ShowConsoleMsg(string.format(fmt .. "\n", ...))
end

reaper.ClearConsole()
log("Lua version: %s", _VERSION)

local item = reaper.GetSelectedMediaItem(0, 0)
if not item then
  log("No item selected. Select one media item and run again.")
  return
end

local take = reaper.GetActiveTake(item)
local src = reaper.GetMediaItemTake_Source(take)
local channels = reaper.GetMediaSourceNumChannels(src)
local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
local offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
local rate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")

log("item pos=%.3f len=%.3f startoffs=%.3f playrate=%.3f channels=%d",
    pos, len, offs, rate, channels)

local n = 10
local peakrate = 20
local buf = reaper.new_array(channels * n * 2)
buf.clear()

local retval = reaper.GetMediaItemTake_Peaks(take, peakrate, offs, channels, n, 0, buf)
local returned = retval & 0xfffff
local out_mode = (retval & 0xf00000) >> 20
local has_extra = (retval & 0x1000000) ~= 0

log("retval=%d  samples=%d  out_mode=%d  extra=%s",
    retval, returned, out_mode, tostring(has_extra))

local t = buf.table()
local maxes, mins = {}, {}
for i = 1, returned * channels do
  maxes[#maxes + 1] = string.format("%.4f", t[i])
  mins[#mins + 1] = string.format("%.4f", t[returned * channels + i])
end
log("block 1 (expect maximums): %s", table.concat(maxes, " "))
log("block 2 (expect minimums): %s", table.concat(mins, " "))

log("")
log("Now compare against starttime=0 to learn the time base:")
local buf2 = reaper.new_array(channels * n * 2)
buf2.clear()
local r2 = reaper.GetMediaItemTake_Peaks(take, peakrate, 0, channels, n, 0, buf2)
local t2 = buf2.table()
local first2 = {}
for i = 1, (r2 & 0xfffff) * channels do
  first2[#first2 + 1] = string.format("%.4f", t2[i])
end
log("starttime=0 block 1: %s", table.concat(first2, " "))
log("If these differ from the startoffs run, starttime is SOURCE time.")
log("If identical and startoffs>0, starttime is ITEM-relative.")
