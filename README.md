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
  { src = "https://github.com/amirs-maki-plugins/maki-herdr-bridge", version = "v1.0.0" },
})
```

Start maki in a Herdr pane. The plugin does nothing outside Herdr.

## What Herdr gets

Two reports go to Herdr, from two separate sources. Each one has its own job
and its own sequence number.

1. `herdr pane report-agent`, source `maki-herdr`. This is lifecycle authority:
   the state, the maki session id, and the resume command
   `maki --resume <id>`. Herdr uses this state instead of reading the screen.
2. `herdr pane report-metadata`, source `maki-herdr-title`. This is display
   only: the title, and the token `session`. A metadata report can never
   change the state or the resume command.

What this gives you:

- The sidebar and `herdr agent list` show the maki state, not a guess from the
  screen.
- `herdr agent wait`, `herdr agent prompt`, and notifications follow that
  state.
- After a Herdr restart, the pane runs `maki --resume <id>` in the same
  directory, so the same maki session comes back.
- The session title appears in the agent row, through the `session` token.

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

Add the `session` token to the agent rows in `~/.config/herdr/config.toml`:

```toml
[ui.sidebar.agents]
rows = [
  ["state_icon", "machine", "workspace", "tab"],
  ["agent", "$session"],
]
```

Then reload the Herdr config. Herdr caps metadata text at 80 characters and
trims it. An empty title clears both the title and the token.

## Requirements

- Herdr 0.9.2 or newer. Older versions ignore the resume command, and the
  state reports still work.
- `HERDR_ENV=1`, `HERDR_BIN_PATH`, and `HERDR_PANE_ID` in the environment.
  Herdr sets all three in every pane it manages.
- maki 0.7.0 or newer.
- The `run` permission, for the two `herdr` jobs. The plugin asks for nothing
  else.

## Known limits

- No `release-agent` report. maki kills its plugin jobs when the runtime
  drops, which is the moment maki quits, so the call would die in flight.
  Herdr clears the agent and the resume command about a second after the pane
  returns to its shell prompt.
- The resume command is `maki --resume <id>`. It does not carry maki start
  flags such as a model or a mode, and it does not carry a `/cd` inside maki:
  maki sets a resumed session's directory to the directory it starts in, which
  is the pane directory Herdr restores.
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
sequence counter, the deduplication key, the title normalization, and both
command line shapes. Run it with `/herdr-bridge-spec` after installing.
