local h = require("test.helpers")
local peaks = require("lib.peaks")

local T = {}

local function track(frames, live)
  return { frames = frames, live = live }
end

local function constant(n, db)
  local f = {} for i = 1, n do f[i] = db end return f
end

function T.produces_the_requested_number_of_buckets()
  local t = { track(constant(500, -20)) }
  h.assert_eq(#peaks.envelope({ t[1] }, 1, 500, 1000), 1000)
  h.assert_eq(#peaks.envelope({ t[1] }, 1, 500, 10), 10)
end

function T.full_scale_reads_as_the_maximum()
  local t = track(constant(100, 0))
  local e = peaks.envelope({ t }, 1, 100, 10)
  h.assert_eq(e[1], 127)
end

function T.silence_reads_as_zero()
  local t = track(constant(100, -140))
  local e = peaks.envelope({ t }, 1, 100, 10)
  h.assert_eq(e[1], 0)
end

function T.minus_six_db_is_about_half_scale()
  local t = track(constant(100, -6.02))
  local e = peaks.envelope({ t }, 1, 100, 10)
  h.assert_near(e[1], 64, 1)
end

function T.the_loudest_track_in_a_bucket_wins()
  local quiet = track(constant(100, -40))
  local loud = track(constant(100, 0))
  local e = peaks.envelope({ quiet, loud }, 1, 100, 4)
  h.assert_eq(e[1], 127)
end

function T.absent_frames_do_not_count_as_silence_from_other_tracks()
  local a = track({ false, false, 0, 0 })
  local e = peaks.envelope({ a }, 1, 4, 2)
  h.assert_eq(e[1], 0, "no media reads as nothing")
  h.assert_eq(e[2], 127, "media reads at its level")
end

function T.tracks_marked_not_live_are_excluded()
  local absent = track(constant(100, 0), false)
  local e = peaks.envelope({ absent }, 1, 100, 4)
  h.assert_eq(e[1], 0)
end

function T.buckets_cover_the_range_without_gaps_or_overrun()
  -- A loud frame anywhere in the range must appear in exactly one bucket, and
  -- the last frame must not be dropped by rounding.
  local frames = constant(1000, -140)
  frames[1000] = 0
  local e = peaks.envelope({ track(frames) }, 1, 1000, 100)
  h.assert_eq(e[100], 127, "the final frame lands in the final bucket")
  local loud = 0
  for _, v in ipairs(e) do if v > 0 then loud = loud + 1 end end
  h.assert_eq(loud, 1, "and nowhere else")
end

function T.more_buckets_than_frames_still_produces_the_full_array()
  local e = peaks.envelope({ track(constant(3, 0)) }, 1, 3, 1000)
  h.assert_eq(#e, 1000)
  h.assert_eq(e[1], 127)
  h.assert_eq(e[1000], 127)
end

function T.an_empty_range_is_all_zeroes_rather_than_an_error()
  local e = peaks.envelope({ track(constant(10, 0)) }, 5, 4, 8)
  h.assert_eq(#e, 8)
  h.assert_eq(e[1], 0)
end

function T.folded_output_alternates_sign_within_the_contract_range()
  local t = track(constant(100, 0))
  local f = peaks.folded({ t }, 1, 100, 4)
  h.assert_eq(f[1], 127)
  h.assert_eq(f[2], -127)
  for _, v in ipairs(f) do
    assert(v >= -128 and v <= 127, "out of range: " .. v)
  end
end

return T
