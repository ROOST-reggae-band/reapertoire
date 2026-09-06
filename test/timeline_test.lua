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

function T.spans_that_share_time_overlap()
  h.assert_eq(timeline.overlaps({start=0,stop=10},{start=5,stop=15}), true)
  h.assert_eq(timeline.overlaps({start=5,stop=15},{start=0,stop=10}), true)
end

function T.a_span_contained_in_another_overlaps()
  h.assert_eq(timeline.overlaps({start=2,stop=4},{start=0,stop=10}), true)
  h.assert_eq(timeline.overlaps({start=0,stop=10},{start=2,stop=4}), true)
end

function T.spans_that_merely_touch_do_not_overlap()
  -- A take ending exactly where a region starts is adjacent, not colliding.
  h.assert_eq(timeline.overlaps({start=0,stop=10},{start=10,stop=20}), false)
  h.assert_eq(timeline.overlaps({start=10,stop=20},{start=0,stop=10}), false)
end

function T.disjoint_spans_do_not_overlap()
  h.assert_eq(timeline.overlaps({start=0,stop=10},{start=20,stop=30}), false)
end

function T.first_overlap_returns_the_colliding_span()
  local others = { {start=100,stop=200,name="A"}, {start=5,stop=15,name="B"} }
  local hit = timeline.first_overlap({start=0,stop=10}, others)
  h.assert_eq(hit.name, "B")
end

function T.first_overlap_returns_nil_when_clear()
  local others = { {start=100,stop=200,name="A"} }
  h.assert_eq(timeline.first_overlap({start=0,stop=10}, others), nil)
end

function T.first_overlap_of_an_empty_list_is_nil()
  h.assert_eq(timeline.first_overlap({start=0,stop=10}, {}), nil)
end

return T
