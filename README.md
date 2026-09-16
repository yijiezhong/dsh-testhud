# dsh-testhud

An always-on-top, click-through progress panel for automated tests in [DeepSeek Harness](https://github.com/deepseek-ai) (dsh),
drawn **over the app under test** — plus the `test_hud` tool that drives it from any session.

![the panel](assets/panel.png)

## Why it exists

When an agent drives a GUI, compares screenshots or renders a batch for a few minutes, the human just sits there:
they cannot tell which step it is on, what the step expects, whether it already failed, or — the question that actually
matters — **whether it is safe to touch the mouse and keyboard again**.

This panel answers exactly that, on screen, without stealing focus:

- **What is being tested** — title, target, start time and elapsed seconds.
- **Every step, with expectation and actual result** — one line each, ✅ / ❌ / ⏳ / •
- **A permanent header line about control**: "🖱️⌨️ working — hands off the mouse and keyboard" while running,
  "✅ finished, you can take back control" when done.
- **It never gets in the way**: click-through (the mouse passes straight through), always on top, not in the Dock
  and not in ⌘Tab, and it picks the emptiest corner of the screen so it covers as little of the app under test as possible.

## Install

```sh
dsh plugin --profile web add github:yijiezhong/dsh-testhud
```

A new bundle row is composed at boot, so restart the profile once (the plugin market offers a restart button).
Every session in that profile then has the `test_hud` tool and a short prompt convention telling the agent to use it.

Uninstall:

```sh
dsh plugin --profile web remove dsh-testhud
```

## The agent tool

| `action` | What it does | Parameters |
| --- | --- | --- |
| `start` | Opens a run and launches the panel | `title` (required), `target`, `anchor` |
| `step` | Reports one check | `name` (required), `expect`, `actual`, `state` = `ok`/`fail`/`run`/`info` |
| `note` | Adds one line at the bottom | `text` |
| `done` | Writes the conclusion and ends the run | `failed` (boolean), `conclusion` |
| `stop` | Closes the panel immediately | — |

The panel sizes itself to its content (capped at 62% of the visible screen height), scrolls **only** the step list while
the header stays fixed, and disappears 12 seconds after `done` — long enough to read the verdict.

## The rule

**If a verification is running, the panel must be up.** Never "just run the commands" without it: during a series of
runs, `start` again after a `done` and before the next action. Whoever is waiting must be able to see what is being
tested and whether it is safe to take back the keyboard.

## The CLI

Same logic, same progress file, for shell scripts and CI:

```sh
testhud start "Movable toolbar layout" "Movable main window" [anchor]
testhud step  "toolbar is centred" "centre == window centre" "962pt, centred" ok
testhud note  "left to the user to decide"
testhud done  ok "3 of 3 checks passed"
testhud stop
testhud status
```

## Configuration

Optional row config in your profile's `cordis.patch.yml` overrides the plugin row:

```yaml
- id: testhud
  config:
    announceToAgent: true     # inject the short "report long tests on screen" convention into every session
    defaultAnchor: auto       # auto | top-left | top-right | bottom-left | bottom-right
    topInset: 155             # how far the top anchors drop below the screen top, in points
```

`topInset` exists because the panel usually floats **over a browser**: the top ~150 pt of the screen are the tab strip,
the address bar and the bookmarks bar, and a panel there would cover them. The default (155) starts the panel just
below that chrome — level with the page's own header. Set it to `0` to get the old behaviour (a 14 pt screen margin),
or to whatever puts the panel where you want it. `DSH_TESTHUD_TOP_INSET` overrides it for the CLI.

The panel background is a 44%-opaque near-black (`Look.bgAlpha` / `Look.bgWhite` in `hud/testhud.swift`) — dark enough
for white text to read, light enough to see what is underneath. Both are one-line edits if you want it different.

## Requirements

- **A dsh host that provides `@deepseek-ai/dsh-tools`** — any 0.1.x harness. The package declares no runtime
  dependencies: `defineTool` and `ctx.*` come from the host.
- **macOS** for the panel itself (AppKit). The progress file and the tool work anywhere.
- **Xcode Command Line Tools** for `swiftc` — the panel is compiled on first use into
  `~/.dsh/dsh-testhud/bin/testhud` (about a second) and reused afterwards, so the package ships source, not binaries.
  Without `swiftc` the tool still records every step and still returns the verdict; it just reports that it could not draw the panel.

## Development

```sh
# a throwaway profile, so your real one is untouched
dsh --profile hudtest --from-default-profile headless --dump-config > /dev/null
dsh plugin --profile hudtest add link:"$PWD"
dsh --profile hudtest --dump-config | grep -A2 testhud        # the row is composed
dsh --profile hudtest "call test_hud: start, step, done"      # a real session must see and call the tool
rm -rf ~/.dsh/profiles/hudtest                                # clean up
```

`node_modules/@deepseek-ai/dsh-tools` is only needed for standalone `node lib/index.js` smoke tests; inside a dsh
process the host resolves it. It is not part of the published package.

## How it works

```
lib/index.js      Cordis host plugin: registers the test_hud tool + a system-prompt section
lib/hud.js        progress file (~/.dsh/test-progress.json) and the panel process (build / start / stop)
hud/testhud.swift the panel itself: borderless NSPanel at .statusBar level, ignoresMouseEvents, polls the file every 0.4s
bin/testhud.js    CLI over the same core
```

The progress file schema is deliberately plain JSON, so anything can write it:

```json
{ "title": "…", "target": "…", "status": "running|done|failed", "startedAt": 1789518613.07,
  "steps": [{ "name": "…", "expect": "…", "actual": "…", "state": "ok|fail|run|info" }], "note": "…" }
```

## Limitations

- **One panel per machine.** The progress file is a single well-known path, so two concurrent test runs share one panel —
  the last writer wins.
- The panel is click-through by design, so it cannot be moved or dismissed with the mouse: use `anchor` to steer it,
  `stop` / `done` to make it go away.
- On a screen already covered by full-screen windows, every corner overlaps something; `auto` then falls back to the
  top-left corner. Pass an explicit `anchor` to keep the panel away from the area you are testing.

## License

MIT
