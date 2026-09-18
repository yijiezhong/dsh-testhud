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
- **A permanent line about control, at the very top** — the panel's own strings are Chinese; this one reads
  `🖱️⌨️ 正在进行：先别动鼠标键盘，以免打断测试` while running and `✅ 已结束，可以收回鼠标键盘的控制权了` when done.
  It is the heaviest text on the panel and the only line carrying a background:
  **black on vivid red while it is unsafe to touch anything, black on vivid green once you may take over**.
  Those two colours are pinned by user request (2026-09-18, replacing amber / teal): hue, saturation and brightness all
  fixed, opacity 0.75 so what is underneath stays dimly readable. Only the text colour (black or white) is still
  solved — that is legibility, not style.
- **It never gets in the way**: click-through (the mouse passes straight through), always on top, not in the Dock
  and not in ⌘Tab, and it picks the emptiest corner of the screen so it covers as little of the app under test as possible.
- **Move it by hand**: grab the top colour band and drag to put the panel wherever suits you. That band is the only part
  that is not click-through — it is the drag handle; everything below it still passes the mouse straight through.
- **Three traffic lights at the band's left end**, the macOS three: **red** closes the panel, **yellow** collapses it
  down to just the band (click again to restore), **green** expands it to the maximum height (click again to go back
  to the content height). So it can be put away or enlarged with the mouse, without going back to the tool. Their
  colours deliberately stay out of the chameleon algorithm — red/amber/green are what people recognise, and a dot
  that recolours itself with the backdrop stops being recognisable. Each dot now carries a **1.5 pt dark stroke**
  (added 2026-09-18): once the band became vivid red / green, the red dot on the red band — and the green dot on the
  green band — dissolved into it (measured: band vs red dot was **1.03:1**, i.e. the dot could not be found).

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

**Everything is computed from what the panel covers.** Every 0.7 s — and immediately whenever the frontmost app
changes, the panel resizes, or its own content changes (0.5 s debounce) — it measures *the rectangle it is about to
cover*, and only that rectangle: its average luminance **and its light/dark spread** (p10–p90). Those numbers derive
the whole appearance: the panel fill and its direction, the luminance of both text greys, the banner's fill and text,
the panel's opacity, and how flat the ground is flattened. There are no two presets, and **not one colour on the panel
is a hard-coded constant**.

The trick is the **direction**: the panel goes *with* the backdrop, not against it — a light backdrop gets a lighter
panel with dark text, a dark backdrop gets a darker panel with white text. Going the other way (a dark panel over a
light page) is only fixable by piling on opacity, and that is exactly what makes the covered area unreadable.

What is left after that is a trade-off that **cannot be solved, only spent**: the pixels that give the panel's text
something to sit on are the same pixels that hide what is underneath. Both ways out were built and measured — per-line
plates (rejected by the user: the content behind them became unreadable) and making the panel itself as transparent as
possible (0.10 / 0.20 / 0.35 all leaked 1–3 lines of background text on a dense backdrop, always the text being *typed
right then*). The floor is therefore **0.50**: on ordinary backdrops the panel's text is far past AAA, and the covered
region still shows light and shape. On black-on-white text filling the whole screen, that is the limit of "both".

**The panel's ground is a blurred snapshot of what it covers**, taken in the same sampling pass, blurred with σ=34 and
desaturated to 0.70. A fully see-through panel has a failure mode of its own: the text underneath stays perfectly
legible and fights the panel's own text — same size, similar colour, two layers of type in one place. Blurring the
ground turns that competing text into soft light and shade: you can still tell *something* is there, but it no longer
competes.

