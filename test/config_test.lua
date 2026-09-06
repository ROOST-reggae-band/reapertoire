local h = require("test.helpers")
local config = require("lib.config")

local T = {}

function T.defaults_cover_every_detection_tunable()
  local d = config.defaults()
  h.assert_eq(d.detection.frameRateHz, 20)
  h.assert_eq(d.detection.minGapSec, 4.0)
  h.assert_eq(d.detection.minTakeSec, 30.0)
  h.assert_eq(d.detection.micWeight, 0.35)
  h.assert_eq(d.detection.snapToMeasure, false)
end

function T.merge_overrides_only_the_leaves_given()
  local merged = config.merge(
    config.defaults(), { detection = { minGapSec = 2.5 } })
  h.assert_eq(merged.detection.minGapSec, 2.5)
  h.assert_eq(merged.detection.minTakeSec, 30.0, "untouched leaf preserved")
end

function T.merge_replaces_arrays_wholesale()
  -- Merging arrays element-wise would make it impossible to remove a track rule.
  local merged = config.merge(
    config.defaults(), { tracks = { { match = "ONLY", slug = "x" } } })
  h.assert_eq(#merged.tracks, 1)
  h.assert_eq(merged.tracks[1].match, "ONLY")
end

function T.expand_path_expands_a_leading_tilde()
  local expanded = config.expand_path("~/Music/X", "/Users/example")
  h.assert_eq(expanded, "/Users/example/Music/X")
end

function T.expand_path_leaves_absolute_paths_alone()
  h.assert_eq(config.expand_path("/tmp/x", "/Users/example"), "/tmp/x")
end

function T.match_track_prefers_an_exact_name()
  local rules = {
    { match = "BASS", slug = "wrong" },
    { match = "BASS DI 2", slug = "right" },
  }
  h.assert_eq(config.match_track("BASS DI 2", rules).slug, "right")
end

function T.match_track_falls_back_to_substring()
  local rules = { { match = "BASS", slug = "bass" } }
  h.assert_eq(config.match_track("BASS DI 2", rules).slug, "bass")
end

function T.match_track_is_case_insensitive()
  local rules = { { match = "bass di", slug = "bass" } }
  h.assert_eq(config.match_track("BASS DI 2", rules).slug, "bass")
end

function T.match_track_returns_nil_when_unmapped()
  local rules = { { match = "BASS", slug = "bass" } }
  h.assert_eq(config.match_track("NEW MIC 4", rules), nil)
end

function T.load_falls_back_to_the_example_when_settings_are_missing()
  local function fake_read(path)
    if path:match("example") then
      return '{"sessionsRoot":"/from/example"}'
    end
    return nil
  end
  local cfg, used_example = config.load("/repo", fake_read)
  h.assert_eq(used_example, true)
  h.assert_eq(cfg.sessionsRoot, "/from/example")
end

function T.load_prefers_settings_over_the_example()
  local function fake_read(path)
    if path:match("example") then return '{"sessionsRoot":"/from/example"}' end
    return '{"sessionsRoot":"/from/settings"}'
  end
  local cfg, used_example = config.load("/repo", fake_read)
  h.assert_eq(used_example, false)
  h.assert_eq(cfg.sessionsRoot, "/from/settings")
end

return T
