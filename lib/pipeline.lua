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
    min_level_db = d.minLevelDb,
    ensemble_ratio = d.ensembleRatio,
    min_ensemble = d.minEnsemble,
    snap_to_measure = d.snapToMeasure,
  }
end

-- input = { tracks, items, sel_start, sel_stop, detection }
--
-- Split into two halves on purpose. `classify` sorts every track's frames to
-- find its noise floor, which is the expensive part; `detect` only walks them.
-- An interactive tuner classifies once and re-runs detect on every slider move,
-- so the split is what makes live feedback possible.

-- Returns { tracks = <classified copies>, n_frames }. Tracks gain live,
-- floor_db, active_fraction and media_frames.
function M.classify(input)
  local opts = M.detection_opts(input.detection)
  local n_frames = frames_util.count(input.sel_start, input.sel_stop, opts.frame_rate_hz)

  -- Classified tracks are shallow copies, so a caller's own list is never
  -- modified behind its back and a mid-loop assertion cannot leave it half
  -- mutated. The frames array is shared by reference: it is large and every
  -- downstream stage only reads it.
  local tracks = {}
  for i, track in ipairs(input.tracks) do
    assert(#track.frames == n_frames, string.format(
      "track %s has %d frames, expected %d -- a frame array must span the whole selection",
      track.name or "?", #track.frames, n_frames))
    -- `programmed` and the item list travel with the track from the adapter:
    -- a MIDI-driven part has no frames to judge, so liveness falls back to
    -- whether it has items at all.
    local result = liveness.classify(track.frames, opts, {
      programmed = track.programmed,
      has_items = track.items ~= nil and #track.items > 0,
    })
    local copy = {}
    for k, v in pairs(track) do copy[k] = v end
    copy.live = result.live
    copy.floor_db = result.floor_db
    copy.active_fraction = result.active_fraction
    copy.media_frames = result.media_frames
    tracks[i] = copy
  end

  return { tracks = tracks, n_frames = n_frames }
end

-- Cheap half: spans, takes and per-take instruments, from an already
-- classified set. Safe to call repeatedly with different detection options.
function M.detect(classified, input)
  local opts = M.detection_opts(input.detection)
  local rate = opts.frame_rate_hz

  -- Noise floors were measured at a particular frame rate; changing it would
  -- silently invalidate them and the cached frame arrays with them.
  assert(frames_util.count(input.sel_start, input.sel_stop, rate) == classified.n_frames,
    "frameRateHz changed since classify -- re-run classify before detect")

  local covered_spans = timeline.covered_spans(
    input.items, input.sel_start, input.sel_stop, opts.merge_gap_sec)

  local activity = detect.activity(classified.tracks, opts, classified.n_frames)
  local takes = detect.takes(activity, covered_spans, input.sel_start, rate, opts)

  -- Ensemble density is attached to every take, then used to filter only if a
  -- minimum is set. Reporting it even when unused is the point: it is the
  -- number the operator is deciding about.
  local kept = {}
  for _, take in ipairs(takes) do
    take.instruments = presence.instruments_in(
      classified.tracks, take, input.sel_start, rate, opts)
    take.ensemble = presence.ensemble(
      classified.tracks, take, input.sel_start, rate, opts)
    if take.ensemble >= (opts.min_ensemble or 0) then
      kept[#kept + 1] = take
    end
  end

  return { covered_spans = covered_spans, takes = kept }
end

-- The whole pipeline, for callers that run it once.
function M.analyze(input)
  local classified = M.classify(input)
  local detected = M.detect(classified, input)
  return {
    tracks = classified.tracks,
    covered_spans = detected.covered_spans,
    takes = detected.takes,
    n_frames = classified.n_frames,
  }
end

return M
