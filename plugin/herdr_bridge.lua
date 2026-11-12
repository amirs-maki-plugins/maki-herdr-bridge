-- Entry point: maki runs every plugin/*.lua in a package at startup.
-- The module in lua/ does the real work; this file only loads it and
-- registers the spec command, because a package's lua/ dir is not on
-- the require path of the user's global config, so their /spec runner
-- cannot reach it.

require("herdr_bridge")

local function check()
  local c = {}
  local function fail(fmt, ...)
    error(string.format(fmt, ...))
  end
  function c.eq(actual, expected, msg)
    if actual ~= expected then
      fail("%s\nexpected: %s\n  actual: %s", msg or "", tostring(expected), tostring(actual))
    end
  end
  c.is = c.eq
  function c.has(s, substr, msg)
    if type(s) ~= "string" or not s:find(substr, 1, true) then
      fail("%s\nexpected to contain: %s\n  actual: %s", msg or "", tostring(substr), tostring(s))
    end
  end
  return c
end

maki.api.register_command({
  name = "/herdr-bridge-spec",
  description = "Run the herdr_bridge spec cases",
  handler = function()
    local spec = require("herdr_bridge_spec")
    local names = {}
    for n in pairs(spec.cases) do
      names[#names + 1] = n
    end
    table.sort(names)
    local passed, failed = 0, {}
    for _, n in ipairs(names) do
      local ok, err = pcall(spec.cases[n], check())
      if ok then
        passed = passed + 1
      else
        failed[#failed + 1] = n .. ": " .. tostring(err)
      end
    end
    if #failed == 0 then
      maki.ui.flash(string.format("/herdr-bridge-spec: %d cases passed", passed))
      maki.log.info(string.format("herdr_bridge spec: %d cases passed", passed))
      return
    end
    maki.ui.flash(string.format("/herdr-bridge-spec: %d passed, %d FAILED (see maki.log)", passed, #failed))
    for _, f in ipairs(failed) do
      maki.log.error("herdr_bridge spec " .. f)
    end
  end,
})
