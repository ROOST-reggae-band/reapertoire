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

function T.merging_takes_updates_by_client_ref_rather_than_duplicating()
  local s = sess("a", 0, 100)
  session.merge_takes(s, { { clientRef = "g1", start = 10, song = "One" } })
  session.merge_takes(s, { { clientRef = "g1", start = 10, song = "Corrected" } })
  h.assert_eq(#s.takes, 1, "re-rendering updates rather than appends")
  h.assert_eq(s.takes[1].song, "Corrected")
end

function T.merged_takes_stay_in_timeline_order()
  local s = sess("a", 0, 100)
  session.merge_takes(s, { { clientRef = "g2", start = 90 } })
  session.merge_takes(s, { { clientRef = "g1", start = 10 } })
  h.assert_eq(s.takes[1].clientRef, "g1")
  h.assert_eq(s.takes[2].clientRef, "g2")
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

return T
