-- lib/util/text.lua
-- Text folding for song search.
--
-- Czech diacritics are multi-byte in UTF-8, so `string.lower` and byte-wise
-- patterns cannot fold them. Typing "pritel" must find "Přítel", because that
-- is what a person types when naming twenty takes quickly.

local M = {}

local FOLD = {
  ["á"]="a",["č"]="c",["ď"]="d",["é"]="e",["ě"]="e",["í"]="i",["ň"]="n",
  ["ó"]="o",["ř"]="r",["š"]="s",["ť"]="t",["ú"]="u",["ů"]="u",["ý"]="y",["ž"]="z",
  ["Á"]="a",["Č"]="c",["Ď"]="d",["É"]="e",["Ě"]="e",["Í"]="i",["Ň"]="n",
  ["Ó"]="o",["Ř"]="r",["Š"]="s",["Ť"]="t",["Ú"]="u",["Ů"]="u",["Ý"]="y",["Ž"]="z",
  -- Common non-Czech accents, so an imported title still matches.
  ["à"]="a",["â"]="a",["ä"]="a",["è"]="e",["ê"]="e",["ë"]="e",["î"]="i",
  ["ï"]="i",["ô"]="o",["ö"]="o",["ù"]="u",["û"]="u",["ü"]="u",["ñ"]="n",["ç"]="c",
}

-- Lowercased, diacritics stripped, whitespace collapsed. Used for both sides of
-- every comparison, never for display.
function M.fold(s)
  if not s then return "" end
  local folded = s:gsub("[\xC0-\xFF][\x80-\xBF]*", function(ch)
    return FOLD[ch] or ch
  end)
  folded = folded:lower():gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
  return folded
end

-- Does `needle` appear in `haystack`, both folded? An empty needle matches.
function M.matches(haystack, needle)
  if not needle or needle == "" then return true end
  -- A filesystem-safe slug.
--
-- Folding comes first and is not optional: %w is byte-wise, so a multi-byte
-- character is not a word character and gets stripped rather than transliterated
-- -- turning "Ptáčci" into "pt-ci" instead of "ptacci".
function M.slug(s)
  local folded = M.fold(s)
  local out = folded:gsub("[^%w]+", "-"):gsub("%-+", "-")
  out = out:gsub("^%-", ""):gsub("%-$", "")
  return out
end

return M.fold(haystack):find(M.fold(needle), 1, true) ~= nil
end

-- A filesystem-safe slug.
--
-- Folding comes first and is not optional: %w is byte-wise, so a multi-byte
-- character is not a word character and gets stripped rather than transliterated
-- -- turning "Ptáčci" into "pt-ci" instead of "ptacci".
function M.slug(s)
  local folded = M.fold(s)
  local out = folded:gsub("[^%w]+", "-"):gsub("%-+", "-")
  out = out:gsub("^%-", ""):gsub("%-$", "")
  return out
end

return M
