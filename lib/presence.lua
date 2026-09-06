-- lib/presence.lua
-- Which live tracks actually carry signal inside a given take.
--
-- This is the `instruments` field the downstream contract wants: what was
-- played and captured on this take, which is deliberately not the same as
-- which stems exist. It varies within a session, so it is computed per take.

local frames_util = require("lib.util.frames")

local M = {}

-- tracks  array of { frames, floor_db, live, name, slug }
-- span    { start, stop }
-- opts    { live_margin_db, presence_min_fraction }
--
-- Returns slugs (or track names where unmapped), in track order.
function M.instruments_in(tracks, span, sel_start, rate, opts)
  local i0, i1 = frames_util.range_of(span, sel_start, rate)

  local out = {}
  for _, track in ipairs(tracks) do
    if track.live then
      local threshold = track.floor_db + opts.live_margin_db
      local total, active = 0, 0
      for i = i0, i1 do
        local v = track.frames[i]
        if v ~= false and v ~= nil then
          total = total + 1
          if v > threshold then active = active + 1 end
        end
      end
      if total > 0 and active / total > opts.presence_min_fraction then
        out[#out + 1] = track.slug or track.name
      end
    end
  end
  return out
end

return M
