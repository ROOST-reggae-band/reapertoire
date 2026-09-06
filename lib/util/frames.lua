-- lib/util/frames.lua
-- Conversions between wall-clock seconds and 1-based frame indices in a dense
-- analysis array covering a time selection.

local M = {}

-- Frame index containing time t. 1-based, so sel_start itself is frame 1.
function M.index_of(t, sel_start, rate)
  return math.floor((t - sel_start) * rate + 1e-9) + 1
end

-- Start time of frame i.
function M.time_of(i, sel_start, rate)
  return sel_start + (i - 1) / rate
end

-- Number of frames needed to cover [sel_start, sel_stop], rounding up so a
-- partial final frame is still represented.
function M.count(sel_start, sel_stop, rate)
  return math.ceil((sel_stop - sel_start) * rate - 1e-9)
end

-- Inclusive frame range covering [span.start, span.stop), clamped into a dense
-- array of n_frames (pass nil for no upper clamp).
--
-- This is deliberately NOT index_of(span.stop): that is the frame which STARTS
-- at span.stop, and it belongs to the following span. Reading it lets one span
-- consume a frame of its successor's audio.
function M.range_of(span, sel_start, rate, n_frames)
  local i0 = math.max(1, M.index_of(span.start, sel_start, rate))
  local i1 = M.index_of(span.stop, sel_start, rate) - 1
  if n_frames then i1 = math.min(n_frames, i1) end
  return i0, i1
end

return M
