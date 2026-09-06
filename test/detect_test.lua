local h = require("test.helpers")
local detect = require("lib.detect")

local T = {}

local RATE = 20

local OPTS = {
  mic_weight = 0.35,
  gap_threshold_db = 6,
  min_gap_sec = 4.0,
  min_take_sec = 30.0,
  pad_sec = 0.5,
}

-- Builds a dense frame array of `total` frames at `quiet` dB, with the given
-- second-ranges raised to `loud` dB.
local function track_frames(total, quiet, loud, loud_ranges)
  local out = {}
  for i = 1, total do out[i] = quiet end
  for _, r in ipairs(loud_ranges or {}) do
    for i = math.floor(r[1] * RATE) + 1, math.floor(r[2] * RATE) do
      out[i] = loud
    end
  end
  return out
end

function T.activity_is_db_above_the_tracks_own_floor()
  local tracks = {
    { frames = { -30, -60 }, floor_db = -60, live = true, is_mic = false },
  }
  local a = detect.activity(tracks, OPTS, 2)
  h.assert_near(a[1], 30)
  h.assert_near(a[2], 0)
end

function T.activity_takes_the_max_across_live_tracks()
  -- One instrument playing is enough; the detector must not need the whole band.
  local tracks = {
    { frames = { -58 }, floor_db = -60, live = true, is_mic = false },
    { frames = { -20 }, floor_db = -60, live = true, is_mic = false },
  }
  h.assert_near(detect.activity(tracks, OPTS, 1)[1], 40)
end

function T.absent_tracks_are_ignored_entirely()
  local tracks = {
    { frames = { -10 }, floor_db = -60, live = false, is_mic = false },
    { frames = { -55 }, floor_db = -60, live = true,  is_mic = false },
  }
  h.assert_near(detect.activity(tracks, OPTS, 1)[1], 5)
end

function T.mic_tracks_are_weighted_down()
  -- Talking between takes is loudest exactly where silence is wanted.
  local tracks = {
    { frames = { -20 }, floor_db = -60, live = true, is_mic = true },
  }
  h.assert_near(detect.activity(tracks, OPTS, 1)[1], 40 * 0.35)
end

function T.frames_with_no_media_on_any_live_track_are_false()
  local tracks = {
    { frames = { false, -20 }, floor_db = -60, live = true, is_mic = false },
  }
  local a = detect.activity(tracks, OPTS, 2)
  h.assert_eq(a[1], false)
  h.assert_near(a[2], 40)
end

