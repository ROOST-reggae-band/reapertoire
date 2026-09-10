local h = require("test.helpers")
local manifest = require("lib.manifest")

local T = {}

local SESSION = {
  id = "5e2c8f1a", kind = "rehearsal",
  heldAt = "2026-09-05T19:30:00+02:00", label = "practice",
  range = { start = 1000, stop = 5000 },
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

function T.the_event_records_where_the_session_starts_on_the_timeline()
  -- Take positions are absolute project seconds; without this nothing
  -- downstream can turn one into a wall-clock time.
  local m = manifest.build(SESSION, { take() })
  h.assert_eq(m.event.rangeStart, 1000)
end

-- Orphaned take folders

local function manifest_with(paths)
  local takes = {}
  for _, p in ipairs(paths) do
    takes[#takes + 1] = { assets = { { path = p } } }
  end
  return { takes = takes }
end

function T.a_folder_no_take_uses_is_orphaned()
  local m = manifest_with({ "/out/01-boj-take-1-aaaaaaaa/master.mp3" })
  local orphans = manifest.orphan_dirs(m, {
    "/out/01-boj-take-1-aaaaaaaa", "/out/01-boj-take-1" })
  h.assert_eq(#orphans, 1)
  h.assert_eq(orphans[1], "/out/01-boj-take-1")
end

function T.a_folder_is_kept_by_a_stem_one_level_down()
  local m = manifest_with({ "/out/01-boj-take-1-aaaaaaaa/stems/bass.mp3" })
  h.assert_eq(#manifest.orphan_dirs(m, { "/out/01-boj-take-1-aaaaaaaa" }), 0)
end

function T.takes_this_render_did_not_touch_keep_their_folders()
  -- The whole reason this runs against the merged manifest: a partial render
  -- must not delete the rest of the session.
  local m = manifest_with({
    "/out/01-boj-take-1-aaaaaaaa/master.mp3",
    "/out/09-divko-take-2-bbbbbbbb/master.mp3",
  })
  h.assert_eq(#manifest.orphan_dirs(m, {
    "/out/01-boj-take-1-aaaaaaaa", "/out/09-divko-take-2-bbbbbbbb" }), 0)
end

function T.a_folder_whose_name_merely_starts_the_same_is_not_kept()
  local m = manifest_with({ "/out/01-boj-take-1/master.mp3" })
  local orphans = manifest.orphan_dirs(m, { "/out/01-boj-take-10" })
  h.assert_eq(#orphans, 1, "01-boj-take-10 is not 01-boj-take-1")
end

function T.nothing_is_orphaned_when_there_is_no_manifest()
  h.assert_eq(#manifest.orphan_dirs(nil, { "/out/anything" }), 1)
  h.assert_eq(#manifest.orphan_dirs({ takes = {} }, {}), 0)
end

-- Takes whose region no longer exists

local function take_at(ref, start)
  return { clientRef = ref, start = start, assets = { { path = "/out/" .. ref .. "/master.mp3" } } }
end

function T.a_take_whose_region_is_gone_is_dropped()
  -- Deleted and re-cut in REAPER: the old entry pointed at a folder whose
  -- audio belonged to whatever replaced it, and blocked every upload after.
  local existing = { takes = { take_at("a", 1), take_at("ghost", 2) } }
  local fresh = { takes = { take_at("a", 1) } }
  local out = manifest.merge(existing, fresh, { a = true })
  h.assert_eq(#out.takes, 1)
  h.assert_eq(out.takes[1].clientRef, "a")
end

function T.a_take_not_rendered_this_time_is_kept_if_its_region_lives()
  -- The reason merge exists: a partial render must not drop the rest.
  local existing = { takes = { take_at("a", 1), take_at("b", 2) } }
  local fresh = { takes = { take_at("a", 1) } }
  local out = manifest.merge(existing, fresh, { a = true, b = true })
  h.assert_eq(#out.takes, 2)
end

function T.without_a_known_region_set_nothing_is_dropped()
  local existing = { takes = { take_at("a", 1), take_at("ghost", 2) } }
  local out = manifest.merge(existing, { takes = { take_at("a", 1) } })
  h.assert_eq(#out.takes, 2, "no set given means no judgement")
end

function T.an_entry_with_no_ref_survives_because_it_cannot_be_checked()
  local existing = { takes = { { start = 1, assets = {} }, take_at("ghost", 2) } }
  local out = manifest.merge(existing, { takes = {} }, { a = true })
  h.assert_eq(#out.takes, 1)
  h.assert_eq(out.takes[1].clientRef, nil)
end

function T.a_dropped_takes_folder_then_reads_as_orphaned()
  -- The two halves together: the entry goes, and the cleanup can see the
  -- folder is unclaimed.
  local existing = { takes = { take_at("a", 1), take_at("ghost", 2) } }
  local out = manifest.merge(existing, { takes = { take_at("a", 1) } }, { a = true })
  local orphans = manifest.orphan_dirs(out, { "/out/a", "/out/ghost" })
  h.assert_eq(#orphans, 1)
  h.assert_eq(orphans[1], "/out/ghost")
end

-- Refreshing the event block from the session record

local function a_session(over)
  local base = { id = "sid", kind = "concert", heldAt = "2025-07-30T19:52:00+02:00",
                 label = "Nota", venue = "Nota", notes = "support slot",
                 range = { start = 100, stop = 400 } }
  for k, v in pairs(over or {}) do base[k] = v end
  return base
end

function T.the_event_block_is_rewritten_from_the_session()
  -- The sidecar owns what a rehearsal IS; the manifest carries a copy so it
  -- stays self-contained, and the copy is refreshed rather than re-rendered.
  local m = { event = { clientRef = "sid", kind = "rehearsal", label = "session" },
              takes = { { clientRef = "g1" } } }
  h.assert_eq(manifest.refresh_event(m, a_session()), true)
  h.assert_eq(m.event.kind, "concert")
  h.assert_eq(m.event.label, "Nota")
  h.assert_eq(m.event.venue, "Nota")
  h.assert_eq(m.event.notes, "support slot")
end

function T.refreshing_leaves_the_takes_alone()
  -- The manifest owns take data. Refreshing the event must not touch it.
  local m = { event = { clientRef = "sid" }, takes = { { clientRef = "g1" }, { clientRef = "g2" } } }
  manifest.refresh_event(m, a_session())
  h.assert_eq(#m.takes, 2)
end

function T.a_field_cleared_in_the_editor_is_cleared_in_the_manifest()
  -- Not merged: a venue removed must not survive in the copy.
  local m = { event = { clientRef = "sid", venue = "Sokolovna", notes = "old" }, takes = {} }
  local session = a_session()
  session.venue, session.notes = nil, nil
  manifest.refresh_event(m, session)
  h.assert_eq(m.event.venue, nil)
  h.assert_eq(m.event.notes, nil)
end

function T.a_manifest_for_a_different_session_is_refused()
  -- clientRef is identity: rewriting the event block of somebody else's
  -- manifest would relabel a whole rehearsal.
  local m = { event = { clientRef = "other" }, takes = {} }
  h.assert_eq(manifest.refresh_event(m, a_session()), false)
  h.assert_eq(m.event.clientRef, "other")
end

function T.a_manifest_with_no_event_is_refused_rather_than_invented()
  h.assert_eq(manifest.refresh_event({ takes = {} }, a_session()), false)
  h.assert_eq(manifest.refresh_event(nil, a_session()), false)
end

function T.the_range_start_travels_because_take_times_are_relative_to_it()
  local m = { event = { clientRef = "sid" }, takes = {} }
  manifest.refresh_event(m, a_session())
  h.assert_near(m.event.rangeStart, 100, 1e-9)
end

return T
