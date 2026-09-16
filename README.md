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
- **A permanent line about control, at the very top**: "🖱️⌨️ working — hands off the mouse and keyboard" while running,
  "✅ finished, you can take back control" when done. It is the heaviest text on the panel and the only one carrying a
  background: **black on solid yellow while it is unsafe to touch anything, black on solid green once you may take
  over** — the highest-contrast pairing a translucent dark panel can show.
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

**Clean up afterwards too**: `done` at the end, then **quit the app you launched for the test** (gracefully, not
`kill -9`) and bring the browser / DSH window back to the front. Do not leave the app under test sitting on screen.

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
    defaultAnchor: auto       # auto | top-left | top-right
    topInset: 155             # how far the top anchors drop below the screen top, in points
```

Where the panel goes is decided in this order:

1. **Do not cover the thing under test.** The panel scores three positions against the frontmost app's windows and
   takes the one that overlaps least. This outranks everything below.
2. **Centre of the screen**, when that blocks nothing.
3. Otherwise **the side** — left before right.

Vertically it always sits high: the top edge clears the menu bar and toolbars (`topInset`), the bottom edge stops above
the status bar / Dock (`Look.bottomInset`, 44 pt), and the height cap respects both. Horizontally it stays off the edges
(`Look.sideInset`, 28 pt) so it cannot sit on a sidebar or a scrollbar. Anchors are `auto | center | left | right`; the
old `top-left` / `top-right` names still map to `left` / `right`.

`topInset` exists because the panel usually floats **over a browser**: the top ~150 pt of the screen are the tab strip,
the address bar and the bookmarks bar, and a panel there would cover them. The default (155) starts the panel just
below that chrome — level with the page's own header. Set it to `0` to get the old behaviour (a 14 pt screen margin),
or to whatever puts the panel where you want it. `DSH_TESTHUD_TOP_INSET` overrides it for the CLI.

**Everything is computed from one number.** The panel samples the average luminance of *the rectangle it is about to
cover* — only that rectangle — every 2 s and whenever the frontmost app changes. That single value then derives the
whole appearance: the panel fill, its direction (dark over a light backdrop, light over a dark one), both text colours,
the text plates, the banner colours and all four opacities. There are no two presets; there is one formula.

The trick is the **direction**, and it is the opposite of what seems natural. The panel goes *with* the backdrop, not
against it: a light backdrop gets a lighter panel with dark text, a dark backdrop gets a darker panel with white text.
Once the direction is right, **10% opacity is enough** — so no text plates are needed at all, and the panel stays 90%
see-through. Going the other way (dark panel over a light page) is what forces opaque plates under every line, and those
plates are what "the covered area is unreadable" means.

Measured: panel body 0.93 over a white page (backdrop 0.93) and 0.10 over a dark terminal (backdrop 0.08) — the panel is
essentially invisible as a surface, and what you read is text floating on the content itself.

**The panel's ground is a blurred snapshot of what it covers**, captured with the same 2 s sampling pass and blurred with
σ=14. Fully see-through panels have a failure mode of their own: the text underneath stays perfectly legible and fights
the panel's own text — same size, same colour, two layers of type in one place. Blurring the ground turns that competing
text into soft light and shade: you can still tell *something* is there (texture stddev drops from 30 to 8), but it no
longer competes. It is the panel equivalent of ground glass, and it replaces the per-line plates entirely.

Targets are WCAG-style contrast ratios, solved by algebra, with one notch of headroom: `plateLum = (text + 0.05) /
contrast − 0.05`, then `alpha = solveAlpha(over: panelLum, base: plateLum)`. The ask is **9:1** — because a paper 7:1
measures about 6.6–6.8 on screen (CJK strokes are thin, and antialiasing lifts the measured text luminance).

Measured, sampled inside each text box:

| backdrop | panel | title | secondary | banner |
|---|---|---|---|---|
| white page | dark, body 0.73 | **10.4:1** | **9.0:1** | **7.1:1** |
| dark terminal | light, body 0.19 | **8.6:1** | **8.6:1** | 5.8:1 |

18 pt counts as large text, so WCAG AAA asks 4.5:1 — every row clears the *body-text* bar of 7:1 except the banner on a
dark backdrop, which is still above the large-text bar.

Sampling excludes the panel's own window by id, so the panel never hides itself and never flickers.

## Visual design

The layout follows CRAP deliberately; keep these rules when you edit it:

- **Contrast** — colour carries exactly one meaning (status): the full-width control banner, plus a single coloured
  character at the head of each step. Everything else is layered with **two** greys (`Look.primary` / `Look.secondary`)
  and four font weights, never with a second size — every line is `Look.base` (18 pt). Two greys, not three: on a light
  ground a third step drops below 3:1, and three greys are hard to tell apart anyway.
- **Repetition** — one left edge for all content (`Look.inset`), and only three spacing values: 14 pt between groups,
  10 pt between steps, 2–4 pt inside a step.
- **Alignment** — the banner spans the full panel width and its text indents back to the content edge; a step's
  expect/actual lines use a real `headIndent`, not spaces (spaces never line up in a proportional font).
- **Proximity** — header (title / target / timer), steps, and the conclusion are three groups: tight inside, loose
  between.

Measured in the worst case (a white background showing through, panel floor `#333`): primary 4.2:1, expect/actual
3.7:1, meta 3.0:1 — all at or above the 3:1 WCAG AA bar for large text. On a dark backdrop every ratio roughly doubles.

Every line is the same size — `Look.base` (18 pt) in `hud/testhud.swift` — and the hierarchy comes from weight alone
(heavy for the control line, bold for the title and status, semibold for steps, regular for the expect/actual detail).
The browser's DSH body text is `--dsh-content-font-size` (14 px by default, 12–17 settable); the panel sits above it
because light text on a translucent dark panel reads smaller than black text on a page. Change `base` and the whole
panel resizes with it.

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
