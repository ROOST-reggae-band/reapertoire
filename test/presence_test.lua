-- test/presence_test.lua
local h = require("test.helpers")
local presence = require("lib.presence")

local T = {}

local RATE = 20
local OPTS = { live_margin_db = 12, presence_min_fraction = 0.05 }

local function frames_at(total, quiet, loud, loud_ranges)
  local out = {}
  for i = 1, total do out[i] = quiet end
  for _, r in ipairs(loud_ranges or {}) do
    for i = math.floor(r[1] * RATE) + 1, math.floor(r[2] * RATE) do
      out[i] = loud
    end
  end
  return out
end

function T.reports_only_tracks_playing_within_the_span()
  local tracks = {
    { name = "BASS DI", slug = "bass", live = true, floor_db = -60,
      frames = frames_at(200 * RATE, -60, -20, { { 0, 100 } }) },
    { name = "TRUMPET", slug = "trumpet", live = true, floor_db = -60,
      frames = frames_at(200 * RATE, -60, -20, { { 100, 200 } }) },
  }
  local first = presence.instruments_in(
    tracks, { start = 0, stop = 100 }, 0, RATE, OPTS)
  h.assert_eq(#first, 1)
  h.assert_eq(first[1], "bass")

  local second = presence.instruments_in(
    tracks, { start = 100, stop = 200 }, 0, RATE, OPTS)
  h.assert_eq(#second, 1)
  h.assert_eq(second[1], "trumpet")
end

function T.absent_tracks_are_never_reported()
  local tracks = {
    { name = "KEYS", slug = "keys", live = false, floor_db = -60,
      frames = frames_at(100 * RATE, -60, -20, { { 0, 100 } }) },
  }
  local got = presence.instruments_in(
    tracks, { start = 0, stop = 100 }, 0, RATE, OPTS)
  h.assert_eq(#got, 0)
end

function T.a_brief_stab_below_the_fraction_does_not_count()
  -- Two seconds of signal in a 100-second take is 2%, under the 5% floor.
  local tracks = {
    { name = "SAX", slug = "sax", live = true, floor_db = -60,
      frames = frames_at(100 * RATE, -60, -20, { { 0, 2 } }) },
  }
  local got = presence.instruments_in(
    tracks, { start = 0, stop = 100 }, 0, RATE, OPTS)
  h.assert_eq(#got, 0)
end

function T.track_name_is_used_when_no_slug_is_mapped()
  local tracks = {
    { name = "NEW MIC 4", slug = nil, live = true, floor_db = -60,
      frames = frames_at(100 * RATE, -60, -20, { { 0, 100 } }) },
  }
  local got = presence.instruments_in(
    tracks, { start = 0, stop = 100 }, 0, RATE, OPTS)
  h.assert_eq(got[1], "NEW MIC 4")
end

function T.frames_with_no_media_do_not_count_against_presence()
  -- A player whose item covers only the second half of the take is present,
  -- judged over the frames where they actually have media.
  local f = frames_at(100 * RATE, -20, -20, {})
  for i = 1, 50 * RATE do f[i] = false end
  local tracks = {
    { name = "GTR", slug = "gtr", live = true, floor_db = -60, frames = f },
  }
  local got = presence.instruments_in(
    tracks, { start = 0, stop = 100 }, 0, RATE, OPTS)
  h.assert_eq(got[1], "gtr")
end

function T.a_take_never_counts_the_next_takes_first_frame()
  -- Regression: index_of(span.stop) is the frame that STARTS at span.stop --
  -- the first frame of the NEXT take. Counting it credited a track with signal
  -- it never played in this take. The other tests miss this because each sizes
  -- its frames array to end at the take boundary, so the phantom index is out
  -- of bounds; a real analysis array spans the whole selection.
  -- presence_min_fraction = 0 makes a single leaked frame decisive.
  local frames = {}
  for i = 1, 200 do frames[i] = (i <= 20) and -60 or -20 end
  local tracks = {
    { name = "SAX", slug = "sax", live = true, floor_db = -60, frames = frames },
  }
  local got = presence.instruments_in(
    tracks, { start = 0, stop = 1.0 }, 0, RATE,
    { live_margin_db = 12, presence_min_fraction = 0 })
  h.assert_eq(#got, 0, "instrument credited from the next take's audio")
end

return T
