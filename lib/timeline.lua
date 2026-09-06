-- lib/timeline.lua
-- Builds the covered/uncovered structure of the timeline from item extents.
--
-- Detection only ever runs inside a covered span. An uncovered span is a hard
-- cut where the operator stopped and restarted; it is NOT silence, and reading
-- peaks across it would yield zeros indistinguishable from a quiet room.

local M = {}

-- items      array of { start = number, stop = number }, any order, may overlap
-- sel_start  selection start, seconds
-- sel_stop   selection stop, seconds
-- merge_gap  spans separated by at most this many seconds are joined; use a
--            small value (0.05) so item-edge artefacts merge but real
--            stop/start cuts do not
--
-- Returns an ascending, non-overlapping array of { start = , stop = }.
function M.covered_spans(items, sel_start, sel_stop, merge_gap)
  local clipped = {}
  for _, item in ipairs(items) do
    local s = math.max(item.start, sel_start)
    local e = math.min(item.stop, sel_stop)
    if e > s then
      clipped[#clipped + 1] = { start = s, stop = e }
    end
  end

  table.sort(clipped, function(a, b)
    if a.start == b.start then return a.stop < b.stop end
    return a.start < b.start
  end)

  local out = {}
  for _, span in ipairs(clipped) do
    local last = out[#out]
    if last and span.start - last.stop <= merge_gap then
      if span.stop > last.stop then last.stop = span.stop end
    else
      out[#out + 1] = { start = span.start, stop = span.stop }
    end
  end

  return out
end

return M
