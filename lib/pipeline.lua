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

  for _, track in ipairs(input.tracks) do
    assert(#track.frames == n_frames, string.format(
      "track %s has %d frames, expected %d -- a frame array must span the whole selection",
      track.name or "?", #track.frames, n_frames))
    local result = liveness.classify(track.frames, opts)
    track.live = result.live
    track.floor_db = result.floor_db
    track.active_fraction = result.active_fraction
    track.media_frames = result.media_frames
  end

  local covered_spans = timeline.covered_spans(
    input.items, sel_start, sel_stop, opts.merge_gap_sec)

  local activity = detect.activity(input.tracks, opts, n_frames)
  local takes = detect.takes(activity, covered_spans, sel_start, rate, opts)

  for _, take in ipairs(takes) do
    take.instruments = presence.instruments_in(
      input.tracks, take, sel_start, rate, opts)
  end

  return {
    tracks = input.tracks,
    covered_spans = covered_spans,
    takes = takes,
    n_frames = n_frames,
  }
end

return M
