-- lib/pipeline.lua
-- Composes the five analysis stages into one call.
--
-- Three consumers need this exact sequence: the REAPER action script, the
-- fixture-driven tuning tests, and any future entry point. Composing it
-- separately in each would leave two of the three runnable only inside a DAW,
-- and would hand-map the camelCase config keys onto snake_case option tables
-- three times over -- where a typo yields nil rather than an error.

local frames_util = require("lib.util.frames")
local timeline = require("lib.timeline")
local liveness = require("lib.liveness")
local detect = require("lib.detect")
local presence = require("lib.presence")

local M = {}

-- Config is hand-edited JSON and uses camelCase; lib/ uses snake_case. This is
-- the single translation between the two vocabularies.
function M.detection_opts(d)
  return {
    frame_rate_hz = d.frameRateHz,
    floor_percentile = d.floorPercentile,
    live_margin_db = d.liveMarginDb,
    live_min_fraction = d.liveMinFraction,
    mic_weight = d.micWeight,
    gap_threshold_db = d.gapThresholdDb,
    min_gap_sec = d.minGapSec,
    min_take_sec = d.minTakeSec,
    pad_sec = d.padSec,
    presence_min_fraction = d.presenceMinFraction,
    merge_gap_sec = d.mergeGapSec,
    snap_to_measure = d.snapToMeasure,
  }
end

-- input = { tracks, items, sel_start, sel_stop, detection }
function M.analyze(input)
  local opts = M.detection_opts(input.detection)
  local rate = opts.frame_rate_hz
  local sel_start, sel_stop = input.sel_start, input.sel_stop
  local n_frames = frames_util.count(sel_start, sel_stop, rate)

  -- Classified tracks are shallow copies, so a caller's own list is never
  -- modified behind its back and a mid-loop assertion cannot leave it half
  -- mutated. The frames array is shared by reference: it is large and every
  -- downstream stage only reads it.
  local tracks = {}
  for i, track in ipairs(input.tracks) do
    assert(#track.frames == n_frames, string.format(
      "track %s has %d frames, expected %d -- a frame array must span the whole selection",
      track.name or "?", #track.frames, n_frames))
    local result = liveness.classify(track.frames, opts)
    local copy = {}
    for k, v in pairs(track) do copy[k] = v end
    copy.live = result.live
    copy.floor_db = result.floor_db
    copy.active_fraction = result.active_fraction
    copy.media_frames = result.media_frames
    tracks[i] = copy
  end

  local covered_spans = timeline.covered_spans(
    input.items, sel_start, sel_stop, opts.merge_gap_sec)

  local activity = detect.activity(tracks, opts, n_frames)
  local takes = detect.takes(activity, covered_spans, sel_start, rate, opts)

  for _, take in ipairs(takes) do
    take.instruments = presence.instruments_in(
      tracks, take, sel_start, rate, opts)
  end

  return {
    tracks = tracks,
    covered_spans = covered_spans,
    takes = takes,
    n_frames = n_frames,
  }
end

return M
