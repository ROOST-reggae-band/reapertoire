-- lib/songs.lua
-- Access to the known-songs list.
--
-- Behind one function on purpose: this is a local JSON list today and becomes
-- a server call later, and nothing above this module should have to care.

local text = require("lib.util.text")

local M = {}

-- Normalises whatever the config carries into { title, aliases } records.
function M.load(cfg)
  local out = {}
  for _, entry in ipairs(cfg.songs or {}) do
    if type(entry) == "string" then
      out[#out + 1] = { title = entry, aliases = {} }
    elseif entry.title then
      out[#out + 1] = { title = entry.title, aliases = entry.aliases or {} }
    end
  end
  return out
end

-- Songs matching `query`, diacritic-insensitively, over titles and aliases.
--
-- Ranked so a title that starts with the query beats one that merely contains
-- it: typing "d" should offer Dezertér and Dívko before Čoudy, which only
-- contains a d in the middle.
function M.filter(songs, query)
  local folded = text.fold(query)
  if folded == "" then return songs end

  local starts, contains = {}, {}
  for _, song in ipairs(songs) do
    local title = text.fold(song.title)
    if title:sub(1, #folded) == folded then
      starts[#starts + 1] = song
    elseif title:find(folded, 1, true) then
      contains[#contains + 1] = song
    else
      local via_alias = false
      for _, alias in ipairs(song.aliases or {}) do
        if text.fold(alias):find(folded, 1, true) then via_alias = true break end
      end
      if via_alias then contains[#contains + 1] = song end
    end
  end

  for _, song in ipairs(contains) do starts[#starts + 1] = song end
  return starts
end

-- Appends a title, keeping the list unique on its folded form so the same song
-- typed twice with different accents does not become two songs.
function M.add(songs, title)
  local folded = text.fold(title)
  if folded == "" then return nil end
  for _, song in ipairs(songs) do
    if text.fold(song.title) == folded then return song end
  end
  local song = { title = title, aliases = {} }
  songs[#songs + 1] = song
  return song
end

return M
