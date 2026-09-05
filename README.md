# Monitor Arranger

A drag-to-arrange display layout widget for the [Omarchy](https://omarchy.org)
shell. Rearrange your monitors on a scale canvas, rotate and scale them,
preview the result live, then persist it to `~/.config/hypr/monitors.lua`.

Omarchy ships display *controls* (brightness, scale, enable/disable) but no
display *arranger*, and the general-purpose Wayland tools — `nwg-displays`,
`wdisplays` — cannot save into Omarchy's Lua config. This fills that gap.

## What it does

- **Drag to arrange.** Displays are drawn to scale and snap flush to each
  other's edges, with a guide line showing what an edge latched onto, so you
  never end up with a one-pixel dead strip or an overlap that Hyprland
  silently reflows around. `Shift+HJKL` nudges the selected display for fine
  adjustment; disabled displays park as ghosts at the bottom of the canvas so
  they stay clickable.
- **Rotate and scale.** Portrait, 180°, 270°, and the usual scale presets.
  Scales that don't divide the resolution evenly (which Hyprland silently
  adjusts on reload) are flagged, with the nearest exact scale suggested.
- **Preview safely, then save.** *Apply* pushes the layout to the running
  session and starts a 15-second countdown — if you don't confirm (because a
  bad mode blacked out your screens, say), the previous arrangement comes
  back on its own. *Save* writes to `monitors.lua` so it survives a reboot.
- **Themed.** Every colour, font, and spacing value comes from the shell's
  `Style` and `Color` singletons, so it follows `omarchy theme set` without
  carrying a palette of its own.
- **Warns about the things that actually break layouts** — see below.

## Requirements

- **Omarchy 4.x.** The widget is a shell plugin (manifest `schemaVersion` 1)
  and builds its UI from the shell's own components and `Style`/`Color`
  singletons — those are internal shell API, so a much older or newer shell
  may not load it. Developed against Omarchy 4.0.1 with Quickshell 0.3.1.
- **Omarchy's Lua Hyprland config.** Live preview runs `hyprctl eval` with
  `hl.monitor(...)` calls and saving writes `~/.config/hypr/monitors.lua`.
  An install configured with classic `hyprland.conf` syntax will not work.

No other dependencies: no extra packages, and nothing is assumed about the
hardware — connector naming, mixed scales, portrait displays, and identical
twin monitors are all handled. So far it has been exercised on a single
three-display setup, so reports from other arrangements are very welcome.

## Install

```bash
omarchy plugin add https://github.com/tzglobic/omarchy-monitor-arranger.git --enable
```

Or clone into place and rescan:

```bash
git clone https://github.com/tzglobic/omarchy-monitor-arranger.git \
  ~/.config/omarchy/plugins/tzglobic.monitor-arranger
omarchy-shell shell rescanPlugins
omarchy plugin enable tzglobic.monitor-arranger --section right
```

## Uninstall

```bash
omarchy plugin remove tzglobic.monitor-arranger
```

The plugin leaves two things behind, both yours to keep or delete: the
generated block in `~/.config/hypr/monitors.lua` (everything between the
`-- >>> omarchy-monitor-arranger >>>` markers — your arrangement keeps
working without the plugin) and the backups in
`~/.local/state/omarchy/monitor-arranger/`.

## How it writes your config

Everything the widget generates lives inside a marked block:

```lua
-- >>> omarchy-monitor-arranger >>>
hl.monitor({ output = "desc:Acme Inc. ACME Q27", mode = "2560x1440@60",
             position = "4608x0", scale = 1.25, transform = 1 })
-- <<< omarchy-monitor-arranger <<<
```

Anything outside those markers is yours and is never touched. Saving replaces
the block in place; it never stacks a second one. Each save first copies the
current file into `~/.local/state/omarchy/monitor-arranger/` (last 10 kept).

Three deliberate choices are worth knowing about:

**The block goes last in the file.** Hyprland applies monitor rules in file
order, so a wildcard `hl.monitor({ output = "", position = "auto" })` earlier
in your config cannot override the arrangement.

**Every display is pinned, including ones you did not move.** Leaving any
monitor on `position = "auto"` makes Hyprland reflow it around the pinned ones
on the next reload, which quietly undoes the arrangement.

**External displays are matched by description, not connector name.**
Connector names are not stable — the same monitor can enumerate as `DP-1` one
day and `DP-3` after a replug or a dock change, and a rule keyed on the name
stops matching after the first one. Internal panels are the exception:
`eDP-1` never changes, while its description is an opaque vendor code.

## Two Omarchy specifics this handles

**Mirroring silently overrides saved layouts.** `SUPER + CTRL + ALT + Delete`
toggles laptop mirroring by writing a rule into
`~/.local/state/omarchy/toggles/hypr/internal-monitor-mirror.lua`. Omarchy
loads `default.hypr.toggles` *after* `hypr.monitors`, so while that toggle is
latched it overrides whatever `monitors.lua` says — including transform and
scale. The widget detects this and offers to clear it.

**Live changes need `hyprctl eval`, not `hyprctl keyword`.** Omarchy
configures Hyprland in Lua, and the Lua parser rejects `keyword` outright:

```
keyword can't work with non-legacy parsers. Use eval.
```

## Scripting

The panel registers an IPC target, so the layout can be driven from a keybind
or a script without opening it:

```bash
omarchy-shell monitor-arranger open       # or close / toggle
omarchy-shell monitor-arranger state      # JSON: bounds, dirty, overlaps
omarchy-shell monitor-arranger arrange    # pack displays left to right
omarchy-shell monitor-arranger preview    # apply to the running session
omarchy-shell monitor-arranger keep       # confirm a preview (stop the countdown)
omarchy-shell monitor-arranger save       # write monitors.lua and reload
omarchy-shell monitor-arranger revert     # back to the pre-preview arrangement
```

`preview` arms the same 15-second auto-revert as the panel's Apply button, so
a script (or keybind) that wants the change to stick must follow up with
`keep` or `save` — the safety net is the point: a preview that produced a
black screen undoes itself.

The file-writing half is a standalone script and is useful on its own:

```bash
bin/omarchy-monitor-arranger status       # is the mirror toggle latched?
bin/omarchy-monitor-arranger mirror-off   # clear it
```

## Layout

| Path | Role |
|------|------|
| `Panel.qml` | Bar button, panel, canvas, and controls |
| `Model.js` | Pure layout logic — geometry, snapping, Lua generation |
| `bin/omarchy-monitor-arranger` | Reads and writes `monitors.lua`; owns the splice |
| `test/model.test.js` | Layout logic, run with `node` |
| `test/splice.test.sh` | Config read/modify/write against a throwaway file |

`Model.js` holds no QML imports and no side effects, so the same code runs
under Quickshell's JS engine and under `node`.

The splice lives in the shell script rather than in QML on purpose: the config
has to be read at the moment it is written. Reading it in QML and holding the
contents until the user hits Save loses any edit made in between — which it
did, until `test/splice.test.sh` started covering that case.

## Tests

```bash
node test/model.test.js
bash test/splice.test.sh
```

Neither touches your real config or the running compositor.

## Developing

The shell only hot-reloads plugins under `~/.config/omarchy/plugins/`, and it
does not follow symlinks out of that directory. If you develop the repo
elsewhere and symlink it in, apply changes with:

```bash
omarchy restart shell
```

## License

MIT
