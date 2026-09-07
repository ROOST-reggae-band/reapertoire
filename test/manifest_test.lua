local h = require("test.helpers")
local manifest = require("lib.manifest")

local T = {}

local SESSION = {
  id = "5e2c8f1a", kind = "rehearsal",
  heldAt = "2026-09-05T19:30:00+02:00", label = "practice",
}

-- A nil in a Lua table literal is an absent key, not a removal, so dropping a
-- field needs to be asked for explicitly.
local function take(extra, drop)
  local t = {
    guid = "{A1B2}", start = 10, stop = 20,
    song = "Dub Corner", label = "take 1", take_no = 1,
    instruments = { "bass" },
    assets = { { kind = "master", format = "opus", path = "x/master.opus",
                 bytes = 100, sha256 = "abc", sampleRate = 48000, channels = 2 } },
  }
  for k, v in pairs(extra or {}) do t[k] = v end
  for _, k in ipairs(drop or {}) do t[k] = nil end
  return t
end

function T.take_refs_are_namespaced_region_guids()
  h.assert_eq(manifest.take_ref("{A1B2}"), "reaper:region-guid:{A1B2}")
  h.assert_eq(manifest.take_ref(nil), nil)
  h.assert_eq(manifest.take_ref(""), nil)
end

function T.duration_is_milliseconds_rounded()
  local m = manifest.build(SESSION, { take({ start = 0, stop = 254.3004 }) })
  h.assert_eq(m.takes[1].durationMs, 254300)
end

function T.the_event_carries_the_session_identity()
  local m = manifest.build(SESSION, { take() })
  h.assert_eq(m.event.clientRef, "5e2c8f1a")
  h.assert_eq(m.event.kind, "rehearsal")
  h.assert_eq(m.event.heldAt, "2026-09-05T19:30:00+02:00")
end

function T.kind_defaults_to_rehearsal()
  local m = manifest.build({ id = "x" }, {})
  h.assert_eq(m.event.kind, "rehearsal")
end

function T.takes_come_out_in_timeline_order()
  local m = manifest.build(SESSION, {
    take({ guid = "{B}", start = 90, stop = 100 }),
    take({ guid = "{A}", start = 10, stop = 20 }),
  })
  h.assert_eq(m.takes[1].clientRef, "reaper:region-guid:{A}")
  h.assert_eq(m.takes[2].clientRef, "reaper:region-guid:{B}")
end

function T.assets_keep_the_fields_ingest_needs()
  local m = manifest.build(SESSION, { take() })
  local a = m.takes[1].assets[1]
  h.assert_eq(a.kind, "master")
  h.assert_eq(a.bytes, 100)
  h.assert_eq(a.sha256, "abc")
  h.assert_eq(a.sampleRate, 48000)
  h.assert_eq(a.channels, 2)
  h.assert_eq(a.tier, "lossy", "tier defaults rather than being absent")
end

function T.a_complete_manifest_reports_no_problems()
  h.assert_eq(#manifest.problems(manifest.build(SESSION, { take() })), 0)
end

function T.a_take_without_a_song_is_reported()
  local m = manifest.build(SESSION, { take(nil, { "song" }) })
  local p = manifest.problems(m)
  h.assert_eq(#p, 1)
  assert(p[1]:find("no song"), p[1])
end

function T.a_take_without_a_region_guid_is_reported()
  local m = manifest.build(SESSION, { take(nil, { "guid" }) })
  local p = manifest.problems(m)
  assert(p[1]:find("no region GUID"), p[1])
end

function T.a_take_that_rendered_nothing_is_reported()
  local m = manifest.build(SESSION, { take({ assets = {} }) })
  local p = manifest.problems(m)
  assert(p[1]:find("rendered no files"), p[1])
end

function T.a_session_missing_its_date_is_reported()
  local m = manifest.build({ id = "x" }, {})
  local p = manifest.problems(m)
  assert(p[1]:find("no date"), p[1])
end

function T.merging_keeps_takes_from_an_earlier_run()
  -- Rendering takes 6-10 of a session must not drop takes 1-5.
  local first = manifest.build(SESSION, { take({ guid = "{A}", start = 10, stop = 20 }) })
  local second = manifest.build(SESSION, { take({ guid = "{B}", start = 90, stop = 100 }) })
  local merged = manifest.merge(first, second)
  h.assert_eq(#merged.takes, 2)
  h.assert_eq(merged.takes[1].clientRef, "reaper:region-guid:{A}")
  h.assert_eq(merged.takes[2].clientRef, "reaper:region-guid:{B}")
end

function T.merging_replaces_a_take_rendered_again()
  local first = manifest.build(SESSION, { take({ guid = "{A}", song = "Old" }) })
  local second = manifest.build(SESSION, { take({ guid = "{A}", song = "Corrected" }) })
  local merged = manifest.merge(first, second)
  h.assert_eq(#merged.takes, 1, "same take, not two")
  h.assert_eq(merged.takes[1].song, "Corrected")
end

function T.merging_into_nothing_is_the_fresh_manifest()
  local fresh = manifest.build(SESSION, { take() })
  h.assert_eq(#manifest.merge(nil, fresh).takes, 1)
  h.assert_eq(#manifest.merge({}, fresh).takes, 1)
end

return T
