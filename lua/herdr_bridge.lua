-- Report this maki instance to Herdr: lifecycle state, session identity, the
-- resume command, and the session title for the sidebar. Loaded from init.lua.
-- Does nothing outside a Herdr pane.
--
-- Herdr has no bundled maki integration, so this plugin is the integration.
-- It uses the documented protocol, in two separate calls that never share
-- authority:
--   herdr pane report-agent <pane> --source maki-herdr ...
--     --agent-session-id <id> -- maki --resume <id>
--   herdr pane report-metadata <pane> --source maki-herdr-title
--     --applies-to-source maki-herdr --title <title> --token session=<title>

local uv = maki.uv
local fn = maki.fn

-- Must stay stable and unique, and must not start with "herdr:".
local SOURCE = "maki-herdr"
local TITLE_SOURCE = "maki-herdr-title"
local AGENT = "maki"

local STATE = {
  working = "working",
  needs_input = "blocked",
  idle = "idle",
  -- Nothing runs a stored session, but maki can open it from this pane and
  -- the user is not waiting on it: idle, never blocked.
  stored = "idle",
}

local RETRY_MS = 500
local MAX_RETRIES = 3
local STARTUP_MS = 1500
local STARTUP_TRIES = 5
-- Herdr caps presentation text at 80 characters and trims it. Capping here
-- keeps the cached title equal to what herdr stores, so the next diff is real.
local TITLE_MAX = 80

local function state_for(status)
  return STATE[status]
end

-- Herdr ignores a report whose sequence is not higher than the last one it
-- accepted, and that number survives a herdr restart and a maki restart, so
-- seed from the clock and never go backwards.
local function next_seq(prev, now)
  return math.max((prev or 0) + 1, (now or os.time()) * 1000)
end

local function same_report(last, sid, state, cwd)
  return last ~= nil and last.sid == sid and last.state == state and last.cwd == cwd
end

