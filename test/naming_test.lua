local h = require("test.helpers")
local naming = require("lib.naming")

local T = {}

local SONGS = {
  { title = "Dub Corner" }, { title = "Skank" },
  { title = "Přítel" }, { title = "Take It Easy" },
  { title = "Stop - Start" },
}

function T.parses_the_form_it_writes()
  local song, label = naming.parse("Dub Corner - take 3", SONGS)
  h.assert_eq(song, "Dub Corner")
  h.assert_eq(label, "take 3")
  h.assert_eq(naming.take_number(label), 3)
end

function T.a_note_round_trips_as_the_label()
  local name = naming.format("Dub Corner", "slow version")
  h.assert_eq(name, "Dub Corner - slow version")
  local song, label = naming.parse(name, SONGS)
  h.assert_eq(song, "Dub Corner")
  h.assert_eq(label, "slow version")
  h.assert_eq(naming.take_number(label), nil, "a note is not a take number")
end

function T.take_number_accepts_the_forms_the_contract_normalises()
  h.assert_eq(naming.take_number("take 3"), 3)
  h.assert_eq(naming.take_number("Take 12"), 12)
  h.assert_eq(naming.take_number("(take 3)"), 3)
  h.assert_eq(naming.take_number("[take 12]"), 12)
  h.assert_eq(naming.take_number("takeaway"), nil)
end

function T.diacritics_survive_the_round_trip()
  local name = naming.format("Přítel", "take 4")
  local song, label = naming.parse(name, SONGS)
  h.assert_eq(song, "Přítel")
  h.assert_eq(label, "take 4")
end

function T.a_song_whose_title_contains_the_separator_still_parses()
  -- Splitting on the last separator would yield "Stop" here; matching against
  -- the known titles is what keeps it whole.
  local song, label = naming.parse("Stop - Start - take 2", SONGS)
  h.assert_eq(song, "Stop - Start")
  h.assert_eq(label, "take 2")
end

function T.a_song_whose_title_contains_take_still_parses()
  local song, label = naming.parse("Take It Easy - take 2", SONGS)
  h.assert_eq(song, "Take It Easy")
  h.assert_eq(label, "take 2")
end

function T.a_bare_song_title_parses_with_no_label()
  local song, label = naming.parse("Dub Corner", SONGS)
  h.assert_eq(song, "Dub Corner")
  h.assert_eq(label, nil)
end

function T.parsing_falls_back_to_the_last_separator_without_a_song_list()
  local song, label = naming.parse("Some Unknown Tune - take 1")
  h.assert_eq(song, "Some Unknown Tune")
  h.assert_eq(label, "take 1")
end

function T.an_unnamed_region_does_not_parse()
  h.assert_eq(naming.parse("Take 1", SONGS), nil)
  h.assert_eq(naming.parse("Intro", SONGS), nil)
  h.assert_eq(naming.parse("", SONGS), nil)
  h.assert_eq(naming.parse(nil, SONGS), nil)
end

function T.numbers_takes_per_song_in_chronological_order()
  local rows = {
    { start = 10, song = "Dub Corner" },
    { start = 20, song = "Skank" },
    { start = 30, song = "Dub Corner" },
  }
  naming.renumber(rows)
  h.assert_eq(rows[1].label, "take 1")
  h.assert_eq(rows[2].label, "take 1")
  h.assert_eq(rows[3].label, "take 2")
end

function T.numbering_follows_time_not_list_order()
  local rows = {
    { start = 90, song = "Dub Corner" },
    { start = 10, song = "Dub Corner" },
  }
  naming.renumber(rows)
  h.assert_eq(rows[1].take_no, 2)
  h.assert_eq(rows[2].take_no, 1)
end

function T.renumbering_is_recomputed_not_incremented()
  local rows = {
    { start = 10, song = "Dub Corner" },
    { start = 20, song = "Dub Corner" },
    { start = 30, song = "Dub Corner" },
  }
  naming.renumber(rows)
  h.assert_eq(rows[2].take_no, 2)

  rows[2].song = "Skank"
  naming.renumber(rows)
  h.assert_eq(rows[1].take_no, 1)
  h.assert_eq(rows[2].take_no, 1, "Skank starts its own count")
  h.assert_eq(rows[3].take_no, 2, "the third row becomes Dub Corner take 2")
