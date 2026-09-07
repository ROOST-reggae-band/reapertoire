-- lib/peaks.lua
-- The waveform summary shipped alongside each take.
--
-- Cheap here, where the level data has already been read, and expensive in a
-- browser, which would have to download and decode the whole file to draw the
-- same picture. Retrofitting it later would mean re-running the entire back
-- catalogue, so it is written from the first render.
--
-- The values are magnitudes, mirrored: the frame data collected upstream has
-- already folded each frame's maximum and minimum into one peak, so the true
-- asymmetry of the waveform is not available to reproduce here. For a
-- thumbnail drawn a thousand pixels wide that distinction is invisible.

local M = {}

M.COUNT = 1000
M.MAX = 127

local function db_to_amplitude(db)
  if not db or db <= -140 then return 0 end
  return 10 ^ (db / 20)
end

-- tracks     array of { frames = { db|false } }
-- i0, i1     inclusive frame range covering the take
-- count      how many buckets to produce (default 1000)
--
-- Returns an array of integers in 0..127 -- the positive half. Callers wanting
-- the contract's -128..127 min/max pairs mirror them.
function M.envelope(tracks, i0, i1, count)
  count = count or M.COUNT
  local out = {}
  local span = i1 - i0 + 1
  if span < 1 then
    for i = 1, count do out[i] = 0 end
    return out
  end

  for bucket = 1, count do
    -- Buckets are derived from the range rather than stepped, so rounding
    -- cannot leave a gap or overrun the last frame.
    local from = i0 + math.floor((bucket - 1) * span / count)
    local to = i0 + math.floor(bucket * span / count) - 1
    if to < from then to = from end

    local loudest = 0
    for _, track in ipairs(tracks) do
      if track.live ~= false then
        for i = from, to do
          local v = track.frames[i]
          if v and v ~= false then
            local amp = db_to_amplitude(v)
            if amp > loudest then loudest = amp end
          end
        end
      end
    end

    local scaled = math.floor(loudest * M.MAX + 0.5)
    if scaled > M.MAX then scaled = M.MAX end
    out[bucket] = scaled
  end

  return out
end

-- The contract's shape: a single array of integers in -128..127, minimum and
-- maximum folded together.
function M.folded(tracks, i0, i1, count)
  local envelope = M.envelope(tracks, i0, i1, count)
  local out = {}
  for i, v in ipairs(envelope) do
    out[i] = (i % 2 == 1) and v or -v
  end
  return out
end

return M
