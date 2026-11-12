# maki-herdr-bridge

Report a [maki](https://github.com/tontinton/maki) session to
[Herdr](https://herdr.dev), so the Herdr sidebar shows the right state, the
session title, and a resume command.

Herdr ships integrations for many agents. It has no maki integration, so this
plugin is the integration. It uses the Herdr protocol for agents that report
their own state and session.

## Install

Add the package to `~/.config/maki/init.lua`, then restart maki and accept the
install prompt:

```lua
maki.pack.add({
  { src = "https://github.com/amirs-maki-plugins/maki-herdr-bridge", version = "v1.1.0" },
})
```

Start maki in a Herdr pane. The plugin does nothing outside Herdr.

## What Herdr gets

Two reports go to Herdr, from two separate sources. Each one has its own job
and its own sequence number.

1. `herdr pane report-agent`, source `maki-herdr`. This is lifecycle authority:
   the state, the maki session id, and the resume command
   `maki-herdr-resume --herdr-restore <id>`. Herdr uses this state instead of
   reading the screen.
2. `herdr pane report-metadata`, source `maki-herdr-title`. This is display
   only: the title, the token `session`, and the token `dir`. A metadata
   report can never change the state or the resume command.

What this gives you:

- The sidebar and `herdr agent list` show the maki state, not a guess from the
  screen.
- `herdr agent wait`, `herdr agent prompt`, and notifications follow that
  state.
- After a Herdr restart, the pane comes back in the session it had, in the
  directory that session was last in, including one changed by `/cd`. See
  [How the pane resumes](#how-the-pane-resumes).
- The session title and the session directory appear in the agent row, through
  the `session` and `dir` tokens.

## How the pane resumes

Herdr restores a pane by starting the pane's shell and typing the saved resume
command into its terminal, because a resume is a shell command line. When
maki itself is the pane's shell, there is no shell to run that line, so the
characters arrive in the chat input instead.

The plugin reads the line from the chat input and opens the session itself:

1. A fresh pane starts with an empty composer and a blank session, so the
   handler is armed.
2. While the whole composer can still become the line
   `maki-herdr-resume --herdr-restore <id>`, the handler stays armed. Any other
   text, and any sent message, disarms it for the rest of the maki process.
3. On a complete line, the handler clears the composer, so the line never
   becomes a message, then focuses that session. A session nothing runs is
   loaded from disk, and it brings its own working directory.

This works the same when maki sits in a shell, where the line does run: the
shell exits maki into `maki-herdr-resume`, which is why that script stays on
`PATH`.

## Status mapping

| maki status   | Herdr state | Why |
| ------------- | ----------- | --- |
| `working`     | `working`   | a turn or a background task runs |
| `needs_input` | `blocked`   | a permission prompt, an auth prompt, or a question waits |
| `idle`        | `idle`      | ready for input |
| `stored`      | `idle`      | nothing runs it, and nobody waits on it |

Only the focused maki session reports. Herdr gives one agent per pane, so a
background tab does not report. When the focus moves, the new session reports
its state and its resume command.

## Show the title in the sidebar

Add the tokens to the agent rows in `~/.config/herdr/config.toml`. This layout
puts the title on its own line, then the directory:

```toml
[ui.sidebar.agents.rows_by_agent]
maki = [
  ["state_icon", "$session"],
  ["$dir"],
]
```

Then reload the Herdr config. Herdr caps metadata text at 80 characters and
trims it. An empty title clears both the title and the token. The `dir` token
is the last component of the session's working directory.

The plugin does not set a display name. The agent row shows the name Herdr
detects, `maki`.

## Requirements

- Herdr 0.9.2 or newer. Older versions ignore the resume command, and the
  state reports still work.
- `HERDR_ENV=1`, `HERDR_BIN_PATH`, and `HERDR_PANE_ID` in the environment.
  Herdr sets all three in every pane it manages.
- maki 0.7.0 or newer.
- The `run` permission, for the two `herdr` jobs. The restore handler also
  needs `session_read` to see the chat input, `input` to clear it, and `agent`
  and `session_write` because maki prices a text change like a message. The
  plugin sends nothing.

## Known limits

- No `release-agent` report. maki kills its plugin jobs when the runtime
  drops, which is the moment maki quits, so the call would die in flight.
  Herdr clears the agent and the resume command about a second after the pane
  returns to its shell prompt.
- The resume command is `maki-herdr-resume --herdr-restore <id>`, a small
  wrapper on `PATH` for the pane whose shell really is a shell. Install it as
  `~/.local/bin/maki-herdr-resume`:

  ```sh
  #!/bin/sh
  case $1 in
  --herdr-restore)
    shift
    sid=$1
    [ -n "$sid" ] && shift
    exec maki --resume "$sid" "$@"
    ;;
  esac
  ```

  A shell in the pane runs it after maki exits. Without the wrapper, and
  without the plugin, Herdr falls back to a plain shell in the pane directory.
  The command does not carry maki start flags such as a model or a mode.
- Herdr does not restore metadata after a server restart. The next maki start
  reports the title again.
- A second maki in the same pane competes with the first one for the pane.
  Herdr keeps the report with the higher sequence number.

## Companion skill

The plugin reports; it does not teach the agent to use Herdr. To give the
agent the Herdr CLI skill, run:

```bash
herdr --skill > ~/.config/maki/skills/herdr/SKILL.md
```

## Layout

```
plugin/herdr_bridge.lua    entry point maki runs at startup: loads the
                           module and registers /herdr-bridge-spec
lua/herdr_bridge.lua       the plugin
lua/herdr_bridge_spec.lua  pure-helper spec cases
```

A package's `lua/` dir is only on its own require path, not the global
config's, which is why the spec command lives in the package.

## Tests

`lua/herdr_bridge_spec.lua` covers the pure helpers: the status map, the
sequence counter, the deduplication key, the title normalization, both command
line shapes, and the restore line matcher. Run it with `/herdr-bridge-spec`
after installing.
