local h = require("test.helpers")
local songs_lib = require("lib.songs")

local T = {}

-- Generic stand-ins: the real repertoire lives in the gitignored config.
local function fixture()
  return songs_lib.load({ songs = {
    { title = "Ptáčci" },
    { title = "Dívko" },
    { title = "Dezertér" },
    { title = "Čoudy" },
    { title = "Long Title Here", aliases = { "LTH" } },
  } })
end

function T.load_normalises_bare_strings_and_records()
  local list = songs_lib.load({ songs = { "Plain", { title = "Rich", aliases = { "R" } } } })
  h.assert_eq(#list, 2)
  h.assert_eq(list[1].title, "Plain")
  h.assert_eq(#list[1].aliases, 0)
  h.assert_eq(list[2].aliases[1], "R")
end

function T.load_of_an_absent_list_is_empty_not_an_error()
  h.assert_eq(#songs_lib.load({}), 0)
end

function T.an_empty_query_returns_everything()
  h.assert_eq(#songs_lib.filter(fixture(), ""), 5)
end

function T.typing_without_diacritics_finds_the_accented_title()
  local hits = songs_lib.filter(fixture(), "ptacci")
  h.assert_eq(#hits, 1)
  h.assert_eq(hits[1].title, "Ptáčci")
end

function T.titles_starting_with_the_query_rank_above_ones_merely_containing_it()
  -- "d" starts Dívko and Dezertér; Čoudy only contains one.
  local hits = songs_lib.filter(fixture(), "d")
  h.assert_eq(#hits, 3)
  local first_two = hits[1].title .. "|" .. hits[2].title
  if first_two:find("Čoudy") then
    error("a merely-containing match outranked a prefix match: " .. first_two)
  end
  h.assert_eq(hits[3].title, "Čoudy")
end

function T.an_alias_finds_its_song()
  local hits = songs_lib.filter(fixture(), "lth")
  h.assert_eq(#hits, 1)
  h.assert_eq(hits[1].title, "Long Title Here")
end

function T.a_query_matching_nothing_returns_nothing()
  h.assert_eq(#songs_lib.filter(fixture(), "zzzz"), 0)
end

function T.add_appends_a_new_title()
  local list = fixture()
  local song = songs_lib.add(list, "Brand New")
  h.assert_eq(#list, 6)
  h.assert_eq(song.title, "Brand New")
end

function T.add_returns_the_existing_song_rather_than_duplicating()
  -- Typed once with accents and once without, it is still one song.
  local list = fixture()
  local song = songs_lib.add(list, "ptacci")
  h.assert_eq(#list, 5, "no duplicate added")
  h.assert_eq(song.title, "Ptáčci", "the existing record is returned")
end

function T.add_ignores_an_empty_title()
  local list = fixture()
  h.assert_eq(songs_lib.add(list, "   "), nil)
  h.assert_eq(#list, 5)
end

return T
