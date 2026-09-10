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
-- What to call a track in the manifest: its mapped slug, or its own name
-- where the mapping has none.
--
-- Nil when it has neither. An unnamed track in REAPER reports an empty name,
-- and `slug or name` then yields "" -- which travels all the way into the
-- manifest and is rejected by the ingest API as a blank instrument, after
-- earlier takes in the same run are already declared. A track nobody named
-- and nothing maps has nothing to be called.
local function name_of(track)
  local label = track.slug
  if label == nil or label == "" then label = track.name end
  if label == nil or label == "" then return nil end
  return label
end

-- Returns slugs (or track names where unmapped), in track order. A track with
-- neither is left out rather than reported as "".
function M.instruments_in(tracks, span, sel_start, rate, opts)
  local i0, i1 = frames_util.range_of(span, sel_start, rate)

  local out = {}
  for _, track in ipairs(tracks) do
    if track.live and track.programmed then
      -- No levels to threshold: a programmed part is present wherever one of
      -- its items covers the take. Strict overlap, so an item that ends
      -- exactly where the next take begins does not bleed into it.
      for _, item in ipairs(track.items or {}) do
        if item.start < span.stop and span.start < item.stop then
          local label = name_of(track)
          if label then out[#out + 1] = label end
          break
        end
      end
    elseif track.live then
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
        local label = name_of(track)
        if label then out[#out + 1] = label end
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
