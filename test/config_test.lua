local h = require("test.helpers")
local config = require("lib.config")
local json = require("lib.util.json")

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

function T.merge_clears_tracks_with_a_decoded_empty_array()
  -- dkjson tags a decoded [] with __jsontype = 'array', distinguishing it from
  -- an empty {} object. An empty array must genuinely clear the base list --
  -- previously #override > 0 made the empty-array branch unreachable, so an
  -- override meant to remove every track rule silently kept the base ones.
  local base = config.merge(
    config.defaults(), { tracks = { { match = "X", slug = "x" } } })
  local override = json.decode('{"tracks":[]}')
  local merged = config.merge(base, override)
  h.assert_eq(#merged.tracks, 0)
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

function T.load_errors_when_no_config_file_is_found()
  local function fake_read(_) return nil end
  local ok, err = pcall(config.load, "/repo", fake_read)
  h.assert_eq(ok, false)
  if not tostring(err):match("no config found") then
    error("expected a 'no config found' error, got: " .. tostring(err))
  end
end

function T.load_errors_on_invalid_json()
  local function fake_read(path)
    if path:match("example") then return nil end
    return "{ not json"
  end
  local ok, err = pcall(config.load, "/repo", fake_read)
  h.assert_eq(ok, false)
  if not tostring(err):match("not valid JSON") then
    error("expected a 'not valid JSON' error, got: " .. tostring(err))
  end
end

function T.validate_rejects_a_missing_detection_key()
  local cfg = config.defaults()
  cfg.detection.minGapSec = nil
  local ok, err = pcall(config.validate, cfg)
  h.assert_eq(ok, false)
  if not tostring(err):match("minGapSec") then
    error("expected error naming minGapSec, got: " .. tostring(err))
  end
end

function T.validate_rejects_a_track_rule_missing_match()
  local cfg = config.defaults()
  cfg.tracks = { { slug = "bass" } }
  local ok, err = pcall(config.validate, cfg)
  h.assert_eq(ok, false)
  if not tostring(err):match("tracks%[1%]") then
    error("expected error naming tracks[1], got: " .. tostring(err))
  end
end

function T.validate_accepts_the_defaults()
  local ok = pcall(config.validate, config.defaults())
  h.assert_eq(ok, true)
end

return T