Two things about that ground have to be right, or the panel ends up **choosing text colours for a backdrop that does
not exist** (this bug took a long time to find). Contrast is compressed **around mid-grey**, so afterwards the image's
mean is no longer the sampled mean — on a dark backdrop the two differ by a factor of two — and the palette computes
the panel's own floor from that number. So the mean is **anchored back** to its true value, and that true value is
**measured** (`CIAreaAverage` rendered to sRGB) rather than derived by formula. The contrast is then scaled by the
region's **light/dark spread** (p10–p90): the ground keeps the large-scale light and shade, while the panel's text has
only one colour — a backdrop that is bright on one side and dark on the other leaves half of it wrong whichever
direction you pick. Flattening adds **no** occlusion (the panel's opacity is untouched); it only costs some of the
"something is down there" texture.

Contrast is WCAG-style (`(lighter + 0.05) / (darker + 0.05)`), but it is **not solved to the exact bar**: the lesson
this project paid for is that a paper 7:1 measures only 6.6–6.8 on screen (CJK strokes are thin, and antialiasing lifts
the measured luminance), so anything solved "just barely" comes out short.

**The text luminances are solved too**, not fixed constants: each is derived from the panel floor's actual luminance
against `primaryContrast` (9) / `secondaryContrast` (7), clamped to black or white when the floor simply cannot give
that much. The second grey targets "0.91 × the contrast the first one actually reached" — solving both independently
would pin them both to pure white on a dark panel, and the two-grey split is this panel's only means of hierarchy.
The banner **no longer takes part in that solving** (since 2026-09-18, when the user asked for "vivid red and green,
highly saturated, brighter"): hue, saturation and brightness are all pinned — vivid red 0° = stop, vivid green 120° =
take over, saturation and brightness both at 1.0 (the extreme for that hue, so "more vivid" can only come from another
hue or a higher opacity). This is a **deliberate reversal** of the chameleon route above, not a bug in it: solving each
term against the backdrop is incompatible with staying vivid (a coloured backdrop pulls saturation down, a bright one
pulls brightness down). The old implementation (`banner()`, amber 0.10 / teal 0.45) is still in `hud/testhud.swift`
with no callers — to roll back, swap the two calls in `palette()`.

Only the **bar's text colour** (black or white) is still solved, and that is a legibility floor rather than a style
choice: the same bar over a light and a dark panel differs by more than 2× in shown luminance (vivid red at alpha 0.75:
≈0.50 light, ≈0.21 dark), so black and white can each serve only one of the two.

The opacity is **0.75**. At 0.55 "vivid red" simply does not exist — measured, it renders as pink `RGB(246,141,131)`
with saturation 0.47; at 0.75 it is `RGB(239,98,85)` with saturation 0.65 (light backdrop). The cost is that the few
lines under the bar go from "clearly readable" to "dimly visible" — the trade-off the user picked on the spot
(0.85 is the next step: more vivid, but the text under the bar ends up essentially covered).
**The side effect, and its fix (same day, 2026-09-18)**: each dot gets a **1.5 pt dark stroke**, with the frame grown
to the outer diameter (15 pt) so the stroke sits *outside* the 12 pt colour — the coloured part loses nothing. The red
dot's distinguishability from the band went from **1.03:1** to **4.44:1** (dot against ring) / **4.57:1** (ring against
band); the green dot on the green band behaves the same (ring vs band 5.0:1). A constant dark stroke suffices: the
band's saturation and brightness are pinned at 1.0, so its shown luminance only spans 0.21–0.74, where dark is past
5:1 in every case.

**The bar's text is plain black or white** — no "solve to exactly the target", no tinting. The bar's brightness is
deliberately pushed up to "bright enough", so pure black is always available there and always higher contrast: with the
bar showing 0.445, pure black measures **9.90:1** while "solved to the target" gave only 6.50:1 — 3.4:1 given away for
nothing. (Carrying the panel text's rule over to the bar was simply wrong: the panel floor can land at any luminance,
the bar cannot.)

Measured: the bar reaches **8.3:1** on a light backdrop and **5.1:1** on a dark one (re-measured 2026-09-18 after the
switch to fixed vivid red / green; the amber / teal pair was 6.6 / 5.8).

**The colour is solved too, black and white first:**

1. **Whichever of black and white gives more wins** — the two are compared by the contrast each reaches against the
   panel floor, rather than picked by "is the panel light or dark". Around panelLum ≈ 0.19, black (4.8:1) actually
   beats white (4.38:1).
2. **A neutral environment gets neutral text**: below `minTintSat` (0.15) saturation the text stays greyscale. That is
   the cleanest choice, and black and white are the **endpoints of the luminance range** — no chromatic colour can be
   more extreme at the same luminance.
3. **A coloured environment gets its complement** (opposite on the colour wheel). The luminance does not change, so
   **no contrast figure moves**. What the hue buys is not "clearer" but "the panel's text and the text underneath are
   no longer the same colour" — and a coloured backdrop is exactly where that happens: two layers of type in one
   colour, brightness already maxed out, hue the only thing left to separate them.
4. **When the luminance is clamped to an endpoint** — meaning the floor cannot even give the target contrast, so black
   and white are already its limit — `tintRelax` (0.05) of luminance is spent to buy a hue. At a clamped luminance no
   hue solves to any saturation at all, which would amount to not tinting.

Measured on a full screen of solid orange (saturation 0.727): the text took the complementary cyan at 202°, and the
panel's brightest 2% of pixels `(218,239,251)` measured R−B = −33 while the backdrop's R sits well above its B. The
price is white text falling from 5.24:1 to 4.62:1.

Measured by `bin/testhud-inspect.py` on the geometry the panel exports itself. **Both backdrops are dense real text**,
not solid colour — a solid backdrop cannot reproduce the failure this panel exists to avoid:

| backdrop | banner | title / step | expect / actual | target / timer |
|---|---|---|---|---|
| light (the DSH UI in a browser: dark text on white) | 8.3:1 | **9.4:1** | 7.2:1 | 7.2 / 7.2:1 |
| dark (a terminal: white text on black) | 5.1:1 | 7.7 / 7.0:1 | 5.9–6.7:1 | 6.5 / 6.8:1 |

18 pt counts as large text, so WCAG AAA asks 4.5:1. On a light backdrop everything except the banner reaches AAA's
body-text bar of 7:1. Dense dark text is the worst case at 5.1:1 — still past the AAA large-text bar, but short of AAA:
that is the price of the 0.50 floor plus vivid red being inherently dark (luminance 0.21, far below the old amber).

Sampling excludes the panel's own window by id, so the panel never hides itself and never flickers.

## Visual design

The layout follows CRAP deliberately; keep these rules when you edit it:

- **Contrast** — colour carries exactly one meaning (status): the full-width control banner, plus a single coloured
  character at the head of each step. Everything else is layered with **two** greys (their luminance solved from the
  panel floor, see above) and four font weights, never with a second size — every line is `Look.base` (18 pt).
  Two greys, not three: on a light ground a third step drops below 3:1, and three greys are hard to tell apart anyway.
- **Repetition** — one left edge for all content (`Look.inset`), and only three spacing values: 14 pt between groups,
  10 pt between steps, 2–4 pt inside a step.
- **Alignment** — the banner spans the full panel width and its text indents back to the content edge; a step's
  expect/actual lines use a real `headIndent`, not spaces (spaces never line up in a proportional font).
- **Proximity** — header (title / target / timer), steps, and the conclusion are three groups: tight inside, loose
  between.

Measured in the worst case (dense dark text, see the table above): banner 5.1:1, expect/actual 5.9–6.7:1, title 7.7:1.
The banner is still the weakest element: its opacity is pinned at 0.75 (0.55 until 2026-09-18, raised to make vivid
red / green actually possible) so the content behind it stays dimly visible, and its hue is the inherently dark vivid
red; 5.1:1 is that banner's ceiling under those constraints.

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

### Inspect, don't guess

`bin/testhud-inspect.py` is the observation tool for the panel's pixels. It reads the geometry the panel itself
exports on every layout (`~/.dsh/dsh-testhud/panel-frame.json`), crops exactly that rectangle, and reports the panel's
internal texture plus every OCR line inside it that does **not** belong to the panel's own content.

Use it instead of reasoning about panel coordinates from a screenshot. Three separate conclusions in this project were
wrong because the panel's rectangle was inferred from OCR output while the panel's position and size are dynamic —
each time, content from *outside* the panel (the left half of a terminal, browser tab titles) was mistaken for text
bleeding through.

It has since learned two traps, both of which produced wrong numbers first. An OCR box can reach **outside the colour
band it names** — the banner's line box ran 20 px past the banner's bottom edge, so the panel's own dark fill was taken
for "the text colour" and a true 5.3:1 was reported as 2.1:1; contrast is now computed from colour clusters rather than
extreme pixels. And `belongs()`'s 3-gram rule can claim a background line that merely shares a fragment with the panel
(a path containing `dsh-testhud`), which is why anything measuring under 1.5:1 is now reported as an out-of-frame
artifact instead of a contrast figure. Text and its ground being nearly the same colour does not happen in reality.

The simplest mistake cost the most. The three dots at the band's left end went through eight rounds of "still not
rendering" before it turned out they had been on screen the whole time: the scan was handed `band height / 2`
(20 px = 10 pt) while the dots' centres sit at 20.5 pt = **41 px**, so every scan passed 10 points above them.
Looking at a screenshot settled it immediately.

So: **when several rounds in a row report "nothing changed", suspect the instrument before changing the subject
again.** A pixel-identical result across rounds, or several genuinely different implementations all "failing" the
same way, are signs that the instrument is broken — not the thing being measured.

### Test on a backdrop that contains text

Sample a backdrop with **real text** under it — a source file, a terminal full of output, a chat transcript. A solid
area (blank page, empty terminal) cannot show the failure this panel exists to avoid: its own text fighting the text
underneath, same size and similar colour, two layers of type in one place. A clean backdrop proves nothing about it.

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
hud/testhud.swift the panel itself: borderless NSPanel at .screenSaver level, ignoresMouseEvents, polls the file every 0.4s
                  (plus a second, transparent window covering only the colour band — the panel is click-through as a whole,
                   so band dragging and the three dots are handled there: ignoresMouseEvents is per-window, one window
                   cannot be "click-through here, solid there")
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
- The panel is click-through by design, with **one exception: the top colour band**, which is the drag handle — without
  it there would be no way to move the panel by hand. So a mouse landing on the band grips the panel instead of the app
  underneath; `stop` / `done` make it go away.
- **The band's left 78 points are reserved for the three dots**; the band text starts after them, so a long status
  line cannot run into the dots.
- Dragging leaves the panel **wherever you put it** — `layout()` only keeps the top edge fixed when the height
  changes, it never snaps back to a candidate position — until the panel process restarts. The drag is clamped to the
  visible area of the screen the mouse is on: otherwise the panel can be dropped into the dead space between two
  displays, where nothing is visible and it can never be clicked again.
- On a screen already covered by full-screen windows, every corner overlaps something; `auto` then falls back to the
  top-left corner. Pass an explicit `anchor` to keep the panel away from the area you are testing.
- **The panel's own text gets weaker in the worst case**: over dense dark text (a terminal full of output, say) it falls
  to 3.7–5.0:1. This is not a parameter still waiting to be tuned — fully blocking a ~15:1 high-contrast layer needs a
  panel opacity of 0.8 or more, which is to say an opaque panel, which throws away "the covered region stays visible".
  0.50 is where those two meet.
- **The panel's strings are Chinese** (the control banner, `测试对象：`, `期待：`, `实际：`, `结论：`). Nothing in the panel
  is localised; a run's own title and step text are whatever the caller wrote.

## License

MIT
