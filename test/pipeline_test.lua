local h = require("test.helpers")
local pipeline = require("lib.pipeline")
local config = require("lib.config")

local T = {}
local RATE = 20

local function frames_of(total, quiet, loud, loud_ranges, absent_ranges)
  local f = {}
  for i = 1, total do f[i] = quiet end
  for _, r in ipairs(loud_ranges or {}) do
    for i = math.floor(r[1]*RATE)+1, math.floor(r[2]*RATE) do f[i] = loud end
  end
  for _, r in ipairs(absent_ranges or {}) do
    for i = math.floor(r[1]*RATE)+1, math.floor(r[2]*RATE) do f[i] = false end
  end
  return f
end

function T.every_detection_config_key_maps_to_its_snake_case_option()
  -- Counting keys is not enough. Two mappings whose source fields are swapped
  -- keep the count equal and both values non-nil, so swapping liveMarginDb and
  -- liveMinFraction would pass unnoticed -- and would give every track a
  -- 0.02 dB threshold plus an impossible 12.0 activity requirement, silently
  -- classifying the whole band as absent. Derive the expected name and compare
  -- values instead.
  --
  -- Residual gap, accepted: a swap between two keys that share a default value
  -- (presenceMinFraction and mergeGapSec are both 0.05) still passes.
  local function snake(s)
    return (s:gsub("(%u)", function(c) return "_" .. c:lower() end))
  end
  local d = config.defaults().detection
  local opts = pipeline.detection_opts(d)
  local declared = 0
  for k, v in pairs(d) do
    declared = declared + 1
    local name = snake(k)
    if opts[name] == nil then
      error(string.format("config key %s has no option named %s", k, name))
    end
    h.assert_eq(opts[name], v, "option " .. name)
  end
  local mapped = 0
  for _ in pairs(opts) do mapped = mapped + 1 end
  h.assert_eq(mapped, declared, "options beyond the declared config keys")
end

function T.analyze_does_not_mutate_the_caller_s_tracks()
  local d = config.defaults().detection
  local total = 20 * RATE
  local input_track = { name = "BASS DI", slug = "bass", is_mic = false,
                        frames = frames_of(total, -60, -20, {{0,10}}, {}) }
  pipeline.analyze({
    tracks = { input_track }, items = { { start = 0, stop = 20 } },
    sel_start = 0, sel_stop = 20, detection = d,
  })
  h.assert_eq(input_track.live, nil, "caller's track gained a live field")
  h.assert_eq(input_track.floor_db, nil, "caller's track gained a floor_db field")
end

function T.analyze_finds_takes_across_a_hard_cut()
  local total = 200 * RATE
  local d = config.defaults().detection
  local tracks = {
    { name = "BASS DI", slug = "bass", is_mic = false,
      frames = frames_of(total, -60, -20, {{0,50},{100,180}}, {{60,100}}) },
    { name = "KEYS", slug = "keys", is_mic = false,
      frames = frames_of(total, -60, -60, {}, {{60,100}}) },
  }
  local items = { { start = 0, stop = 60 }, { start = 100, stop = 200 } }
  local r = pipeline.analyze({
    tracks = tracks, items = items,
    sel_start = 0, sel_stop = 200, detection = d,
  })
  h.assert_eq(#r.covered_spans, 2, "covered spans")
  h.assert_eq(#r.takes, 2, "takes")
  h.assert_eq(r.takes[1].span_index, 1)
  h.assert_eq(r.takes[2].span_index, 2)
  h.assert_eq(r.tracks[1].live, true, "bass live")
  h.assert_eq(r.tracks[2].live, false, "keys absent")
  h.assert_eq(#r.takes[1].instruments, 1)
  h.assert_eq(r.takes[1].instruments[1], "bass")
end

function T.a_frame_array_not_spanning_the_selection_is_rejected()
  local d = config.defaults().detection
  local ok, err = pcall(pipeline.analyze, {
    tracks = { { name = "SHORT", frames = { -60, -60 } } },
    items = { { start = 0, stop = 10 } },
    sel_start = 0, sel_stop = 10, detection = d,
  })
  h.assert_eq(ok, false, "expected an error")
  if not tostring(err):find("must span the whole selection") then
    error("wrong error: " .. tostring(err))
  end
end

function T.classify_then_detect_matches_a_single_analyze_call()
  -- The tuner classifies once and re-runs detect per slider move; that path
  -- must give exactly what the one-shot path gives.
  local d = config.defaults().detection
  local total = 200 * RATE
  local function build()
    return { { name = "BASS DI", slug = "bass", is_mic = false,
               frames = frames_of(total, -60, -20, {{0,50},{100,180}}, {{60,100}}) } }
  end
  local input = { tracks = build(), items = { { start = 0, stop = 60 }, { start = 100, stop = 200 } },
                  sel_start = 0, sel_stop = 200, detection = d }
  local one_shot = pipeline.analyze(input)

  local split_input = { tracks = build(), items = input.items,
                        sel_start = 0, sel_stop = 200, detection = d }
  local classified = pipeline.classify(split_input)
  local detected = pipeline.detect(classified, split_input)

  h.assert_eq(#detected.takes, #one_shot.takes, "take count")
  for i, take in ipairs(detected.takes) do
    h.assert_near(take.start, one_shot.takes[i].start, 1e-9)
    h.assert_near(take.stop, one_shot.takes[i].stop, 1e-9)
  end
end

function T.detect_can_be_re_run_with_new_thresholds_without_reclassifying()
  local d = config.defaults().detection
  local total = 200 * RATE
  local input = {
    tracks = { { name = "BASS DI", slug = "bass", is_mic = false,
                 frames = frames_of(total, -60, -20, {{0,50},{100,180}}, {{60,100}}) } },
    items = { { start = 0, stop = 60 }, { start = 100, stop = 200 } },
    sel_start = 0, sel_stop = 200, detection = d,
  }
  local classified = pipeline.classify(input)
  local before = pipeline.detect(classified, input)

  -- A minTakeSec above every take's length must empty the result, using the
  -- same classification.
  local raised = {}
  for k, v in pairs(d) do raised[k] = v end
  raised.minTakeSec = 10000
  input.detection = raised
  local after = pipeline.detect(classified, input)

  assert(#before.takes > 0, "expected takes before raising the threshold")
  h.assert_eq(#after.takes, 0, "takes after raising minTakeSec")
end

function T.detect_refuses_a_frame_rate_that_invalidates_the_classification()
  local d = config.defaults().detection
  local total = 200 * RATE
  local input = {
    tracks = { { name = "BASS DI", slug = "bass", is_mic = false,
                 frames = frames_of(total, -60, -20, {{0,50}}, {}) } },
    items = { { start = 0, stop = 200 } },
    sel_start = 0, sel_stop = 200, detection = d,
  }
  local classified = pipeline.classify(input)
  local changed = {}
  for k, v in pairs(d) do changed[k] = v end
  changed.frameRateHz = 40
  input.detection = changed
  local ok, err = pcall(pipeline.detect, classified, input)
  h.assert_eq(ok, false, "expected an error")
  if not tostring(err):find("re%-run classify") then
    error("wrong error: " .. tostring(err))
  end
end

return T
