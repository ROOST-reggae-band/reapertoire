-- Decides which tracks carry a player this session.
--
-- The floor is computed per track from the track's own frames, not from a
-- fixed dBFS threshold: absolute thresholds break the moment the lineup or the
-- gain staging changes. Liveness is judged over the track's own media, not the
-- selection's wall-clock length, so one short item in a long selection counts
-- as live for that item rather than reading as 98% silence.

local M = {}

-- Nearest-rank percentile. Returns nil for an empty set. Does not mutate.
function M.percentile(values, p)
  if #values == 0 then return nil end
  local sorted = table.move(values, 1, #values, 1, {})
  table.sort(sorted)
  local rank = math.ceil(p / 100 * #sorted)
  if rank < 1 then rank = 1 end
  if rank > #sorted then rank = #sorted end
  return sorted[rank]
end

-- frames  dense array; each element is a dB number, or `false` where the track
--         has no media at that position. Never nil, never 0.
-- opts    { floor_percentile, live_margin_db, live_min_fraction }
-- track   optional { programmed, has_items } -- see below
function M.classify(frames, opts, track)
  local present = {}
  for _, v in ipairs(frames) do
    if v ~= false then present[#present + 1] = v end
  end

  -- A part played by a plugin from MIDI produces no audio until something
  -- renders it, so there is nothing to read at the item level and every frame
  -- is absent. Judged on frames alone such a track reads as dead and vanishes
  -- from every take -- which is how programmed drums went missing entirely.
  -- Having items IS the signal here: nobody writes MIDI into a track by
  -- accident. There is no floor and no active fraction, and none is invented:
  -- writing a stand-in dB would put a lie into the frame arrays that
  -- everything downstream trusts.
  if track and track.programmed and #present == 0 then
    return {
      live = track.has_items or false,
      floor_db = nil, active_fraction = 0, media_frames = 0,
    }
  end

  if #present == 0 then
    return { live = false, floor_db = nil, active_fraction = 0, media_frames = 0 }
  end

  local floor_db = M.percentile(present, opts.floor_percentile)
  local threshold = floor_db + opts.live_margin_db

  local active = 0
  for _, v in ipairs(present) do
    if v > threshold then active = active + 1 end
  end

  local fraction = active / #present
  return {
    live = fraction > opts.live_min_fraction,
    floor_db = floor_db,
    active_fraction = fraction,
    media_frames = #present,
  }
end

return M
