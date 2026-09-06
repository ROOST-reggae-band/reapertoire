local h = require("test.helpers")
local timeline = require("lib.timeline")

local T = {}

function T.single_item_clipped_to_selection()
  local spans = timeline.covered_spans(
    { { start = 0, stop = 100 } }, 10, 50, 0.05)
  h.assert_spans(spans, { { start = 10, stop = 50 } })
end

function T.overlapping_items_across_tracks_merge_into_one_span()
  -- Everyone recording together: aligned but not identical item edges.
  local spans = timeline.covered_spans({
    { start = 0,    stop = 60 },
    { start = 0.01, stop = 60.02 },
    { start = 0,    stop = 59.98 },
  }, 0, 100, 0.05)
  h.assert_spans(spans, { { start = 0, stop = 60.02 } })
end

function T.hard_cut_produces_two_spans()
  -- Operator stopped and restarted: a real gap in the timeline.
  local spans = timeline.covered_spans({
    { start = 0,  stop = 60 },
    { start = 90, stop = 150 },
  }, 0, 200, 0.05)
  h.assert_spans(spans, { { start = 0, stop = 60 }, { start = 90, stop = 150 } })
end

function T.sub_frame_gaps_merge()
  -- 20 ms between items is an item-edge artefact, not a stop/start.
  local spans = timeline.covered_spans({
    { start = 0,     stop = 60 },
    { start = 60.02, stop = 120 },
  }, 0, 200, 0.05)
  h.assert_spans(spans, { { start = 0, stop = 120 } })
end

function T.late_arrival_extends_coverage_without_shortcutting()
  -- Trumpet arrives late: its item starts after everyone else's ends.
  local spans = timeline.covered_spans({
    { start = 0,   stop = 60 },
    { start = 200, stop = 260 },
  }, 0, 300, 0.05)
  h.assert_spans(spans, { { start = 0, stop = 60 }, { start = 200, stop = 260 } })
end

function T.items_entirely_outside_selection_are_dropped()
  local spans = timeline.covered_spans({
    { start = 0,   stop = 10 },
    { start = 500, stop = 600 },
  }, 100, 400, 0.05)
  h.assert_spans(spans, {})
end

function T.zero_length_intersection_is_dropped()
  local spans = timeline.covered_spans(
    { { start = 0, stop = 100 } }, 100, 200, 0.05)
  h.assert_spans(spans, {})
end

function T.unsorted_input_is_handled()
  local spans = timeline.covered_spans({
    { start = 90, stop = 150 },
    { start = 0,  stop = 60 },
  }, 0, 200, 0.05)
  h.assert_spans(spans, { { start = 0, stop = 60 }, { start = 90, stop = 150 } })
end

function T.fully_contained_item_does_not_shorten_its_span()
  local spans = timeline.covered_spans({
    { start = 0,  stop = 100 },
    { start = 20, stop = 30 },
  }, 0, 200, 0.05)
  h.assert_spans(spans, { { start = 0, stop = 100 } })
end

return T