-- Surrounding blanks and control characters would make herdr's stored value
-- differ from the cached one, so normalize before reporting.
local function normalize_title(title)
  if type(title) ~= "string" then
    return nil
  end
  title = title:gsub("%c", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if title == "" then
    return nil
  end
  if #title > TITLE_MAX then
    -- Cut at a UTF-8 boundary: never leave half a character behind.
    title = title:sub(1, TITLE_MAX)
    local i = #title
    while i > 0 and title:byte(i) >= 0x80 and title:byte(i) < 0xC0 do
      i = i - 1
    end
    local lead = title:byte(i)
    local need = lead >= 0xF0 and 4 or lead >= 0xE0 and 3 or lead >= 0xC0 and 2 or 1
    if i > 0 and #title - i + 1 < need then
      title = title:sub(1, i - 1)
    end
  end
  return title
end

local function report_argv(bin, pane, sid, state, seq, cwd)
  return {
    bin,
    "pane",
    "report-agent",
    pane,
    "--source",
    SOURCE,
    "--agent",
    AGENT,
    "--state",
    state,
    "--seq",
    tostring(seq),
    "--agent-session-id",
    sid,
    -- Herdr restores the pane in its own directory and runs this there. The
    -- first word must be a plain command name on PATH, never a path. The
    -- wrapper enters the directory the session was last in, because herdr
    -- saves the pane's spawn directory, not one a /cd changed.
    "--",
    "maki-herdr-resume",
    cwd or "",
    sid,
  }
end

local function metadata_argv(bin, pane, title, seq, dir)
  local argv = {
    bin,
    "pane",
    "report-metadata",
    pane,
    "--source",
    TITLE_SOURCE,
    "--agent",
    AGENT,
    "--applies-to-source",
    SOURCE,
    "--seq",
    tostring(seq),
    -- Clears the parenthesized agent name earlier versions reported.
    "--clear-display-agent",
  }
  if title then
    argv[#argv + 1] = "--title"
    argv[#argv + 1] = title
    -- The sidebar row renders this as $session.
    argv[#argv + 1] = "--token"
    argv[#argv + 1] = "session=" .. title
  else
    -- Metadata is not restored after a herdr restart and a stale title
    -- outlives the session, so an empty title clears instead of staying.
    argv[#argv + 1] = "--clear-title"
    argv[#argv + 1] = "--clear-token"
    argv[#argv + 1] = "session"
  end
  if dir then
    -- The sidebar row renders this as $dir: the session's directory name.
    argv[#argv + 1] = "--token"
    argv[#argv + 1] = "dir=" .. dir
  else
    argv[#argv + 1] = "--clear-token"
    argv[#argv + 1] = "dir"
  end
  return argv
end

-- Last path component, or nil for a root path or a missing value.
local function dir_name(cwd)
  if type(cwd) ~= "string" or cwd == "" then
    return nil
  end
  local name = cwd:match("([^/]+)/*$")
  if not name or name == "" then
    return nil
  end
  return name
end

local M = {
  _test = {
    state_for = state_for,
    next_seq = next_seq,
    same_report = same_report,
    normalize_title = normalize_title,
    report_argv = report_argv,
    metadata_argv = metadata_argv,
  },
}

local bin = uv.os_getenv("HERDR_BIN_PATH")
local pane = uv.os_getenv("HERDR_PANE_ID")

if uv.os_getenv("HERDR_ENV") ~= "1" or not bin or not pane or pane == "" then
  return M
end
-- Binaries are not probed with maki.fn.executable: that costs the fs_read
-- permission, and a jobstart that cannot spawn answers with nil and a reason.

local function warn(msg)
  maki.log.warn("herdr_bridge: " .. tostring(msg))
end

local function spawn(argv)
  local id, err = fn.jobstart(argv, {
    scope = "plugin",
    stdout = false,
    stderr = false,
  })
  if not id then
    warn(err)
    return nil
  end
  return id
end

-- Lifecycle authority. Herdr keeps one agent per pane, so what it last
-- accepted for this pane is one (session, state) pair, not one per session.
local sent = nil
local active = nil
local in_flight = false
local queued = nil
local retries = 0
local retry_timer = nil
local state_seq = 0

-- Display only, its own source and its own sequence.
local title_sent = false
local last_title = nil
local title_seq = 0

local pump
local schedule_resync

local function launch(item)
  state_seq = next_seq(state_seq)
  in_flight = true
  active = item
  local argv = report_argv(bin, pane, item.sid, item.state, state_seq, item.cwd)
  local id = fn.jobstart(argv, {
    scope = "plugin",
    stdout = false,
    stderr = false,
    on_exit = function(_, code)
      in_flight = false
      active = nil
      if code == 0 then
        sent = item
        retries = 0
      else
        -- Nothing reached herdr. Forget the report, or the same state would
        -- be deduplicated away and the pane would keep the older one.
        sent = nil
        warn(string.format("report-agent exited %d", code))
        schedule_resync()
      end
      pump()
    end,
  })
  if not id then
    in_flight = false
    active = nil
    sent = nil
    warn("report-agent could not start")
    schedule_resync()
  end
end

pump = function()
  if in_flight or not queued then
    return
  end
  local item = queued
  queued = nil
  if same_report(sent, item.sid, item.state, item.cwd) then
    return
  end
  launch(item)
end

local function send_state(sid, state, cwd)
  if not sid or not state then
    return
  end
  -- Keep at most one report in flight and one waiting: herdr only needs the
  -- latest state, and a transition storm must not spawn a process per frame.
  -- While a report is in flight, it, not the last accepted one, is what the
  -- next state has to differ from.
  local baseline = in_flight and active or sent
  if same_report(baseline, sid, state, cwd) or same_report(queued, sid, state, cwd) then
    return
  end
  queued = { sid = sid, state = state, cwd = cwd }
  pump()
end

-- Display only. Its own source and its own sequence, so a title report can
-- never change lifecycle authority.
local function send_title(title, dir)
  title = normalize_title(title)
  dir = normalize_title(dir)
  local key = tostring(title) .. "\0" .. tostring(dir)
  if title_sent and key == last_title then
    return
  end
  title_sent = true
  last_title = key
  title_seq = next_seq(title_seq)
  if not spawn(metadata_argv(bin, pane, title, title_seq, dir)) then
    -- Nothing reached herdr: report the same title again on the next event.
    title_sent = false
    last_title = nil
  end
end

-- The resume command rides on the state report, and herdr holds it only while
-- this source holds the pane, so a focus change must report both.
local function sync_focused()
  local s = maki.session.read()
  if not s or not s.id then
    -- The UI has no session yet, or the host is detaching.
    return false
  end
  send_state(s.id, state_for(s.status), s.cwd)
  send_title(s.title, dir_name(s.cwd))
  return true
end

schedule_resync = function()
  if retries >= MAX_RETRIES then
    return
  end
  retries = retries + 1
  if retry_timer then
    retry_timer:stop()
  end
  retry_timer = maki.defer_fn(function()
    retry_timer = nil
    sync_focused()
  end, RETRY_MS)
end

maki.api.create_autocmd("SessionStatusChanged", {
  callback = function(ev)
    if ev.data.focused then
      local cur = maki.session.read()
      send_state(ev.data.session_id, state_for(ev.data.status), cur and cur.cwd or nil)
    end
  end,
})

-- A /cd must reach herdr: the resume command carries the directory, and the
-- pane's saved spawn directory never changes.
maki.api.create_autocmd("SessionCwdChanged", {
  callback = function(ev)
    if ev.data.focused then
      local cur = maki.session.read()
      send_state(cur and cur.id or ev.data.session_id, cur and state_for(cur.status) or nil, ev.data.cwd)
      send_title(cur and cur.title or nil, dir_name(ev.data.cwd))
    end
  end,
})

maki.api.create_autocmd("SessionFocusChanged", {
  callback = function()
    sync_focused()
  end,
})

maki.api.create_autocmd("SessionTitleChanged", {
  callback = function(ev)
    if ev.data.focused then
      local cur = maki.session.read()
      send_title(ev.data.title, cur and dir_name(cur.cwd) or nil)
    end
  end,
})

maki.api.create_autocmd({ "SessionReset", "SessionEnd" }, {
  callback = function(ev)
    -- The kept report names a session that is gone, so the next report must
    -- reach herdr even when it carries the same state as the last one.
    if sent and sent.sid == ev.data.session_id then
      sent = nil
    end
    if queued and queued.sid == ev.data.session_id then
      queued = nil
    end
    -- No release-agent here. A session-owned or plugin-owned job is killed
    -- when this runtime drops, which is the very moment maki quits, so the
    -- call would be killed in flight. Herdr clears the agent and its resume
    -- command when the pane returns to its shell prompt.
    maki.defer_fn(sync_focused, 200)
  end,
})

-- The first focus at startup fires an event, but under /reload and on a fast
-- start it can land before the session is readable, so retry a few times.
maki.defer_fn(function()
  local function attempt(n)
    if sync_focused() then
      return
    end
    if n < STARTUP_TRIES then
      maki.defer_fn(function()
        attempt(n + 1)
      end, STARTUP_MS)
    end
  end
  attempt(1)
end, STARTUP_MS)

return M
