-- herdr_bridge_spec: pure-helper cases for the herdr_bridge plugin.
-- Run with /herdr-bridge-spec. No job is started; only the helpers run.

local hb = require("herdr_bridge")
local t = hb._test

local cases = {}

cases.state_maps_maki_statuses = function(check)
  check.eq(t.state_for("working"), "working")
  check.eq(t.state_for("needs_input"), "blocked", "a prompt is blocked in herdr")
  check.eq(t.state_for("idle"), "idle")
  check.eq(t.state_for("stored"), "idle", "a stored session waits for nobody")
end

cases.state_rejects_unknown = function(check)
  check.eq(t.state_for("done"), nil)
  check.eq(t.state_for(nil), nil)
end

cases.seq_is_clock_seeded = function(check)
  check.eq(t.next_seq(0, 1000), 1000000, "first report seeds from the clock")
end

cases.seq_never_repeats_inside_one_millisecond = function(check)
  local a = t.next_seq(0, 1700000000)
  local b = t.next_seq(a, 1700000000)
  local c = t.next_seq(b, 1700000000)
  check.is(b > a, true, "second report is higher")
  check.is(c > b, true, "third report is higher")
end

cases.seq_never_goes_backwards_when_the_clock_does = function(check)
  local seeded = t.next_seq(0, 1700000000)
  local skewed = t.next_seq(seeded, 1600000000)
  check.is(skewed > seeded, true, "a clock set back keeps the sequence rising")
end

cases.same_report_compares_both_fields = function(check)
  local last = { sid = "abc", state = "idle" }
  check.eq(t.same_report(last, "abc", "idle"), true)
  check.eq(t.same_report(last, "abc", "working"), false, "a new state is a new report")
  check.eq(t.same_report(last, "xyz", "idle"), false, "a new session is a new report")
  check.eq(t.same_report(nil, "abc", "idle"), false)
end

cases.title_trims_and_strips_control = function(check)
  check.eq(t.normalize_title("  refactor auth\n"), "refactor auth")
  check.eq(t.normalize_title("a\tb"), "a b")
end

cases.title_is_nil_when_empty = function(check)
  check.eq(t.normalize_title(""), nil)
  check.eq(t.normalize_title("   "), nil)
  check.eq(t.normalize_title(nil), nil)
  check.eq(t.normalize_title(7), nil)
end

