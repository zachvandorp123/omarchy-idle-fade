# Idle Fade

An Omarchy shell plugin that puts the screen under slowly instead of switching
it off. Two things happen while the machine sits idle:

- the **backlight** walks down a perceptual curve, and
- a **vignette** closes in from the edges, so the screen tunnels inward rather
  than dimming flatly.

Coming back, the screen does not just snap on: the tunnel reopens as a pair of
eyes, blinking twice on the way. One gradient carries both effects, because it
has independent horizontal and vertical radii — shrinking them together is a
tunnel, holding the horizontal wide and working the vertical alone is an eyelid.

Stock Omarchy jumps straight from full brightness to screensaver to lock. This
fills in the ramp between.

```
0s        idle begins
60s       fade starts from whatever brightness is in use
~108s     tunnel starts closing in from the edges
~120s     ~60% brightness
~240s     ~15%
300s      1% backlight, tunnel fully closed — screensaver appears
600s      lock screen

on wake   squint → blink → wider → blink → open, ~1.1s, light flooding back
```

## Requirements

- Omarchy with the Quickshell-based shell (`omarchy-shell`)
- `brightnessctl` — ships in the default Omarchy set
- `qt6-5compat` — provides `Qt5Compat.GraphicalEffects` for the vignette
- A writable backlight. Laptop panels work out of the box; desktops with only
  DDC/external monitors get the vignette but not the backlight ramp.

## Install

```bash
omarchy plugin add https://github.com/zachvandorp123/omarchy-idle-fade.git --enable
omarchy restart shell
```

Plugins land disabled unless you pass `--enable`, so you can read the code
first. A shell restart is needed because the shell mounts a service once per
session.

Then set the screensaver to fire when the fade finishes. In
`~/.config/omarchy/shell.json`:

```json
"idle": { "screensaver": 300, "lock": 600 }
```

The plugin does not edit that file for you. Match `idle.screensaver` to
`startSeconds + durationSeconds` (60 + 240 = 300 by default) so the screen
finishes fading exactly as the screensaver takes over.

## Remove

```bash
omarchy plugin remove io.github.zachvandorp123.idle-fade
omarchy restart shell
```

Optionally delete `~/.config/omarchy/idle-fade.json`, and restore
`idle.screensaver` / `idle.lock` in `~/.config/omarchy/shell.json` to the
Omarchy defaults of `150` and `300`.

## Try it without waiting

```bash
omarchy-shell idle-fade preview 20    # the whole cycle in 20s, then restore
omarchy-shell idle-fade status        # JSON state dump
omarchy-shell idle-fade restore       # abort a fade and restore brightness
```

## Configuration

Create `~/.config/omarchy/idle-fade.json` — see `idle-fade.example.json` in
this repo. It hot-reloads on save; every key is optional and falls back to the
default below.

| Key               | Default | Meaning                                                      |
|-------------------|---------|---------------------------------------------------------------|
| `enabled`         | `true`  | Master switch.                                                |
| `startSeconds`    | `60`    | Idle time before the fade begins.                             |
| `durationSeconds` | `240`   | How long the ramp takes to reach the floor.                   |
| `minPercent`      | `1`     | Floor, as a percent of panel maximum.                         |
| `curve`           | `1.6`   | Ramp shape. `1` is linear; higher holds bright longer then drops. |
| `stepPercent`     | `0.5`   | Perceptual distance between backlight writes.                 |
| `tickMs`          | `50`    | How often the ramp recomputes. Costs nothing; spawns nothing. |
| `minWriteMs`      | `25`    | Rate cap on writes, so a short preview cannot storm the CPU.  |
| `device`          | auto    | `brightnessctl` device. Omit unless you have several backlights. |

### `vignette`

| Key             | Default | Meaning                                                      |
|-----------------|---------|---------------------------------------------------------------|
| `enabled`       | `true`  | Off keeps the plain backlight fade.                           |
| `startFraction` | `0.2`   | How far into the fade the tunnel starts closing.              |
| `curve`         | `1.5`   | Close shape. Higher lingers open, then collapses at the end.  |
| `softness`      | `0.55`  | Size of the clear centre. Lower is a tighter, harder tunnel.  |
| `openRadius`    | `1.5`   | Starting radius, in half-screens.                             |
| `quantize`      | `0.002` | Progress step. Smaller is finer but repaints more often.      |

### `wake`

| Key            | Default | Meaning                                                        |
|----------------|---------|-----------------------------------------------------------------|
| `enabled`      | `true`  | Off restores instantly instead of opening the eyes.              |
| `blinks`       | `2`     | Number of shut-and-wider cycles. `0` is a single smooth open.    |
| `speed`        | `1`     | Duration multiplier. `0.6` is a brisker wake, `1.5` a drowsier one. |
| `minProgress`  | `0.5`   | How far under the fade must have gone to earn the animation.     |
| `stepPercent`  | `2`     | Perceptual step for the brightness climb; coarser than the fade because the lid is covering it anyway. |

Waking from a shallow fade skips the blinks entirely — nudging the mouse 70
seconds in just restores the screen, so the effect stays something that happens
when the machine has actually gone under.

## How it stays cheap

Backlight steps are paced by *perceived* change, not by the clock. The eye needs
roughly a 1% relative change to notice a step, so the ramp ticks cheaply in QML
and only spends a `brightnessctl` call (~4ms) once the target has drifted
`stepPercent` away from what the panel is showing.

That matters because an evenly-timed ramp is not evenly *seen*: near full
brightness a one-second step moves the level 0.03%, but near the floor the same
step is a ~6% jump, which is exactly where flat pacing looks chunky. Delta
pacing spreads ~900 writes across a four-minute fade — sparse while bright,
dense near black — for well under 2% of a core.

## Behaviour notes

- Respects idle inhibitors, so video playback and presentations never dim.
- Respects the Stay Awake bar indicator; turning it on suppresses the fade.
- The overlay is a click-through layer-shell surface (`mask: Region {}`), so it
  never swallows the input meant to dismiss it.
- The overlay covers every screen, which gives external monitors a fade even
  though only the internal panel has a controllable backlight.
- The overlay drops the moment the screensaver opens, so it cannot cover it.
- Once the screensaver is up, incidental compositor activity does not undo the
  fade; dismissing the screensaver does.
- The pre-fade level is parked in `$XDG_RUNTIME_DIR/omarchy-idle-fade.state`,
  so a shell crash mid-fade cannot leave the panel stuck dark.

## Security surface

No network access, no downloads, no `sudo` or `pkexec`, no bundled binaries.
Subprocesses are limited to `brightnessctl` and two one-line `bash` helpers that
read and write a single integer in `$XDG_RUNTIME_DIR`, which is owner-only. The
plugin never writes to user configuration; it only reads
`~/.config/omarchy/idle-fade.json`.

## Development

The shell mounts a service once per session, so changes to `Service.qml` need
`omarchy restart shell` rather than a plugin rescan. Values in
`idle-fade.json` hot-reload without one.

## Licence

MIT. See [LICENSE](LICENSE) for the external dependency list.
