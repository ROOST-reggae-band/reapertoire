-- lib/report.lua
-- Renders the dry-run report. Written to both the REAPER console and a file so
-- two threshold settings can be diffed rather than compared by screenshot.

local time = require("lib.util.time")

local M = {}

local mmss = time.hms

function M.render(data)
  local out = {}
  local function line(fmt, ...)
    out[#out + 1] = select("#", ...) > 0 and string.format(fmt, ...) or fmt
  end

  line("Reapertoire dry run")
  line("Selection: %s to %s (%s) at %d Hz",
    mmss(data.sel_start), mmss(data.sel_stop),
    time.duration(data.sel_stop - data.sel_start), data.rate)
  line("Thresholds: minGapSec=%.1f minTakeSec=%.1f",
    data.opts.minGapSec, data.opts.minTakeSec)
  line("")

  line("Tracks")
  for _, t in ipairs(data.tracks) do
    if t.live then
      line("  %-16s live         floor %.1f dB, active %.1f%%%s",
        t.name, t.floor_db or 0, (t.active_fraction or 0) * 100,
        t.slug and "" or "   [UNMAPPED]")
    else
      line("  %-16s not present  floor %s dB",
        t.name, t.floor_db and string.format("%.1f", t.floor_db) or "n/a")
    end
  end
  line("")

  line("Timeline: %d covered span%s", #data.covered_spans,
    #data.covered_spans == 1 and "" or "s")
  for i, span in ipairs(data.covered_spans) do
    local n = 0
    for _, take in ipairs(data.takes) do
      if take.span_index == i then n = n + 1 end
    end
    line("  span %d  %s - %s (%s)  %d take%s%s",
      i, mmss(span.start), mmss(span.stop), time.duration(span.stop - span.start),
      n, n == 1 and "" or "s",
      n > 1 and "  [subdivided]" or "")
  end
  line("")

  if #data.takes == 0 then
    line("No takes detected. Lower minTakeSec or gapThresholdDb and re-run.")
  else
    line("Takes")
    for i, take in ipairs(data.takes) do
      line("  %2d  %s - %s  %8s  span %d  %s",
        i, mmss(take.start), mmss(take.stop), time.duration(take.stop - take.start),
        take.span_index, table.concat(take.instruments, ", "))
    end
  end

  if #data.warnings > 0 then
    line("")
    line("Warnings")
    for _, w in ipairs(data.warnings) do line("  %s", w) end
  end

  return table.concat(out, "\n") .. "\n"
end

return M
