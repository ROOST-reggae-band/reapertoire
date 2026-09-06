-- lib/util/peaks.lua
-- Decodes the buffer GetMediaItemTake_Peaks fills into per-frame magnitude in
-- dB. Pure arithmetic, deliberately separated from the adapter so the one piece
-- of the REAPER integration that CAN be tested outside a DAW, is.
--
-- Layout, verified empirically (docs/notes/reascript-findings.md): with
-- want_extra_type = 0 the buffer holds two channel-interleaved blocks --
-- maximums first, then minimums, the second starting at returned * channels.

local M = {}

-- Amplitudes below this read as digital silence. A read outside an item's
-- media returns zeros with no error, so this is also what "no media" decodes
-- to -- which is exactly why the caller must not infer presence from it.
local SILENCE_DB = -140

function M.amplitude_to_db(amplitude)
  if amplitude < 1e-7 then return SILENCE_DB end
  return 20 * math.log(amplitude, 10)
end

-- buf       flat table from a reaper.array's :table()
-- returned  frame count, from retval & 0xfffff
-- channels  channels requested
-- Returns an array of `returned` dB values, one per frame, taking the largest
-- magnitude across channels and across the maximum and minimum blocks.
function M.to_db(buf, returned, channels)
  local out = {}
  for f = 1, returned do
    local peak = 0
    for ch = 1, channels do
      local hi = math.abs(buf[(f - 1) * channels + ch] or 0)
      local lo = math.abs(buf[returned * channels + (f - 1) * channels + ch] or 0)
      if hi > peak then peak = hi end
      if lo > peak then peak = lo end
    end
    out[f] = M.amplitude_to_db(peak)
  end
  return out
end

return M