cases.title_caps_at_eighty_cells = function(check)
  local long = t.normalize_title(string.rep("x", 200))
  check.eq(#long, 80, "herdr stores 80 characters at most")
end

cases.title_cap_keeps_utf8_whole = function(check)
  -- 41 two-byte characters: byte 80 lands on a continuation byte.
  local long = t.normalize_title(string.rep("\u{e9}", 60))
  check.eq(#long <= 80, true, "under the cap")
  local utf8 = rawget(_G, "utf8")
  if utf8 and utf8.len then
    check.is(utf8.len(long) ~= nil, true, "still valid UTF-8")
  end
end

cases.resume_argv_shape = function(check)
  local argv = t.report_argv("/bin/herdr", "w1:p3", "sess1", "blocked", 42)
  local joined = table.concat(argv, " ")
  check.eq(argv[1], "/bin/herdr")
  check.eq(argv[2], "pane")
  check.eq(argv[3], "report-agent")
  check.eq(argv[4], "w1:p3")
  check.has(joined, "--source maki-herdr ")
  check.has(joined, "--agent maki ")
  check.has(joined, "--state blocked")
  check.has(joined, "--seq 42")
  check.has(joined, "--agent-session-id sess1")
  check.has(joined, "-- maki-herdr-resume --herdr-restore sess1", "the resume command is the last argument group")
end

cases.resume_first_word_is_a_bare_name = function(check)
  local argv = t.report_argv("/bin/herdr", "w1:p3", "s", "idle", 1)
  local dash
  for i, a in ipairs(argv) do
    if a == "--" then
      dash = i
    end
  end
  check.eq(argv[dash + 1], "maki-herdr-resume", "herdr requires a plain command name on PATH")
  check.eq(argv[dash + 2], "--herdr-restore", "the marker lives in the first argument")
  check.eq(argv[dash + 3], "s", "then the session herdr types for the plugin to read")
end

cases.resume_line_is_the_reported_argv = function(check)
  local argv = t.report_argv("/bin/herdr", "w1:p3", "sess1", "idle", 1)
  local line = table.concat(argv, " ", #argv - 2)
  check.eq(line, "maki-herdr-resume --herdr-restore sess1", "herdr types exactly this line")
end

cases.restore_target_reads_the_whole_line_only = function(check)
  check.eq(t.restore_target(t.RESTORE_PREFIX .. "sess1"), "sess1")
  check.eq(t.restore_target(t.RESTORE_PREFIX .. "a.b-c_1"), "a.b-c_1")
  check.eq(t.restore_target("maki-herdr-resume --herdr-restore"), nil, "no session yet")
  check.eq(t.restore_target(t.RESTORE_PREFIX .. "sess1 "), nil, "trailing text is not the line")
  check.eq(t.restore_target(t.RESTORE_PREFIX .. "a/b"), nil, "a path is not a session id")
  check.eq(t.restore_target("maki --resume sess1"), nil, "another agent's command is not ours")
  check.eq(t.restore_target(nil), nil)
end

cases.restore_prefix_follows_the_line_character_by_character = function(check)
  check.eq(t.restore_prefix(""), true, "an empty composer can still become the line")
  check.eq(t.restore_prefix("maki-herdr"), true)
  check.eq(t.restore_prefix(t.RESTORE_PREFIX), true)
  check.eq(t.restore_prefix(t.RESTORE_PREFIX .. "sess"), true)
  check.eq(t.restore_prefix("maki herdr"), false, "typing something else disarms the handler")
  check.eq(t.restore_prefix(t.RESTORE_PREFIX .. "sess1 x"), false)
end

cases.metadata_argv_sets_title_and_token = function(check)
  local argv = t.metadata_argv("/bin/herdr", "w1:p3", "refactor auth", 7)
  local joined = table.concat(argv, " ")
  check.eq(argv[1], "/bin/herdr")
  check.eq(argv[2], "pane")
  check.eq(argv[3], "report-metadata")
  check.eq(argv[4], "w1:p3")
  check.has(joined, "--source maki-herdr-title ")
  check.has(joined, "--applies-to-source maki-herdr ")
  check.has(joined, "--agent maki ")
  check.has(joined, "--title refactor auth")
  check.has(joined, "--token session=refactor auth")
  check.eq(joined:find("%-%-state"), nil, "metadata never carries a state")
end

cases.metadata_argv_clears_a_missing_title = function(check)
  local argv = t.metadata_argv("/bin/herdr", "w1:p3", nil, 8)
  local joined = table.concat(argv, " ")
  check.has(joined, "--clear-title")
  check.has(joined, "--clear-token session")
  check.eq(joined:find("%-%-title"), nil)
  check.eq(joined:find("%-%-token session="), nil)
end

cases.metadata_argv_carries_the_directory = function(check)
  local argv = t.metadata_argv("/bin/herdr", "w1:p3", "refactor auth", 9, "maki")
  local joined = table.concat(argv, " ")
  check.has(joined, "--token dir=maki")
  check.has(joined, "--clear-display-agent")
  check.eq(joined:find("%-%-display%-agent"), nil, "no display name is set")
end

cases.metadata_argv_clears_a_missing_directory = function(check)
  local argv = t.metadata_argv("/bin/herdr", "w1:p3", "refactor auth", 10, nil)
  local joined = table.concat(argv, " ")
  check.has(joined, "--clear-token dir")
  check.eq(joined:find("%-%-token dir="), nil)
end

return { name = "herdr_bridge", cases = cases }
