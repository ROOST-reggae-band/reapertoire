-- lib/session.lua
-- The sidecar that records which rehearsals live in this project.
--
-- One REAPER project holds many rehearsals, appended along the timeline, so a
-- session is identified by the time range it occupies. Re-running over the same
-- range must converge on the same session rather than creating a second one --
-- that is what makes re-rendering idempotent, and what lets a stable identifier
-- be handed downstream.

local json = require("lib.util.json")
local text = require("lib.util.text")

local M = {}

M.SCHEMA = 1
M.FILENAME = ".session-metadata.json"

function M.empty()
  return { schema = M.SCHEMA, sessions = {} }
end

function M.decode(raw)
  if not raw or raw == "" then return M.empty() end
  local parsed = json.decode(raw)
  if type(parsed) ~= "table" or type(parsed.sessions) ~= "table" then
    return M.empty()
  end
  parsed.schema = parsed.schema or M.SCHEMA
  return parsed
end

function M.encode(doc)
  return json.encode(doc, { indent = true })
end

local function overlap_seconds(a_start, a_stop, b_start, b_stop)
  local from = math.max(a_start, b_start)
  local to = math.min(a_stop, b_stop)
  return math.max(0, to - from)
end

-- How much of the shorter span the two share. Comparing against the shorter one
-- means a short selection inside a long session still counts as that session,
-- which is the common case when re-rendering part of a rehearsal.
local function overlap_ratio(a_start, a_stop, b_start, b_stop)
  local shared = overlap_seconds(a_start, a_stop, b_start, b_stop)
  if shared <= 0 then return 0 end
  local shortest = math.min(a_stop - a_start, b_stop - b_start)
  if shortest <= 0 then return 0 end
  return shared / shortest
end

-- Below this, a selection touching a session is treated as a different
-- rehearsal that happens to abut it, not the same one. Rehearsals sit end to
-- end on the timeline, so a few seconds of overlap is a near miss rather than
-- a match, and silently filing takes under the neighbouring session is worse
-- than asking.
M.MATCH_RATIO = 0.5

