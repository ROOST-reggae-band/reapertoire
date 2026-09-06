local h = require("test.helpers")
local peaks = require("lib.util.peaks")

local T = {}

-- Real values captured by tools/probe_peaks.lua from a rehearsal recording:
-- mono, 8 frames, maximums block then minimums block.
local PROBE = {
  0.15360, 0.16175, 0.07828, 0.28971, 0.24232, 0.22987, 0.22193, 0.21754,
  -0.20325, -0.18707, -0.13086, -0.26489, -0.21780, -0.21121, -0.21252, -0.21393,
}

function T.decodes_real_captured_peaks()
  local db = peaks.to_db(PROBE, 8, 1)
  h.assert_eq(#db, 8, "frame count")
  -- Frame 1's magnitude comes from the MINIMUMS block (0.20325 > 0.15360),
  -- so this value passing proves both blocks are read, not just the first.
  h.assert_near(db[1], -13.8394, 0.001)
  -- Frame 4's comes from the maximums block (0.28971 > 0.26489).
  h.assert_near(db[4], -10.7607, 0.001)
end

function T.an_all_zero_buffer_decodes_to_the_silence_floor()
  -- This is what a read outside an item's media returns: zeros, no error.
  -- It must decode to a defined floor, never to 0 dB or an arithmetic error.
  local db = peaks.to_db({ 0, 0, 0, 0 }, 2, 1)
  h.assert_eq(db[1], -140)
  h.assert_eq(db[2], -140)
end

function T.channels_are_interleaved_and_the_loudest_wins()
  -- Two frames, two channels: channel 1 quiet, channel 2 loud.
  local buf = { 0.01, 0.50, 0.02, 0.40, -0.01, -0.30, -0.02, -0.45 }
  local db = peaks.to_db(buf, 2, 2)
  h.assert_near(db[1], -6.0206, 0.001)
  h.assert_near(db[2], -6.9357, 0.001)
end

function T.full_scale_is_zero_db()
  h.assert_near(peaks.amplitude_to_db(1.0), 0, 1e-9)
end

function T.amplitude_to_db_floors_rather_than_diverging()
  -- log(0) is -inf; the floor keeps a silent frame comparable with real ones.
  h.assert_eq(peaks.amplitude_to_db(0), -140)
end

return T
