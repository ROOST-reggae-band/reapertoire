local h = require("test.helpers")
local session = require("lib.session")

local T = {}

local function doc_with(...)
  local doc = session.empty()
  for _, s in ipairs({ ... }) do doc.sessions[#doc.sessions + 1] = s end
  return doc
end

local function sess(id, from, to, extra)
  local s = { id = id, range = { start = from, stop = to } }
  for k, v in pairs(extra or {}) do s[k] = v end
  return s
end

function T.an_absent_or_broken_sidecar_reads_as_empty()
  h.assert_eq(#session.decode(nil).sessions, 0)
  h.assert_eq(#session.decode("").sessions, 0)
  h.assert_eq(#session.decode("not json at all").sessions, 0)
  h.assert_eq(#session.decode('{"nonsense":true}').sessions, 0)
end

function T.a_document_survives_a_round_trip()
  local doc = doc_with(sess("a", 0, 100, { label = "one" }))
  local back = session.decode(session.encode(doc))
  h.assert_eq(#back.sessions, 1)
  h.assert_eq(back.sessions[1].id, "a")
  h.assert_eq(back.sessions[1].range.stop, 100)
end

function T.a_range_inside_a_session_finds_it()
  local doc = doc_with(sess("a", 0, 100))
  local found, how = session.find(doc, 10, 50)
  h.assert_eq(how, "existing")
  h.assert_eq(found.id, "a")
end

function T.a_range_overlapping_nothing_is_new()
  local doc = doc_with(sess("a", 0, 100))
  local found, how = session.find(doc, 500, 600)
  h.assert_eq(found, nil)
  h.assert_eq(how, "new")
end

function T.a_range_spanning_two_sessions_refuses_to_guess()
  -- Filing takes under the wrong rehearsal is worse than asking.
  local doc = doc_with(sess("a", 0, 100), sess("b", 200, 300))
  local found, how, candidates = session.find(doc, 50, 250)
  h.assert_eq(found, nil)
  h.assert_eq(how, "ambiguous")
  h.assert_eq(#candidates, 2)
end

function T.adjacent_sessions_do_not_overlap()
  -- One rehearsal ending exactly where the next begins is two rehearsals.
  local doc = doc_with(sess("a", 0, 100))
  local _, how = session.find(doc, 100, 200)
  h.assert_eq(how, "new")
end

function T.upsert_adds_a_session_that_is_new()
  local doc = session.empty()
  local s, created = session.upsert(doc, sess("a", 0, 100))
  h.assert_eq(created, true)
  h.assert_eq(#doc.sessions, 1)
  h.assert_eq(s.id, "a")
end

function T.upsert_converges_on_the_existing_session_rather_than_duplicating()
  local doc = doc_with(sess("a", 0, 100, { label = "one" }))
  local s, created = session.upsert(doc, sess("b", 10, 50))
  h.assert_eq(created, false, "no second session")
  h.assert_eq(#doc.sessions, 1)
  h.assert_eq(s.id, "a", "the original identity is kept")
end

function T.upsert_widens_a_range_but_never_shrinks_it()
  -- Selecting more of a rehearsal is still that rehearsal; selecting less must
  -- not orphan takes already rendered from the wider range.
  local doc = doc_with(sess("a", 100, 200))
  session.upsert(doc, sess("a", 50, 150))
  h.assert_eq(doc.sessions[1].range.start, 50)
  h.assert_eq(doc.sessions[1].range.stop, 200)

  session.upsert(doc, sess("a", 120, 130))
  h.assert_eq(doc.sessions[1].range.start, 50, "not shrunk")
  h.assert_eq(doc.sessions[1].range.stop, 200, "not shrunk")
end

function T.upsert_updates_descriptive_fields()
  local doc = doc_with(sess("a", 0, 100, { label = "old" }))
  session.upsert(doc, sess("a", 0, 100, { label = "new", heldAt = "2026-09-05T19:30:00+02:00" }))
  h.assert_eq(doc.sessions[1].label, "new")
  h.assert_eq(doc.sessions[1].heldAt, "2026-09-05T19:30:00+02:00")
end

function T.folder_name_is_date_then_slug()
  h.assert_eq(session.folder_name({
    heldAt = "2026-09-05T19:30:00+02:00", label = "Zkušebna",
  }), "2026-09-05-zkusebna")
end

function T.folder_name_copes_with_a_missing_date_or_label()
  h.assert_eq(session.folder_name({ label = "x" }), "undated-x")
  h.assert_eq(session.folder_name({ heldAt = "2026-01-02T00:00:00Z" }), "2026-01-02-session")
end

function T.reads_the_recording_date_out_of_a_reaper_filename()
  local date, time = session.date_from_filename("26-Organ-260528_2125.wav")
  h.assert_eq(date, "2026-05-28")
  h.assert_eq(time, "21:25")
end

function T.the_date_survives_a_full_path()
  local date = session.date_from_filename("/Volumes/X/Media/27-Sax-260528_2125.wav")
  h.assert_eq(date, "2026-05-28")
end

function T.a_filename_without_a_timestamp_yields_nothing()
  h.assert_eq(session.date_from_filename("bounce.wav"), nil)
  h.assert_eq(session.date_from_filename(nil), nil)
end

function T.an_impossible_date_is_rejected_rather_than_believed()
  -- Otherwise a track called "Kick 991399_9999" would set the session date.
  h.assert_eq(session.date_from_filename("x-991399_9999.wav"), nil)
end

function T.iso8601_carries_an_offset()
  local iso = session.iso8601("2026-09-05", "19:30")
  assert(iso:match("^2026%-09%-05T19:30:00[+%-]%d%d:%d%d$"),
    "expected an offset, got " .. tostring(iso))
end

function T.iso8601_defaults_a_missing_time_to_midnight()
  local iso = session.iso8601("2026-09-05")
  assert(iso:match("^2026%-09%-05T00:00:00"), iso)
end

function T.iso8601_rejects_a_date_it_cannot_parse()
  h.assert_eq(session.iso8601("5th of September"), nil)
  h.assert_eq(session.iso8601("2026-9-5"), nil)
end

function T.the_offset_is_for_the_sessions_own_date()
  -- A summer and a winter rehearsal in a DST zone must not share an offset
  -- just because they were filed on the same day.
  local summer = session.iso8601("2026-07-01", "12:00"):match("([+%-]%d%d:%d%d)$")
  local winter = session.iso8601("2026-01-01", "12:00"):match("([+%-]%d%d:%d%d)$")
  if os.date("*t", os.time({year=2026,month=7,day=1,hour=12})).isdst
     ~= os.date("*t", os.time({year=2026,month=1,day=1,hour=12})).isdst then
    assert(summer ~= winter, "expected different offsets across DST, both " .. summer)
  end
end

function T.recognises_a_timestamp_that_already_has_an_offset()
  h.assert_eq(session.has_offset("2026-09-05T19:30:00+02:00"), true)
  h.assert_eq(session.has_offset("2026-09-05T19:30:00Z"), true)
  h.assert_eq(session.has_offset("2026-09-05T19:30:00"), false)
  h.assert_eq(session.has_offset(nil), false)
end

function T.upgrades_a_stored_timestamp_that_predates_offsets()
  local upgraded = session.with_offset("2025-12-04T20:48:00")
  assert(upgraded:match("^2025%-12%-04T20:48:00[+%-]%d%d:%d%d$"), upgraded)
end

function T.upgrading_leaves_an_already_offset_timestamp_alone()
  local already = "2026-09-05T19:30:00+02:00"
  h.assert_eq(session.with_offset(already), already)
end

function T.upgrading_something_unparseable_returns_it_unchanged()
  h.assert_eq(session.with_offset("whenever"), "whenever")
  h.assert_eq(session.with_offset(nil), nil)
end

function T.a_selection_barely_touching_a_session_is_not_that_session()
  -- Rehearsals sit end to end, so a few seconds of overlap is a near miss.
  -- Filing takes under the neighbouring rehearsal is worse than asking.
  local doc = doc_with(sess("a", 0, 1000))
  local found, how, candidates = session.find(doc, 995, 2000)
  h.assert_eq(found, nil)
  h.assert_eq(how, "partial")
  h.assert_eq(#candidates, 1)
end

function T.a_short_selection_inside_a_session_is_that_session()
  -- Re-rendering part of a rehearsal must find it, so the ratio is measured
  -- against the shorter span rather than the session's whole length.
  local doc = doc_with(sess("a", 0, 3600))
  local found, how = session.find(doc, 1000, 1100)
  h.assert_eq(how, "existing")
  h.assert_eq(found.id, "a")
end

function T.a_selection_covering_most_of_a_session_is_that_session()
  local doc = doc_with(sess("a", 100, 200))
  local found, how = session.find(doc, 0, 300)
  h.assert_eq(how, "existing")
  h.assert_eq(found.id, "a")
end

-- Timeline markers

local function sess(over)
  local base = { id = "a", label = "Choltice", heldAt = "2025-09-27T19:30:00+02:00",
                 range = { start = 100.5, stop = 400.25 },
                 takes = { {}, {}, {} } }
  for k, v in pairs(over or {}) do base[k] = v end
  return base
end

function T.a_session_becomes_a_marker_at_each_end()
  local m = session.span_markers(sess())
  h.assert_eq(#m, 2)
  h.assert_near(m[1].at, 100.5, 1e-9)
  h.assert_near(m[2].at, 400.25, 1e-9)
end

function T.the_opening_marker_names_the_rehearsal_and_counts_its_takes()
  local m = session.span_markers(sess())
  h.assert_eq(m[1].name, "\u{25B6} 2025-09-27 Choltice - 3 takes")
end

function T.the_closing_marker_is_terse_because_it_repeats_nothing()
  h.assert_eq(session.span_markers(sess())[2].name, "\u{25C0} Choltice ends")
end

function T.one_take_is_not_called_takes()
  local m = session.span_markers(sess({ takes = { {} } }))
  h.assert_eq(m[1].name, "\u{25B6} 2025-09-27 Choltice - 1 take")
end

function T.a_session_with_no_takes_says_so_rather_than_zero()
  local m = session.span_markers(sess({ takes = {} }))
  h.assert_eq(m[1].name, "\u{25B6} 2025-09-27 Choltice - not rendered")
end

function T.an_unlabelled_session_falls_back_to_the_date()
  -- Built rather than overridden: `pairs` never yields a nil, so passing
  -- `label = nil` to the helper would silently keep the label.
  local unlabelled = sess()
  unlabelled.label = nil
  local m = session.span_markers(unlabelled)
  h.assert_eq(m[1].name, "\u{25B6} 2025-09-27 rehearsal - 3 takes")
  h.assert_eq(m[2].name, "\u{25C0} rehearsal ends")
end

function T.a_session_with_no_range_yields_no_markers()
  -- Nothing to point at; better than two markers at zero.
  local no_range = sess()
  no_range.range = nil
  h.assert_eq(#session.span_markers(no_range), 0)
  h.assert_eq(#session.span_markers(sess({ range = { start = 1 } })), 0)
end

-- Editing a session's metadata

local function editable()
  return { id = "a", kind = "rehearsal", label = "session",
           heldAt = "2025-09-27T19:30:00+02:00",
           range = { start = 100, stop = 400 }, takes = { {}, {} } }
end

function T.editing_writes_the_fields_through()
  local sess = editable()
  local problems = session.update(sess, {
    label = "Choltice", kind = "concert", venue = "Sokolovna", notes = "new tune" })
  h.assert_eq(#problems, 0)
  h.assert_eq(sess.label, "Choltice")
  h.assert_eq(sess.kind, "concert")
  h.assert_eq(sess.venue, "Sokolovna")
  h.assert_eq(sess.notes, "new tune")
end

function T.changing_the_date_keeps_the_time_of_day_and_the_offset()
  -- The contract rejects a timestamp with no offset, and rebuilding the string
  -- from the date alone would throw away the hour the rehearsal started.
  local sess = editable()
  session.update(sess, { date = "2025-10-01" })
  h.assert_eq(sess.heldAt:sub(1, 10), "2025-10-01")
  h.assert_eq(sess.heldAt:match("19:30") ~= nil, true, "kept the time")
  h.assert_eq(session.has_offset(sess.heldAt), true)
end

function T.a_malformed_date_is_refused_and_changes_nothing()
  local sess = editable()
  local problems = session.update(sess, { date = "27/09/2025", label = "Choltice" })
  h.assert_eq(#problems, 1)
  h.assert_eq(sess.heldAt, "2025-09-27T19:30:00+02:00", "left alone")
  h.assert_eq(sess.label, "session", "nothing applied when anything is wrong")
end

function T.an_unknown_kind_is_refused()
  -- The server takes exactly three, and a typo would only surface as a 422
  -- part-way through an upload.
  local problems = session.update(editable(), { kind = "jam" })
  h.assert_eq(#problems, 1)
  h.assert_eq(problems[1]:match("rehearsal") ~= nil, true, "names the valid ones")
end

function T.a_blank_venue_or_note_is_absent_not_empty()
  -- Nullable but min-length-1 server-side: "" is a 422, absent is fine.
  local sess = editable()
  sess.venue, sess.notes = "Sokolovna", "something"
  session.update(sess, { venue = "", notes = "   " })
  h.assert_eq(sess.venue, nil)
  h.assert_eq(sess.notes, nil)
end

function T.a_blank_label_is_refused_because_a_session_needs_a_name()
  local problems = session.update(editable(), { label = "  " })
  h.assert_eq(#problems, 1)
end

function T.fields_not_given_are_left_alone()
  local sess = editable()
  sess.venue = "Sokolovna"
  session.update(sess, { label = "Choltice" })
  h.assert_eq(sess.venue, "Sokolovna")
  h.assert_eq(sess.kind, "rehearsal")
end

function T.removing_a_session_takes_only_that_one()
  local doc = { schema = 1, sessions = {
    { id = "a", range = { start = 0, stop = 10 } },
    { id = "b", range = { start = 20, stop = 30 } },
  } }
  h.assert_eq(session.remove(doc, "a"), true)
  h.assert_eq(#doc.sessions, 1)
  h.assert_eq(doc.sessions[1].id, "b")
end

function T.removing_an_unknown_session_reports_it_rather_than_guessing()
  local doc = { schema = 1, sessions = { { id = "a", range = { start = 0, stop = 10 } } } }
  h.assert_eq(session.remove(doc, "zzz"), false)
  h.assert_eq(#doc.sessions, 1)
end

function T.a_re_render_no_longer_wipes_the_venue_and_notes()
  -- upsert carried forward only label/kind/heldAt/outputDir, so anything typed
  -- into the editor vanished on the next render.
  local doc = { schema = 1, sessions = {} }
  session.upsert(doc, { id = "a", range = { start = 0, stop = 100 },
                        label = "Choltice", venue = "Sokolovna", notes = "new tune" })
  session.upsert(doc, { id = "a", range = { start = 0, stop = 100 }, label = "Choltice" })
  h.assert_eq(doc.sessions[1].venue, "Sokolovna")
  h.assert_eq(doc.sessions[1].notes, "new tune")
end

-- How many takes a session has

function T.recording_takes_stores_a_count_not_a_copy_of_them()
  -- The sidecar used to hold every take in full -- assets, paths, byte counts
  -- -- and every reader asked it only for the number.
  local sess = { id = "a" }
  session.record_takes(sess, { {}, {}, {} })
  h.assert_eq(sess.takeCount, 3)
  h.assert_eq(sess.takes, nil, "the copy is gone")
end

function T.recording_replaces_rather_than_accumulating()
  -- The bug: takes were matched by region GUID and appended, never dropped, so
  -- a region re-cut in REAPER left its old entry behind for good. One session
  -- reached 24 entries against 12 real takes.
  local sess = { id = "a" }
  session.record_takes(sess, { {}, {}, {} })
  session.record_takes(sess, { {}, {} })
  h.assert_eq(session.take_count(sess), 2)
end

function T.the_count_reads_back_from_a_sidecar_written_before_the_change()
  -- Old records carry the array and no count; they must not read as zero
  -- until the next render rewrites them.
  h.assert_eq(session.take_count({ takes = { {}, {}, {}, {} } }), 4)
end

function T.a_stored_count_wins_over_a_leftover_array()
  h.assert_eq(session.take_count({ takeCount = 2, takes = { {}, {}, {} } }), 2)
end

function T.a_session_with_neither_counts_zero()
  h.assert_eq(session.take_count({}), 0)
end

function T.the_markers_count_takes_the_same_way()
  local m = session.span_markers({
    label = "Nota", heldAt = "2025-07-30T19:00:00+02:00",
    range = { start = 0, stop = 10 }, takeCount = 12 })
  h.assert_eq(m[1].name:match("12 takes") ~= nil, true, m[1].name)
end

return T
