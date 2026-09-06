local M = {}

local function fail(msg)
  error(msg, 3)
end

function M.assert_eq(actual, expected, label)
  if actual ~= expected then
    fail(string.format("%s: expected %s, got %s",
      label or "assert_eq", tostring(expected), tostring(actual)))
  end
end

function M.assert_near(actual, expected, tol, label)
  tol = tol or 1e-6
  if type(actual) ~= "number" or math.abs(actual - expected) > tol then
    fail(string.format("%s: expected %s (+/-%s), got %s",
      label or "assert_near", tostring(expected), tostring(tol), tostring(actual)))
  end
end

-- Compares arrays of { start = , stop = } within a tolerance.
function M.assert_spans(actual, expected, label)
  label = label or "assert_spans"
  if #actual ~= #expected then
    local got = {}
    for _, s in ipairs(actual) do
      got[#got + 1] = string.format("[%.3f,%.3f]", s.start, s.stop)
    end
    fail(string.format("%s: expected %d spans, got %d: %s",
      label, #expected, #actual, table.concat(got, " ")))
  end
  for i, want in ipairs(expected) do
    M.assert_near(actual[i].start, want.start, 1e-6,
      string.format("%s[%d].start", label, i))
    M.assert_near(actual[i].stop, want.stop, 1e-6,
      string.format("%s[%d].stop", label, i))
  end
end

return M
