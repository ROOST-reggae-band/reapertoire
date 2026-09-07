local h = require("test.helpers")
local time = require("lib.util.time")

local T = {}

function T.omits_hours_when_there_are_none()
  h.assert_eq(time.hms(0), "0:00.00")
  h.assert_eq(time.hms(40), "0:40.00")
  h.assert_eq(time.hms(95.5), "1:35.50")
end

function T.shows_hours_once_there_are_some()
  h.assert_eq(time.hms(3600), "1:00:00.00")
  h.assert_eq(time.hms(3661.25), "1:01:01.25")
end

function T.copes_with_a_timeline_tens_of_hours_long()
  -- A project holding many rehearsals reaches this, and minutes-only
  -- formatting produced "3482:35.62" here.
  h.assert_eq(time.hms(209555.62), "58:12:35.62")
end

function T.handles_a_negative_offset()
  h.assert_eq(time.hms(-95.5), "-1:35.50")
end

function T.nil_is_a_question_mark_not_an_error()
  h.assert_eq(time.hms(nil), "?")
  h.assert_eq(time.duration(nil), "?")
end

function T.durations_read_as_lengths()
  h.assert_eq(time.duration(45), "45s")
  h.assert_eq(time.duration(95), "1m 35s")
  h.assert_eq(time.duration(275.2), "4m 35s")
end

function T.a_duration_rounding_up_to_a_whole_minute_carries()
  h.assert_eq(time.duration(59.7), "1m 00s")
end

return T
