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

local function overlaps(a_start, a_stop, b_start, b_stop)
  return a_start < b_stop and b_start < a_stop
end

-- Which session a time range belongs to.
--
-- Returns the session and "existing", or nil and "new" when nothing overlaps,
-- or nil and "ambiguous" plus the candidates when the range spans two. Guessing
-- between two rehearsals would file takes under the wrong date, so it refuses.
function M.find(doc, range_start, range_stop)
  local hits = {}
  for _, session in ipairs(doc.sessions) do
    local r = session.range
    if r and overlaps(range_start, range_stop, r.start, r.stop) then
      hits[#hits + 1] = session
    end
  end
  if #hits == 0 then return nil, "new" end
  if #hits > 1 then return nil, "ambiguous", hits end
  return hits[1], "existing"
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
  for _, key in ipairs({ "label", "kind", "heldAt", "outputDir" }) do
    if session[key] ~= nil then existing[key] = session[key] end
  end
  return existing, false
end

-- Folder name for a session: the date it was held plus its label, so the
-- directory sorts chronologically and reads as what it is.
function M.folder_name(session)
  local date = (session.heldAt or ""):match("^(%d%d%d%d%-%d%d%-%d%d)") or "undated"
  local slug = text.slug(session.label or "session")
  if slug == "" then slug = "session" end
  return date .. "-" .. slug
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
