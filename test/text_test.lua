local h = require("test.helpers")
local text = require("lib.util.text")

local T = {}

function T.folds_czech_diacritics()
  h.assert_eq(text.fold("Přítel"), "pritel")
  h.assert_eq(text.fold("Žluťoučký kůň"), "zlutoucky kun")
  h.assert_eq(text.fold("Ďábel"), "dabel")
end

function T.folding_is_case_insensitive()
  h.assert_eq(text.fold("DUB CORNER"), "dub corner")
end

function T.collapses_and_trims_whitespace()
  h.assert_eq(text.fold("  Dub   Corner  "), "dub corner")
end

function T.plain_ascii_is_unchanged_apart_from_case()
  h.assert_eq(text.fold("Dub Corner"), "dub corner")
end

function T.matching_works_in_both_directions()
  -- Typing without diacritics finds the accented title...
  h.assert_eq(text.matches("Přítel", "pritel"), true)
  -- ...and typing with them still works.
  h.assert_eq(text.matches("Přítel", "Pří"), true)
end

function T.matching_is_substring_not_prefix()
  h.assert_eq(text.matches("Dub Corner", "corner"), true)
end

function T.an_empty_query_matches_everything()
  h.assert_eq(text.matches("Anything", ""), true)
  h.assert_eq(text.matches("Anything", nil), true)
end

function T.a_query_that_is_absent_does_not_match()
  h.assert_eq(text.matches("Dub Corner", "reggae"), false)
end

function T.folding_nil_is_empty_not_an_error()
  h.assert_eq(text.fold(nil), "")
end

return T