function T.two_takes_separated_by_a_long_gap()
  -- 60 s take, 10 s of silence, 60 s take.
  local total = 130 * RATE
  local tracks = { {
    frames = track_frames(total, -60, -20, { { 0, 60 }, { 70, 130 } }),
    floor_db = -60, live = true, is_mic = false,
  } }
  local activity = detect.activity(tracks, OPTS, total)
  local takes = detect.takes(activity, { { start = 0, stop = 130 } }, 0, RATE, OPTS)
  h.assert_eq(#takes, 2, "take count")
  h.assert_near(takes[1].start, 0, 0.1)
  h.assert_near(takes[1].stop, 60.5, 0.1)
  h.assert_near(takes[2].start, 69.5, 0.1)
  h.assert_near(takes[2].stop, 130, 0.1)
end

function T.a_short_gap_does_not_split_a_take()
  -- 2 s of silence mid-song is a breakdown, not a take boundary.
  local total = 130 * RATE
  local tracks = { {
    frames = track_frames(total, -60, -20, { { 0, 60 }, { 62, 130 } }),
    floor_db = -60, live = true, is_mic = false,
  } }
  local activity = detect.activity(tracks, OPTS, total)
  local takes = detect.takes(activity, { { start = 0, stop = 130 } }, 0, RATE, OPTS)
  h.assert_eq(#takes, 1, "take count")
end

function T.noodling_shorter_than_min_take_is_discarded()
  -- 10 s of tuning, long gap, then a real 60 s take.
  local total = 130 * RATE
  local tracks = { {
    frames = track_frames(total, -60, -20, { { 0, 10 }, { 60, 125 } }),
    floor_db = -60, live = true, is_mic = false,
  } }
  local activity = detect.activity(tracks, OPTS, total)
  local takes = detect.takes(activity, { { start = 0, stop = 130 } }, 0, RATE, OPTS)
  h.assert_eq(#takes, 1, "take count")
  h.assert_near(takes[1].start, 59.5, 0.2)
end

function T.a_take_never_spans_a_hard_cut()
  -- Continuous audio across what the timeline says is a stop/start. Detection
  -- must obey the item boundary regardless of what the amplitude says.
  local total = 130 * RATE
  local tracks = { {
    frames = track_frames(total, -60, -20, { { 0, 130 } }),
    floor_db = -60, live = true, is_mic = false,
  } }
  local activity = detect.activity(tracks, OPTS, total)
  local spans = { { start = 0, stop = 60 }, { start = 60, stop = 130 } }
  local takes = detect.takes(activity, spans, 0, RATE, OPTS)
  h.assert_eq(#takes, 2, "take count")
  h.assert_eq(takes[1].span_index, 1)
  h.assert_eq(takes[2].span_index, 2)
end

function T.a_span_never_borrows_the_next_spans_first_frame()
  -- Regression: index_of(span.stop) is the frame that STARTS at span.stop --
  -- the first frame of the NEXT span. Walking it inside this span let a phantom
  -- take be attributed to span 1 from audio belonging to span 2. Setting
  -- min_take_sec and pad_sec to 0 strips the two mechanisms (the padding clamp
  -- and the short-take filter) that otherwise mask the leak.
  local total = 130 * RATE
  local tracks = { {
    frames = track_frames(total, -60, -20, { { 0, 50 }, { 60, 130 } }),
    floor_db = -60, live = true, is_mic = false,
  } }
  local activity = detect.activity(tracks, OPTS, total)
  local spans = { { start = 0, stop = 60 }, { start = 60, stop = 130 } }
  local takes = detect.takes(activity, spans, 0, RATE, {
    gap_threshold_db = 6, min_gap_sec = 4.0, min_take_sec = 0, pad_sec = 0,
  })
  h.assert_eq(#takes, 2, "take count")
  h.assert_near(takes[1].stop, 50, 0.1)
  h.assert_eq(takes[2].span_index, 2)
  h.assert_near(takes[2].start, 60, 0.1)
end

function T.padding_is_clamped_to_the_covered_span()
  -- A take filling its span must not be padded past the item edge.
  local total = 60 * RATE
  local tracks = { {
    frames = track_frames(total, -60, -20, { { 0, 60 } }),
    floor_db = -60, live = true, is_mic = false,
  } }
  local activity = detect.activity(tracks, OPTS, total)
  local takes = detect.takes(activity, { { start = 0, stop = 60 } }, 0, RATE, OPTS)
  h.assert_eq(#takes, 1, "take count")
  h.assert_near(takes[1].start, 0, 1e-9)
  h.assert_near(takes[1].stop, 60, 1e-9)
end

function T.an_empty_span_yields_no_takes()
  local total = 60 * RATE
  local tracks = { {
    frames = track_frames(total, -60, -20, {}),
    floor_db = -60, live = true, is_mic = false,
  } }
  local activity = detect.activity(tracks, OPTS, total)
  local takes = detect.takes(activity, { { start = 0, stop = 60 } }, 0, RATE, OPTS)
  h.assert_eq(#takes, 0)
end

function T.span_index_is_reported_for_every_take()
  local total = 200 * RATE
  local tracks = { {
    frames = track_frames(total, -60, -20, { { 0, 60 }, { 100, 190 } }),
    floor_db = -60, live = true, is_mic = false,
  } }
  local activity = detect.activity(tracks, OPTS, total)
  local spans = { { start = 0, stop = 60 }, { start = 100, stop = 200 } }
  local takes = detect.takes(activity, spans, 0, RATE, OPTS)
  h.assert_eq(#takes, 2)
  h.assert_eq(takes[1].span_index, 1)
  h.assert_eq(takes[2].span_index, 2)
end

return T
