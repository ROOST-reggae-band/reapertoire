-- lib/util/time.lua
-- Clock formatting for timeline positions.
--
-- A project holding many rehearsals runs to tens of hours, where minutes-only
-- formatting produces "3482:35.62" -- technically correct and unreadable. Hours
-- appear when there are any and are omitted when there are not, so a take
-- forty seconds into a selection still reads as "0:40.00".

local M = {}

function M.hms(seconds)
  if not seconds then return "?" end

  local sign = ""
  if seconds < 0 then
    sign = "-"
    seconds = -seconds
  end

  local hours = math.floor(seconds / 3600)
  local minutes = math.floor((seconds - hours * 3600) / 60)
  local rest = seconds - hours * 3600 - minutes * 60

  if hours > 0 then
    return string.format("%s%d:%02d:%05.2f", sign, hours, minutes, rest)
  end
  return string.format("%s%d:%05.2f", sign, minutes, rest)
end

-- Durations read as a length, not a position: "4m 35s" rather than "4:35.00".
function M.duration(seconds)
  if not seconds then return "?" end
  local minutes = math.floor(seconds / 60)
  local rest = math.floor(seconds - minutes * 60 + 0.5)
  if rest == 60 then minutes, rest = minutes + 1, 0 end
  if minutes > 0 then
    return string.format("%dm %02ds", minutes, rest)
  end
  return string.format("%ds", rest)
end

return M
