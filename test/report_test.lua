local h = require("test.helpers")
local report = require("lib.report")

local T = {}

local function sample()
  return {
    sel_start = 0, sel_stop = 300, rate = 20,
    tracks = {
      { name = "BASS DI 2", slug = "bass", live = true,
        floor_db = -58.2, active_fraction = 0.41 },
      { name = "KEYS", slug = "keys", live = false,
        floor_db = -61.0, active_fraction = 0.001 },
    },
    covered_spans = {
      { start = 0, stop = 150 },
      { start = 160, stop = 300 },
    },
    takes = {
      { start = 10, stop = 70, span_index = 1, instruments = { "bass" } },
      { start = 165, stop = 290, span_index = 2, instruments = { "bass" } },
    },
    warnings = { "unmapped live track: NEW MIC 4" },
    opts = { minGapSec = 4.0, minTakeSec = 30.0 },
  }
end

function T.reports_absent_tracks_so_the_operator_can_correct_the_heuristic()
  local text = report.render(sample())
  assert(text:find("KEYS"), "absent track not listed")
  assert(text:find("not present"), "absence not stated in words")
end

function T.reports_the_measured_floor_per_track()
  local text = report.render(sample())
  assert(text:find("%-58%.2"), "bass floor not reported")
end

function T.reports_span_count_and_whether_detection_subdivided_each()
  local text = report.render(sample())
  assert(text:find("2 covered spans"), "span count missing")
  -- One take in each span means neither was subdivided.
  assert(text:find("1 take"), "per-span take count missing")
end

function T.reports_each_take_with_duration_and_instruments()
  local text = report.render(sample())
  assert(text:find("0:10"), "take start not formatted as mm:ss")
  assert(text:find("bass"), "instruments missing")
end

function T.surfaces_warnings()
  local text = report.render(sample())
  assert(text:find("NEW MIC 4"), "warning not surfaced")
end

function T.states_plainly_when_nothing_was_detected()
  local data = sample()
  data.takes = {}
  local text = report.render(data)
  assert(text:find("No takes detected"), "empty result not stated")
end

return T
