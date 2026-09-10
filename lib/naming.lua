-- lib/naming.lua
-- Region names: composing them, parsing them back, and numbering takes.
--
-- A region name is the only thing a person sees in REAPER's region manager, so
-- it is written for them: "Dub Corner - take 3". It is also the only place the
-- naming survives closing the project, so it has to parse back reliably --
-- otherwise reopening the panel means naming everything again.
--
-- The part after the song is a free label. It defaults to the take number but
-- can be replaced with a note: "Dub Corner - slow version". Downstream this is
-- one field either way, so a note costs nothing structurally.

local text = require("lib.util.text")

local M = {}

local SEPARATOR = " - "

-- Splits a name into song and label. When `songs` is given, the longest known
-- title that the name starts with wins -- that is what lets a song whose own
-- title contains " - " survive the round trip. Without the list, the last
-- separator is the boundary.
function M.parse(name, songs)
  if not name or name == "" then return nil end

  if songs then
    -- The boundary is found in the RAW string, never by slicing at the folded
    -- title's length. Folding is not length-preserving -- "ř" is two bytes and
    -- "r" is one -- so a region named PRITEL matching a title spelled Přítel
    -- would be cut short by one byte per accented character, silently turning
    -- "take 3" into "ke 3".
    local best_title, best_label
    for _, song in ipairs(songs) do
      local title = song.title or song
      local folded_title = text.fold(title)

      if text.fold(name) == folded_title then
        return title, nil
      end

      -- Try each real separator position and fold what precedes it.
      local from = 1
      while true do
        local at = name:find(SEPARATOR, from, true)
        if not at then break end
        if text.fold(name:sub(1, at - 1)) == folded_title then
          if not best_title or #title > #best_title then
            best_title, best_label = title, name:sub(at + #SEPARATOR)
          end
          break
        end
        from = at + 1
      end
    end
    if best_title then return best_title, best_label end
  end

  local last = nil
  local from = 1
  while true do
    local i = name:find(SEPARATOR, from, true)
    if not i then break end
    last = i
    from = i + 1
  end
  if not last then return nil end

  local song = name:sub(1, last - 1)
  local label = name:sub(last + #SEPARATOR)
  if song == "" or label == "" then return nil end
  return song, label
end

-- The take number a label carries, or nil when it is a note rather than a
-- number. "take 3", "Take 3" and the bracketed forms the downstream contract
-- normalises all count.
function M.take_number(label)
  if not label then return nil end
  local lowered = label:lower()
  local n = lowered:match("^take%s+(%d+)$")
    or lowered:match("^%(take%s+(%d+)%)$")
    or lowered:match("^%[take%s+(%d+)%]$")
  return n and tonumber(n) or nil
end

function M.default_label(take_no)
  return string.format("take %d", take_no)
end

function M.format(song, label)
  if not label or label == "" then return song end
  return song .. SEPARATOR .. label
end

-- Assigns take numbers per song in chronological order, and derives each row's
-- label.
--
-- Recomputed from scratch every time, never incremented: renaming one row
-- changes the numbering of two songs at once, and a counter that only goes up
-- gets it wrong the first time a name is corrected.
--
-- A row with its own `note` keeps it as the label but still consumes a take
-- number, so "slow version" does not make the next plain take number wrong.
function M.renumber(rows)
  local ordered = {}
  for i, row in ipairs(rows) do ordered[i] = { index = i, row = row } end
  table.sort(ordered, function(a, b)
    if a.row.start == b.row.start then return a.index < b.index end
    return a.row.start < b.row.start
  end)

  local counts = {}
  for _, entry in ipairs(ordered) do
    local row = entry.row
    if row.song and row.song ~= "" then
      local key = text.fold(row.song)
      counts[key] = (counts[key] or 0) + 1
      row.take_no = counts[key]
      row.label = (row.note and row.note ~= "") and row.note
        or M.default_label(row.take_no)
    else
      row.take_no = nil
      row.label = nil
    end
  end

  return rows
end

-- The folder one take's renders belong in, relative to the session's output
-- directory.
--
-- The GUID fragment is what makes it a take's OWN folder. Position alone --
-- the index in the render and the take number -- is not identity: render a
-- different time selection and a different region becomes take 1 at index 1,
-- landing on a folder another take already owns and overwriting its audio.
-- That is not hypothetical; it destroyed half the renders in two sessions
-- before this existed, and the manifest, which has always keyed takes by
-- region GUID, was left with two takes pointing at one folder.
--
-- The readable part stays first so the directory still sorts and reads the way
-- a person expects.
function M.take_folder(index, song, label, guid)
  local name = string.format("%02d-%s-%s", index, text.slug(song or ""), text.slug(label or ""))
  local hex = tostring(guid or ""):match("(%x%x%x%x%x%x%x%x)")
  if hex then name = name .. "-" .. hex:lower() end
  return (name:gsub("%-+", "-"):gsub("%-$", ""))
end

-- The name a row should carry in the project.
function M.region_name(row)
  if not row.song or row.song == "" then return nil end
  return M.format(row.song, row.label)
end

return M
