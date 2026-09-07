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

-- take rows are { guid, start, stop, song, label, take_no, instruments, assets }
-- assets are { kind, instrument, format, path, bytes, sha256, sampleRate, channels }
function M.build(session, takes)
  local out = {
    schema = M.SCHEMA,
    event = {
      clientRef = session.id,
      kind = session.kind or "rehearsal",
      heldAt = session.heldAt,
      label = session.label,
      venue = session.venue,
    },
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
