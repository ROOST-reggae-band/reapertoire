-- lib/manifest.lua
-- Assembles the per-session manifest written beside the renders.
--
-- Shaped for a downstream ingest API: every field it needs is free to compute
-- here, where the audio and the project are both to hand, and expensive or
-- impossible to reconstruct later.

local M = {}

M.SCHEMA = 1

-- Region GUIDs are the stable identity: they survive a region being renamed,
-- moved or renumbered, which names and positions do not. Namespaced so a
-- consumer can tell where the reference came from.
function M.take_ref(region_guid)
  if not region_guid or region_guid == "" then return nil end
  return "reaper:region-guid:" .. region_guid
end

local function duration_ms(from, to)
  return math.floor((to - from) * 1000 + 0.5)
end

-- The event block: what the rehearsal IS, copied from the session record.
--
-- The sidecar owns these; the manifest carries a copy so it stays
-- self-contained -- `upload.py` needs no DAW, which is what lets a session be
-- pushed from anywhere. A copy is fine; a copy nothing can refresh is not,
-- which is why `refresh_event` exists beside it.
function M.event_of(session)
  return {
    clientRef = session.id,
    kind = session.kind or "rehearsal",
    heldAt = session.heldAt,
    label = session.label,
    venue = session.venue,
    notes = session.notes,
    -- Where the session starts on the project timeline. Take positions are
    -- absolute project seconds, so without this nothing downstream can turn
    -- one into a wall-clock time.
    rangeStart = session.range and session.range.start,
  }
end

-- Brings a manifest's event block back in line with the session record.
--
-- Editing a rehearsal's venue writes the sidecar, and the uploader reads the
-- manifest -- so without this the correction reached the library only after a
-- full re-render, hours of re-encoding audio that had not changed, to alter a
-- string. Rewritten wholesale rather than merged, so clearing a field clears
-- it here too.
--
-- Refuses a manifest belonging to a different session: `clientRef` is
-- identity, and rewriting somebody else's event block would relabel a whole
-- rehearsal. Returns whether it did anything.
function M.refresh_event(manifest, session)
  if type(manifest) ~= "table" or type(manifest.event) ~= "table" then return false end
  if manifest.event.clientRef and manifest.event.clientRef ~= session.id then
    return false
  end
  manifest.event = M.event_of(session)
  return true
end

-- take rows are { guid, start, stop, song, label, take_no, instruments, assets }
-- assets are { kind, instrument, format, path, bytes, sha256, sampleRate, channels }
function M.build(session, takes)
  local out = {
    schema = M.SCHEMA,
    event = M.event_of(session),
    takes = {},
  }

  for _, take in ipairs(takes) do
    local assets = {}
    for _, asset in ipairs(take.assets or {}) do
      assets[#assets + 1] = {
        kind = asset.kind,
        instrument = asset.instrument,
        tier = asset.tier or "lossy",
        format = asset.format,
        path = asset.path,
        bytes = asset.bytes,
        sha256 = asset.sha256,
        durationMs = asset.durationMs,
        sampleRate = asset.sampleRate,
        channels = asset.channels,
      }
    end

    out.takes[#out.takes + 1] = {
      clientRef = M.take_ref(take.guid),
      song = take.song,
      label = take.label,
      takeNo = take.take_no,
      start = take.start,
      durationMs = duration_ms(take.start, take.stop),
      instruments = take.instruments or {},
      assets = assets,
    }
  end

  table.sort(out.takes, function(a, b) return (a.start or 0) < (b.start or 0) end)
  return out
end

-- Merges freshly built takes into a manifest already on disk, matched on
-- clientRef.
--
-- Rendering part of a session must not drop the rest of it: the output folder
-- is per session, so a run covering takes 6-10 would otherwise overwrite the
-- manifest listing takes 1-5, orphaning their audio and quietly removing them
-- from the reference library on the next index.
--
-- `known_refs`, when given, is the set of clientRefs the project STILL has a
-- region for. Keeping an entry only means "not rendered this time", and on its
-- own that is indistinguishable from "the region is gone" -- so a take deleted
-- and re-cut in REAPER left its old entry behind for good, pointing at a
-- folder whose audio now belongs to whatever took its place, and refusing to
-- upload ever after. Pass nil where the full region set is not known and
-- nothing is dropped.
function M.merge(existing, fresh, known_refs)
  if type(existing) ~= "table" or type(existing.takes) ~= "table" then
    return fresh
  end

  local merged = {}
  local at = {}
  for _, take in ipairs(existing.takes) do
    -- An entry with no clientRef cannot be checked, so it is never dropped.
    local gone = known_refs and take.clientRef and not known_refs[take.clientRef]
    if not gone then
      merged[#merged + 1] = take
      if take.clientRef then at[take.clientRef] = #merged end
    end
  end
  for _, take in ipairs(fresh.takes) do
    local index = take.clientRef and at[take.clientRef]
    if index then
      merged[index] = take
    else
      merged[#merged + 1] = take
      if take.clientRef then at[take.clientRef] = #merged end
    end
  end

  table.sort(merged, function(a, b) return (a.start or 0) < (b.start or 0) end)
  fresh.takes = merged
  return fresh
end

-- Which of `dirs` no take in `manifest` has any file in.
--
-- Compared against the WHOLE manifest, never against one render's output:
-- rendering a two-take time selection inside a twelve-take session leaves the
-- other ten untouched, and their folders are still exactly where the manifest
-- says their audio lives. Judging by what was just rendered would delete them.
--
-- A directory is claimed if any asset path lies inside it, so a take folder is
-- kept by its own master as well as by the stems one level down.
function M.orphan_dirs(manifest, dirs)
  local claimed = {}
  for _, take in ipairs((manifest or {}).takes or {}) do
    for _, asset in ipairs(take.assets or {}) do
      if asset.path then claimed[#claimed + 1] = asset.path end
    end
  end

  local out = {}
  for _, dir in ipairs(dirs or {}) do
    local prefix = dir:gsub("/+$", "") .. "/"
    local used = false
    for _, path in ipairs(claimed) do
      if path:sub(1, #prefix) == prefix then used = true break end
    end
    if not used then out[#out + 1] = dir end
  end
  return out
end

-- Takes that cannot be sent downstream, with the reason. Reporting these beats
-- writing a manifest that fails validation somewhere else later.
function M.problems(manifest)
  local out = {}
  for i, take in ipairs(manifest.takes) do
    if not take.clientRef then
      out[#out + 1] = string.format("take %d has no region GUID to identify it by", i)
    end
    if not take.song or take.song == "" then
      out[#out + 1] = string.format("take %d has no song", i)
    end
    if #take.assets == 0 then
      out[#out + 1] = string.format("take %d rendered no files", i)
    end
    if take.durationMs and take.durationMs <= 0 then
      out[#out + 1] = string.format("take %d has no duration", i)
    end
  end
  if not manifest.event.clientRef then
    out[#out + 1] = "the session has no identifier"
  end
  if not manifest.event.heldAt then
    out[#out + 1] = "the session has no date"
  end
  return out
end

return M