-- Which session a time range belongs to.
--
-- Returns the session and "existing", or nil and "new" when nothing overlaps,
-- or nil and "ambiguous" plus the candidates when the range spans two. Guessing
-- between two rehearsals would file takes under the wrong date, so it refuses.
-- Returns the session and "existing"; nil and "new" when nothing overlaps
-- substantially; nil and "ambiguous" plus candidates when two sessions match;
-- or nil and "partial" plus candidates when a session is touched but not
-- substantially, which needs a person rather than a guess.
function M.find(doc, range_start, range_stop)
  local hits, grazed = {}, {}
  for _, session in ipairs(doc.sessions) do
    local r = session.range
    if r then
      local ratio = overlap_ratio(range_start, range_stop, r.start, r.stop)
      if ratio >= M.MATCH_RATIO then
        hits[#hits + 1] = session
      elseif ratio > 0 then
        grazed[#grazed + 1] = session
      end
    end
  end
  if #hits > 1 then return nil, "ambiguous", hits end
  if #hits == 1 then return hits[1], "existing" end
  if #grazed > 0 then return nil, "partial", grazed end
  return nil, "new"
end

-- Records a session, widening its range if the new one reaches further. The
-- range only ever grows: selecting more of the same rehearsal is still that
-- rehearsal, and shrinking it would orphan takes already rendered.
function M.upsert(doc, session)
  local existing = M.find(doc, session.range.start, session.range.stop)
  if not existing then
    doc.sessions[#doc.sessions + 1] = session
    return session, true
  end
  existing.range.start = math.min(existing.range.start, session.range.start)
  existing.range.stop = math.max(existing.range.stop, session.range.stop)
  -- Venue and notes included: they exist only because somebody typed them,
  -- and leaving them out meant the next render silently threw them away.
  for _, key in ipairs({ "label", "kind", "heldAt", "outputDir", "venue", "notes" }) do
    if session[key] ~= nil then existing[key] = session[key] end
  end
  return existing, false
end

M.KINDS = { "rehearsal", "concert", "session" }

local function is_kind(value)
  for _, kind in ipairs(M.KINDS) do
    if value == kind then return true end
  end
  return false
end

local function trimmed(value)
  return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Applies edited metadata to a session, returning a list of problems.
--
-- All or nothing: a bad date leaves the label alone too. Half-applying an edit
-- is worse than refusing it, because the panel would then show some fields
-- saved and some not with no way to tell which.
--
-- Only the keys present in `fields` are touched, so the panel can send what it
-- has without spelling out the rest.
function M.update(session, fields)
  local problems = {}
  local date, held

  if fields.date ~= nil then
    date = trimmed(fields.date)
    if not date:match("^%d%d%d%d%-%d%d%-%d%d$") then
      problems[#problems + 1] =
        string.format("the date %q is not YYYY-MM-DD", tostring(fields.date))
    else
      -- Rebuilt from the date plus the time already stored, so editing the day
      -- does not silently move the rehearsal to midnight -- and put back
      -- through `with_offset`, because the ingest contract rejects a timestamp
      -- carrying no UTC offset.
      local time_of_day = (session.heldAt or ""):match("T(%d%d:%d%d)") or "00:00"
      held = M.with_offset(M.iso8601(date, time_of_day))
    end
  end

  if fields.kind ~= nil and not is_kind(trimmed(fields.kind)) then
    problems[#problems + 1] = string.format("the kind %q is none of %s",
      tostring(fields.kind), table.concat(M.KINDS, ", "))
  end

  if fields.label ~= nil and trimmed(fields.label) == "" then
    problems[#problems + 1] = "a session needs a label -- it names its output folder"
  end

  if #problems > 0 then return problems end

  if held then session.heldAt = held end
  if fields.kind ~= nil then session.kind = trimmed(fields.kind) end
  if fields.label ~= nil then session.label = trimmed(fields.label) end
  -- Blank means absent, not empty: both are nullable server-side but
  -- min-length-1 where present, so "" is rejected and nil is not.
  for _, key in ipairs({ "venue", "notes" }) do
    if fields[key] ~= nil then
      local value = trimmed(fields[key])
      session[key] = value ~= "" and value or nil
    end
  end

  return problems
end

-- Drops a session record. Returns whether one went.
--
-- The record only: the rendered audio and its manifest are left exactly where
-- they are, because deleting a row in a sidecar should never cost anybody a
-- rehearsal.
function M.remove(doc, id)
  for index, session in ipairs(doc.sessions or {}) do
    if session.id == id then
      table.remove(doc.sessions, index)
      return true
    end
  end
  return false
end

-- Folder name for a session: the date it was held plus its label, so the
-- directory sorts chronologically and reads as what it is.
function M.folder_name(session)
  local date = (session.heldAt or ""):match("^(%d%d%d%d%-%d%d%-%d%d)") or "undated"
  local slug = text.slug(session.label or "session")
  if slug == "" then slug = "session" end
  return date .. "-" .. slug
end

-- The two markers that delimit a session on the timeline.
--
-- Markers, not regions: the region lane already carries one per take, and a
-- second kind of region interleaved with those makes the lane unreadable.
-- Markers live in their own lane, REAPER draws them as gridlines down the
-- arrange view, and nothing that reads regions or media items can mistake one
-- for a take.
--
-- Two of them rather than one, because rehearsals are not contiguous -- two on
-- the same evening can sit minutes apart -- so a single marker per session
-- would leave the gap between them looking like part of the previous one.
function M.span_markers(session)
  local range = session.range or {}
  if not range.start or not range.stop then return {} end

  local date = (session.heldAt or ""):match("^(%d%d%d%d%-%d%d%-%d%d)") or "undated"
  local label = session.label
  if not label or label == "" then label = "rehearsal" end

  local count = #(session.takes or {})
  local takes
  if count == 0 then
    -- Distinguishes a rehearsal nobody has rendered from one that rendered
    -- nothing, which "0 takes" would not.
    takes = "not rendered"
  else
    takes = string.format("%d take%s", count, count == 1 and "" or "s")
  end

  return {
    { at = range.start, name = string.format("\u{25B6} %s %s - %s", date, label, takes) },
    { at = range.stop, name = string.format("\u{25C0} %s ends", label) },
  }
end

-- Merges freshly rendered takes into a session, matched on the region GUID so
-- a re-render updates a take rather than duplicating it.
function M.merge_takes(session, takes)
  session.takes = session.takes or {}
  local by_ref = {}
  for i, existing in ipairs(session.takes) do
    if existing.clientRef then by_ref[existing.clientRef] = i end
  end
  for _, take in ipairs(takes) do
    local at = take.clientRef and by_ref[take.clientRef]
    if at then
      session.takes[at] = take
    else
      session.takes[#session.takes + 1] = take
      if take.clientRef then by_ref[take.clientRef] = #session.takes end
    end
  end
  table.sort(session.takes, function(a, b) return (a.start or 0) < (b.start or 0) end)
  return session.takes
end

-- Recording date from a source filename.
--
-- REAPER's recorded filenames carry YYMMDD_HHMM, which is a better date source
-- than the file's mtime: it survives the file being copied, moved between
-- drives, or restored from a backup, all of which reset mtime.
function M.date_from_filename(name)
  if not name then return nil end
  local base = name:match("([^/\\]+)$") or name
  local y, mo, d, hh, mm = base:match("(%d%d)(%d%d)(%d%d)_(%d%d)(%d%d)")
  if not y then return nil end
  local year = 2000 + tonumber(y)
  local month, day = tonumber(mo), tonumber(d)
  local hour, minute = tonumber(hh), tonumber(mm)
  if month < 1 or month > 12 or day < 1 or day > 31
    or hour > 23 or minute > 59 then
    return nil
  end
  return string.format("%04d-%02d-%02d", year, month, day),
         string.format("%02d:%02d", hour, minute)
end

-- Whether a stored timestamp already carries a UTC offset.
function M.has_offset(stamp)
  if not stamp then return false end
  return stamp:match("[+%-]%d%d:%d%d$") ~= nil or stamp:match("Z$") ~= nil
end

-- Adds an offset to a timestamp written before offsets were recorded, reading
-- the date and time already stored rather than inventing new ones.
function M.with_offset(stamp)
  if not stamp or M.has_offset(stamp) then return stamp end
  local date, time_of_day = stamp:match("^(%d%d%d%d%-%d%d%-%d%d)T(%d%d:%d%d)")
  if not date then return stamp end
  return M.iso8601(date, time_of_day) or stamp
end

-- ISO-8601 with an offset, which the ingest contract requires: without one the
-- server cannot know what instant "20:48" meant. The offset is asked of the
-- session's own date rather than today's, so a summer rehearsal filed in winter
-- still carries the offset that was in force when it happened.
function M.iso8601(date, time_of_day)
  if not date then return nil end
  local y, mo, d = date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not y then return nil end
  local hh, mm = (time_of_day or "00:00"):match("^(%d%d):(%d%d)$")
  hh, mm = hh or "00", mm or "00"

  local at = os.time({
    year = tonumber(y), month = tonumber(mo), day = tonumber(d),
    hour = tonumber(hh), min = tonumber(mm), sec = 0,
  })
  if not at then return nil end

  -- %z reports the offset in force at that instant, DST included. Deriving it
  -- by round-tripping through os.date("!*t") and os.time loses the DST flag and
  -- reports standard time all year.
  local sign, oh, om = tostring(os.date("%z", at)):match("^([+%-])(%d%d)(%d%d)$")
  local offset = sign and (sign .. oh .. ":" .. om) or "+00:00"

  return string.format("%s-%s-%sT%s:%s:00%s", y, mo, d, hh, mm, offset)
end

return M
