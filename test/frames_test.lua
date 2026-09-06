local h = require("test.helpers")
local frames = require("lib.util.frames")

local T = {}

function T.first_frame_is_index_one()
  h.assert_eq(frames.index_of(0, 0, 20), 1)
  h.assert_eq(frames.index_of(100, 100, 20), 1)
end

function T.index_advances_with_the_frame_rate()
  h.assert_eq(frames.index_of(0.05, 0, 20), 2)
  h.assert_eq(frames.index_of(1.0, 0, 20), 21)
end

function T.index_is_relative_to_selection_start()
  h.assert_eq(frames.index_of(101.0, 100, 20), 21)
end

function T.time_of_inverts_index_of()
  h.assert_near(frames.time_of(1, 100, 20), 100)
  h.assert_near(frames.time_of(21, 100, 20), 101)
end

function T.count_covers_the_whole_selection()
  h.assert_eq(frames.count(0, 1, 20), 20)
  h.assert_eq(frames.count(0, 1.5, 20), 30)
end

function T.count_rounds_up_a_partial_final_frame()
  h.assert_eq(frames.count(0, 1.01, 20), 21)
end

function T.range_of_excludes_the_frame_starting_at_stop()
  -- index_of(span.stop) is the first frame of the NEXT span; range_of must
  -- stop one frame short of it.
  local i0, i1 = frames.range_of({ start = 0, stop = 1 }, 0, 20)
  h.assert_eq(i0, 1)
  h.assert_eq(i1, 20)
end

function T.range_of_clamps_i0_to_one_for_a_span_before_the_selection()
  local i0 = frames.range_of({ start = -5, stop = 1 }, 0, 20)
  h.assert_eq(i0, 1)
end

function T.range_of_clamps_i1_to_n_frames_when_given()
  local _, i1 = frames.range_of({ start = 0, stop = 100 }, 0, 20, 50)
  h.assert_eq(i1, 50)
end

function T.range_of_applies_no_upper_clamp_when_n_frames_is_nil()
  local _, i1 = frames.range_of({ start = 0, stop = 100 }, 0, 20, nil)
  h.assert_eq(i1, 2000)
end

return T