end

function T.a_note_replaces_the_label_but_still_consumes_a_take_number()
  -- Otherwise the take after a noted one would reuse its number.
  local rows = {
    { start = 10, song = "Dub Corner" },
    { start = 20, song = "Dub Corner", note = "slow version" },
    { start = 30, song = "Dub Corner" },
  }
  naming.renumber(rows)
  h.assert_eq(rows[1].label, "take 1")
  h.assert_eq(rows[2].label, "slow version")
  h.assert_eq(rows[2].take_no, 2, "still counted")
  h.assert_eq(rows[3].label, "take 3")
end

function T.unnamed_rows_get_no_label_and_do_not_consume_a_number()
  local rows = {
    { start = 10, song = "Dub Corner" },
    { start = 20, song = nil },
    { start = 30, song = "Dub Corner" },
  }
  naming.renumber(rows)
  h.assert_eq(rows[2].label, nil)
  h.assert_eq(rows[3].take_no, 2)
end

function T.songs_differing_only_by_diacritics_share_a_count()
  local rows = {
    { start = 10, song = "Přítel" },
    { start = 20, song = "Pritel" },
  }
  naming.renumber(rows)
  h.assert_eq(rows[2].take_no, 2)
end

function T.region_name_composes_song_and_label()
  local rows = { { start = 10, song = "Dub Corner" } }
  naming.renumber(rows)
  h.assert_eq(naming.region_name(rows[1]), "Dub Corner - take 1")
end

function T.an_unnamed_row_has_no_region_name()
  h.assert_eq(naming.region_name({ start = 10 }), nil)
end

function T.a_region_spelled_without_diacritics_keeps_its_whole_label()
  -- The boundary must be found in the raw string. Slicing at the folded
  -- title's byte length loses one byte per accented character, which turned
  -- "take 3" into "ke 3" and then wrote that back into the project.
  local song, label = naming.parse("PRITEL - take 3", SONGS)
  h.assert_eq(song, "Přítel")
  h.assert_eq(label, "take 3")
  h.assert_eq(naming.take_number(label), 3)
end

function T.a_note_survives_a_title_spelled_without_diacritics()
  local song, label = naming.parse("Pritel - slow version", SONGS)
  h.assert_eq(song, "Přítel")
  h.assert_eq(label, "slow version")
end

-- Take folders

function T.a_take_folder_carries_the_regions_own_identity()
  local a = naming.take_folder(1, "Roost rád mám", "take 1",
    "{9C6799CD-AACF-2B42-8AB8-7D869CAF5F2A}")
  h.assert_eq(a, "01-roost-rad-mam-take-1-9c6799cd")
end

function T.two_takes_at_the_same_position_do_not_share_a_folder()
  -- The bug this exists for: a different time selection makes a different
  -- region take 1 at index 1, and it overwrote the other take's audio.
  local a = naming.take_folder(1, "Čoudy", "take 1", "{9C6799CD-AACF-2B42-8AB8-7D869CAF5F2A}")
  local b = naming.take_folder(1, "Čoudy", "take 1", "{D5E2FF98-BB7C-744F-9C78-0FAF43AC35E0}")
  h.assert_eq(a ~= b, true, "same folder for two regions")
end

function T.the_same_region_always_lands_in_the_same_folder()
  local guid = "{9C6799CD-AACF-2B42-8AB8-7D869CAF5F2A}"
  h.assert_eq(naming.take_folder(3, "Boj", "take 2", guid),
              naming.take_folder(3, "Boj", "take 2", guid))
end

function T.a_take_with_no_guid_still_gets_a_usable_folder()
  -- Region GUIDs are unavailable on some REAPER builds; the name degrades to
  -- what it was rather than becoming nil.
  h.assert_eq(naming.take_folder(2, "Dívko", "take 4", nil), "02-divko-take-4")
  h.assert_eq(naming.take_folder(2, "Dívko", "take 4", ""), "02-divko-take-4")
end

function T.a_take_with_no_note_has_no_trailing_separator()
  h.assert_eq(naming.take_folder(7, "Boj", "", "{ABCDEF01-0000-0000-0000-000000000000}"),
              "07-boj-abcdef01")
end

return T
