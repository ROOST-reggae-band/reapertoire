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
          local gated = opts.min_level_db and v < opts.min_level_db
        if v > threshold and not gated then active = active + 1 end
        end
      end
      if total > 0 and active / total > opts.presence_min_fraction then
        out[#out + 1] = track.slug or track.name
      end
    end
  end
  return out
end

-- What fraction of a take has most of the band playing at once.
--
-- This is the one measure that separates a run-through from one player working
-- their part: both are sustained playing at full level, so neither level nor
-- duration can tell them apart, but the number of people playing differs.
--
-- The count required is a RATIO of the live lineup, never a fixed number: with
-- six live tracks "most of the band" is three or four, with a drummer's twenty
-- mics live it is something else entirely.
function M.ensemble(tracks, span, sel_start, rate, opts)
  local frames_util_local = require("lib.util.frames")
  local i0, i1 = frames_util_local.range_of(span, sel_start, rate)

  local live = {}
  for _, track in ipairs(tracks) do
    if track.live then live[#live + 1] = track end
  end
  if #live == 0 then return 0 end

  local needed = math.max(1, math.ceil(#live * (opts.ensemble_ratio or 0.5)))
  local dense, total = 0, 0

  for i = i0, i1 do
    local playing = 0
    for _, track in ipairs(live) do
      local v = track.frames[i]
      if v ~= false and v ~= nil and v > track.floor_db + opts.live_margin_db then
        if not (opts.min_level_db and v < opts.min_level_db) then
          playing = playing + 1
        end
      end
    end
    if playing >= needed then dense = dense + 1 end
    total = total + 1
  end

  if total == 0 then return 0 end
  return dense / total
end

return M
