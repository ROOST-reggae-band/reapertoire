-- Runs the real pipeline over captured recordings. These are the tests that
-- actually decide whether the thresholds are right: every other suite checks
-- that a stage behaves as specified, this one checks that the specification
-- matches real rehearsal audio.
--
-- Capture a fixture with tools/capture_fixture.lua, count the run-throughs by
-- ear, and record what detection should produce in its `expected` block.

local h = require("test.helpers")
local json = require("lib.util.json")
local config = require("lib.config")
local pipeline = require("lib.pipeline")

local FIXTURES = { "fixture-no-drummer" }

local function load_fixture(name)
  local f = io.open("test/fixtures/" .. name .. ".json", "r")
  if not f then return nil end
  local contents = f:read("*a")
  f:close()
  return json.decode(contents)
end

local function analyze(fx)
  -- Deliberately the shipped defaults, not bespoke options: these tests exist
  -- to catch a default drifting away from what real audio needs.
  local tracks = {}
  for i, t in ipairs(fx.tracks) do
    tracks[i] = { name = t.name, slug = t.slug, is_mic = t.isMic, frames = t.frames }
  end
  return pipeline.analyze({
    tracks = tracks,
    items = fx.items,
    sel_start = fx.selStart,
    sel_stop = fx.selStop,
    detection = config.defaults().detection,
  })
end

local T = {}

for _, name in ipairs(FIXTURES) do
  local key = name:gsub("-", "_")

  T["spans_and_takes_in_" .. key] = function()
    local fx = load_fixture(name)
    if not fx then
      print("  SKIP " .. name .. " (not captured)")
      return
    end
    local r = analyze(fx)
    h.assert_eq(#r.covered_spans, fx.expected.spanCount, name .. " span count")
    h.assert_eq(#r.takes, fx.expected.takeCount, name .. " take count")
  end

  T["no_take_escapes_its_covered_span_in_" .. key] = function()
    local fx = load_fixture(name)
    if not fx then return end
    local r = analyze(fx)
    for i, take in ipairs(r.takes) do
      local span = r.covered_spans[take.span_index]
      assert(span, string.format("%s take %d has no span", name, i))
      assert(take.start >= span.start - 1e-6 and take.stop <= span.stop + 1e-6,
        string.format("%s take %d escaped its covered span", name, i))
    end
  end

  T["every_take_carries_at_least_one_instrument_in_" .. key] = function()
    local fx = load_fixture(name)
    if not fx then return end
    local r = analyze(fx)
    for i, take in ipairs(r.takes) do
      assert(#take.instruments > 0,
        string.format("%s take %d reports no instruments", name, i))
    end
  end

  T["at_least_one_track_is_live_in_" .. key] = function()
    -- A session where everything classifies absent means the floor reference
    -- has drifted, which is how the first real run failed.
    local fx = load_fixture(name)
    if not fx then return end
    local r = analyze(fx)
    local live = 0
    for _, t in ipairs(r.tracks) do
      if t.live then live = live + 1 end
    end
    assert(live > 0, name .. " classified every track as absent")
  end
end

return T
