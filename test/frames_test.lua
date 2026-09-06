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

return T
