local h = require("test.helpers")
local liveness = require("lib.liveness")

local T = {}

local OPTS = {
  floor_percentile = 10,
  live_margin_db = 12,
  live_min_fraction = 0.02,
}

-- Builds a dense frame array: `n` frames at `quiet` dB, with `loud_count`
-- frames raised to `loud` dB, optionally surrounded by `false` (no media).
local function make_frames(opts)
  local out = {}
  for _ = 1, (opts.leading_absent or 0) do out[#out + 1] = false end
  for i = 1, opts.n do
    out[#out + 1] = (i <= (opts.loud_count or 0)) and opts.loud or opts.quiet
  end
  for _ = 1, (opts.trailing_absent or 0) do out[#out + 1] = false end
  return out
end

function T.percentile_uses_nearest_rank()
  local v = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }
  h.assert_eq(liveness.percentile(v, 10), 1)
  h.assert_eq(liveness.percentile(v, 50), 5)
  h.assert_eq(liveness.percentile(v, 100), 10)
end

function T.percentile_of_empty_is_nil()
  h.assert_eq(liveness.percentile({}, 10), nil)
end

function T.percentile_does_not_mutate_its_input()
  local v = { 3, 1, 2 }
  liveness.percentile(v, 50)
  h.assert_eq(v[1], 3, "input reordered")
end

function T.silent_track_is_not_live()
  local r = liveness.classify(
    make_frames({ n = 1000, quiet = -60 }), OPTS)
  h.assert_eq(r.live, false)
end

function T.playing_track_is_live()
  local r = liveness.classify(
    make_frames({ n = 1000, quiet = -60, loud = -12, loud_count = 400 }), OPTS)
  h.assert_eq(r.live, true)
  h.assert_near(r.active_fraction, 0.4, 1e-9)
end

function T.room_bleed_alone_is_not_live()
  -- An absent player's mic picks up the room: above the floor, but only just,
  -- and never by the 12 dB margin.
  local r = liveness.classify(
    make_frames({ n = 1000, quiet = -60, loud = -55, loud_count = 900 }), OPTS)
  h.assert_eq(r.live, false)
end

function T.track_with_no_media_at_all_is_not_live()
  local r = liveness.classify({ false, false, false }, OPTS)
  h.assert_eq(r.live, false)
  h.assert_eq(r.media_frames, 0)
  h.assert_eq(r.floor_db, nil)
end

function T.liveness_is_judged_over_own_media_not_selection_length()
  -- One 30-second item inside an hour-long selection, played through with the
  -- normal rests any real part contains. Judged over the selection it would
  -- look 99% silent; judged over its own media it is unambiguously live.
  local r = liveness.classify(make_frames({
    leading_absent = 60000,
    n = 600, quiet = -60, loud = -10, loud_count = 500,
    trailing_absent = 11400,
  }), OPTS)
  h.assert_eq(r.live, true)
  h.assert_eq(r.media_frames, 600)
  h.assert_near(r.active_fraction, 500 / 600, 1e-9)
end

function T.a_track_that_never_rests_has_no_measurable_floor()
  -- Pinned deliberately: a self-referential floor needs the track to be quiet
  -- sometimes. A part with literally no rests has a floor equal to its own
  -- signal level and classifies as absent. Real parts always contain rests, so
  -- this does not bite in practice — but it is why the dry-run report prints
  -- the measured floor per track, where a floor of -10 dB is visibly wrong.
  local frames = {}
  for i = 1, 1000 do frames[i] = -10 end
  local r = liveness.classify(frames, OPTS)
  h.assert_eq(r.live, false)
  h.assert_near(r.floor_db, -10, 1e-9)
end

function T.absent_frames_never_reach_the_floor_calculation()
  -- If `false` were treated as 0 dB, the floor would be dragged far upward and
  -- the real signal would fall below the margin.
  local r = liveness.classify(make_frames({
    leading_absent = 9000,
    n = 1000, quiet = -60, loud = -12, loud_count = 400,
  }), OPTS)
  h.assert_near(r.floor_db, -60, 1e-9)
  h.assert_eq(r.live, true)
end

return T
