-- tools/probe_peaks.lua
-- Determines the time base of GetMediaItemTake_Peaks's `starttime` argument and
-- confirms the returned buffer layout. The ReaScript documentation states
-- neither, and the REAPER adapter depends on both.
--
-- Run from REAPER's action list with ONE audio item selected. Reads only;
-- changes nothing in the project.

local function log(fmt, ...)
  reaper.ShowConsoleMsg(string.format(fmt .. "\n", ...))
end

reaper.ClearConsole()
log("Lua version: %s", _VERSION)

local item = reaper.GetSelectedMediaItem(0, 0)
if not item then
  log("No item selected. Select one audio item and run again.")
  return
end

local take = reaper.GetActiveTake(item)
if not take then
  log("Item has no active take.")
  return
end
if reaper.TakeIsMIDI(take) then
  log("Active take is MIDI. Select an audio item instead.")
  return
end

local source = reaper.GetMediaItemTake_Source(take)
local channels = reaper.GetMediaSourceNumChannels(source)
local src_len = reaper.GetMediaSourceLength(source)
local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
local offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
local playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")

log("item pos=%.3f len=%.3f startoffs=%.3f playrate=%.3f channels=%d source_len=%.3f",
  pos, len, offs, playrate, channels, src_len)

local PEAKRATE = 20
local N = 40 -- two seconds at 20 Hz

-- Returns: frames returned, count of non-silent values, largest magnitude,
-- the raw retval, and the decoded buffer.
local function read_at(starttime)
  local buf = reaper.new_array(channels * N * 2)
  buf.clear()
  local retval = reaper.GetMediaItemTake_Peaks(
    take, PEAKRATE, starttime, channels, N, 0, buf)
  local returned = retval & 0xfffff
  local t = buf.table()
  local nonzero, largest = 0, 0
  for f = 1, returned do
    for ch = 1, channels do
      local hi = math.abs(t[(f - 1) * channels + ch] or 0)
      local lo = math.abs(t[returned * channels + (f - 1) * channels + ch] or 0)
      local v = math.max(hi, lo)
      if v > 1e-6 then nonzero = nonzero + 1 end
      if v > largest then largest = v end
    end
  end
  return returned, nonzero, largest, retval, t
end

-- Probe the item's MIDPOINT. A recording's first half-second is very often
-- genuine silence, which is exactly what made the first probe inconclusive.
local mid = len * 0.5

log("")
log("Reading %d frames at %d Hz from the item's midpoint (%.3f s in),", N, PEAKRATE, mid)
log("under each candidate interpretation of `starttime`:")
log("")

local candidates = {
  { name = "SOURCE time    (startoffs + mid)", t = offs + mid },
  { name = "ITEM-relative  (mid)            ", t = mid },
  { name = "PROJECT time   (item pos + mid) ", t = pos + mid },
}

local winner
for _, c in ipairs(candidates) do
  local returned, nonzero, largest, retval = read_at(c.t)
  log("  %s  starttime=%11.3f  returned=%3d  non-silent=%3d  peak=%.5f  retval=0x%X",
    c.name, c.t, returned, nonzero, largest, retval)
  if nonzero > 0 and (winner == nil or nonzero > winner.nonzero) then
    winner = { name = c.name, t = c.t, nonzero = nonzero }
  end
end

log("")

if not winner then
  log("=> INCONCLUSIVE: all three read silence.")
  log("   Either this item really is silent at its midpoint, or its peak cache")
  log("   has not been built. Try an item you can clearly hear, or select it and")
  log("   run Item processing > Build peak cache, then run this again.")
  return
end

log("=> `starttime` is %s", (winner.name:gsub("%s+$", "")))
log("")

-- With the time base settled, confirm the buffer layout at that same position.
local returned, _, _, _, t = read_at(winner.t)
log("Buffer layout check at that position (first 8 frames, channel 1):")
log("  %-8s %-10s %-10s", "frame", "block 1", "block 2")
local inverted = 0
for f = 1, math.min(8, returned) do
  local a = t[(f - 1) * channels + 1] or 0
  local b = t[returned * channels + (f - 1) * channels + 1] or 0
  log("  %-8d %-10.5f %-10.5f", f, a, b)
  if b > a then inverted = inverted + 1 end
end
log("")
if inverted == 0 then
  log("=> Block 1 is never below block 2: maximums first, then minimums, as documented.")
else
  log("=> WARNING: block 2 exceeded block 1 in %d of the sampled frames.", inverted)
  log("   The documented maximums-then-minimums layout may not hold here.")
end

log("")
log("Sample-count behaviour: requested %d, returned %d.", N, returned)
if returned < N then
  log("   Fewer than requested -- the read ran past the end of available media.")
end
