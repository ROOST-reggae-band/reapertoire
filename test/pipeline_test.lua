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

function T.every_detection_config_key_is_mapped()
  -- The point of this test: adding a config key without adding its mapping
  -- would otherwise surface as a nil threshold deep inside an analysis stage.
  local d = config.defaults().detection
  local opts = pipeline.detection_opts(d)
  local mapped = 0
  for _ in pairs(opts) do mapped = mapped + 1 end
  local declared = 0
  for _ in pairs(d) do declared = declared + 1 end
  h.assert_eq(mapped, declared, "mapped option count vs declared config keys")
  for k, v in pairs(opts) do
    if v == nil then error("option " .. k .. " mapped to nil") end
  end
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

return T
