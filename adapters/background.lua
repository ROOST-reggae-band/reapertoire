-- adapters/background.lua
-- Runs a long command without freezing REAPER, and reports its output as it
-- arrives.
--
-- REAPER is single-threaded. `io.popen` with `read("*a")` waits for the
-- process to exit, so the whole DAW sat frozen for the length of an upload or
-- a reindex -- minutes at a time, unable even to move its own window -- and
-- every line of output landed at once, after it no longer told anyone
-- anything.
--
-- Instead the command is detached, its output redirected to a file, and the
-- file tailed from `reaper.defer`. Deferred rather than looped: a loop here
-- would block the UI exactly as `read("*a")` did.

local M = {}

-- Marks the end of the output and carries the exit status. A sentinel rather
-- than watching for the process to disappear: knowing WHETHER it succeeded
-- needs its status, and a detached process cannot be waited on.
local SENTINEL = "__reapertoire_done "

-- Single-quoted, the only quoting /bin/sh guarantees: everything inside is
-- literal, and an embedded quote is closed, escaped and reopened. Lua's %q is
-- Lua's escaping, not the shell's, and differs on exactly the characters a
-- path is most likely to contain.
function M.quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

-- Runs `command` (already quoted by the caller), writing its output to
-- `log_path`.
--
-- `on_output(text)` is called with each new chunk as it appears, and
-- `on_finish(ok, exit_code)` once, when the command is done. Returns
-- immediately; the work happens in deferred callbacks.
function M.run(command, log_path, on_output, on_finish)
  os.remove(log_path)

  local shell = string.format("%s >%s 2>&1; echo %s$? >>%s",
    command, M.quote(log_path), M.quote(SENTINEL), M.quote(log_path))
  -- REAPER does not inherit a login shell, so this runs through one; `&`
  -- detaches it so os.execute returns straight away.
  os.execute(string.format("/bin/sh -lc %s &", M.quote(shell)))

  local shown = 0
  local function poll()
    local handle = io.open(log_path, "r")
    if handle then
      handle:seek("set", shown)
      local fresh = handle:read("*a") or ""
      handle:close()
      if #fresh > 0 then
        shown = shown + #fresh
        local code = fresh:match(SENTINEL .. "(%d+)")
        if code then
          -- The sentinel is ours, not the command's; it never reaches the
          -- caller's output.
          fresh = fresh:gsub(SENTINEL .. "%d+%s*", "")
        end
        if #fresh > 0 and on_output then on_output(fresh) end
        if code then
          if on_finish then on_finish(code == "0", tonumber(code)) end
          return
        end
      end
    end
    reaper.defer(poll)
  end

  poll()
end

return M
