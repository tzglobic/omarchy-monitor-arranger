// Pure layout logic for the monitor arranger. No QML imports, no side
// effects: everything here is a plain function over plain data so the same
// code runs under Quickshell's JS engine and under `node test/model.test.js`.
//
// Vocabulary:
//   pixels  — the monitor's own framebuffer, e.g. 2560x1440
//   rotated — pixels after `transform` (90/270 swap the axes)
//   logical — rotated divided by `scale`; this is the coordinate space
//             Hyprland lays monitors out in, and the space this file works in

// Hyprland transforms: 0-3 are 0/90/180/270, 4-7 are the flipped variants of
// the same angles. Every odd value swaps width and height.
function transformSwapsAxes(transform) {
  return (Number(transform) || 0) % 2 === 1
}

function transformLabel(transform) {
  var labels = {
    0: "Landscape", 1: "Portrait", 2: "Landscape (180°)", 3: "Portrait (270°)",
    4: "Flipped", 5: "Flipped 90°", 6: "Flipped 180°", 7: "Flipped 270°"
  }
  return labels[Number(transform) || 0] || "Landscape"
}

function isPortrait(transform) {
  return transformSwapsAxes(transform)
}

function rotatedPixels(monitor) {
  var w = Number(monitor.pixelWidth) || 0
  var h = Number(monitor.pixelHeight) || 0
  return transformSwapsAxes(monitor.transform) ? { w: h, h: w } : { w: w, h: h }
}

// Logical size is what Hyprland actually reserves in the layout. Rounding
// matters: a 3840px display at scale 1.25 is exactly 3072, but odd
// resolutions land on fractions that Hyprland itself rounds.
function logicalSize(monitor) {
  var scale = Number(monitor.scale)
  if (!isFinite(scale) || scale <= 0) scale = 1
  var px = rotatedPixels(monitor)
  return { w: Math.round(px.w / scale), h: Math.round(px.h / scale) }
}

function rectOf(monitor) {
  var size = logicalSize(monitor)
  return {
    x: Number(monitor.x) || 0,
    y: Number(monitor.y) || 0,
    w: size.w,
    h: size.h
  }
}

function bounds(monitors) {
  var active = enabledOnly(monitors)
  if (active.length === 0) return { x: 0, y: 0, w: 0, h: 0 }

  var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity
  for (var i = 0; i < active.length; i++) {
    var r = rectOf(active[i])
    if (r.x < minX) minX = r.x
    if (r.y < minY) minY = r.y
    if (r.x + r.w > maxX) maxX = r.x + r.w
    if (r.y + r.h > maxY) maxY = r.y + r.h
  }
  return { x: minX, y: minY, w: maxX - minX, h: maxY - minY }
}

function enabledOnly(monitors) {
  var out = []
  for (var i = 0; i < (monitors || []).length; i++) {
    if (monitors[i] && monitors[i].enabled) out.push(monitors[i])
  }
  return out
}

// Hyprland tolerates negative coordinates, but a layout anchored at 0,0 is
// far easier to reason about in a config file and in the canvas. Shift the
// whole arrangement so the top-left enabled monitor sits at the origin.
function normalizeOrigin(monitors) {
  var box = bounds(monitors)
  if (box.w === 0 && box.h === 0) return monitors
  if (box.x === 0 && box.y === 0) return monitors

  var out = []
  for (var i = 0; i < monitors.length; i++) {
    var m = shallowCopy(monitors[i])
    m.x = (Number(m.x) || 0) - box.x
    m.y = (Number(m.y) || 0) - box.y
    out.push(m)
  }
  return out
}

function shallowCopy(obj) {
  var out = {}
  for (var key in obj) out[key] = obj[key]
  return out
}

// Deep copy of an already-parsed monitor list. This — not parseMonitors — is
// how to duplicate parsed state: parseMonitors expects raw hyprctl field
// names (width, disabled, availableModes) and running it over its own output
// zeroes every geometry and re-enables disabled displays.
function copyMonitors(monitors) {
  var out = []
  for (var i = 0; i < (monitors || []).length; i++) {
    var m = shallowCopy(monitors[i])
    var modes = []
    for (var j = 0; j < (m.modes || []).length; j++) modes.push(shallowCopy(m.modes[j]))
    m.modes = modes
    out.push(m)
  }
  return out
}

// ------------------------------------------------------------------ parsing

var INTERNAL_CONNECTOR = /^(eDP|LVDS|DSI)-/i

function isInternal(name) {
  return INTERNAL_CONNECTOR.test(String(name || ""))
}

// `hyprctl monitors all -j` reports disabled outputs with zeroed geometry, so
// remember the last known mode from availableModes rather than trusting
// width/height for those.
function parseMonitors(raw) {
  var list
  try {
    list = typeof raw === "string" ? JSON.parse(raw || "[]") : (raw || [])
  } catch (e) {
    return []
  }
  if (!Array.isArray(list)) return []

  var out = []
  for (var i = 0; i < list.length; i++) {
    var m = list[i] || {}
    var modes = parseModes(m.availableModes)
    var width = Number(m.width) || 0
    var height = Number(m.height) || 0
    if ((width === 0 || height === 0) && modes.length > 0) {
      width = modes[0].w
      height = modes[0].h
    }
    out.push({
      name: String(m.name || ""),
      description: String(m.description || ""),
      make: String(m.make || ""),
      model: String(m.model || ""),
      serial: String(m.serial || ""),
      pixelWidth: width,
      pixelHeight: height,
      refresh: Math.round(Number(m.refreshRate) || (modes.length > 0 ? modes[0].hz : 60)),
      x: Number(m.x) || 0,
      y: Number(m.y) || 0,
      scale: Number(m.scale) || 1,
      transform: Number(m.transform) || 0,
      enabled: !m.disabled,
      focused: !!m.focused,
      mirrorOf: m.mirrorOf && m.mirrorOf !== "none" ? String(m.mirrorOf) : "",
      internal: isInternal(m.name),
      modes: modes
    })
  }
  return out
}

// "2560x1440@59.95Hz" -> { w, h, hz }. Duplicates are common (the same mode
// advertised at several refresh rates rounds to one entry); keep the first.
function parseModes(availableModes) {
  var seen = {}
  var out = []
  var list = availableModes || []
  for (var i = 0; i < list.length; i++) {
    var match = String(list[i]).match(/^(\d+)x(\d+)@([\d.]+)/)
    if (!match) continue
    var mode = {
      w: parseInt(match[1], 10),
      h: parseInt(match[2], 10),
      hz: Math.round(parseFloat(match[3]))
    }
    var key = mode.w + "x" + mode.h + "@" + mode.hz
    if (seen[key]) continue
    seen[key] = true
    out.push(mode)
  }
  return out
}

function modeLabel(mode) {
  return mode.w + "x" + mode.h + "@" + mode.hz
}

function currentModeLabel(monitor) {
  return monitor.pixelWidth + "x" + monitor.pixelHeight + "@" + monitor.refresh
}

// ----------------------------------------------------------------- identity
//
// Connector names are not stable: the same external display can enumerate as
// DP-1 one day and DP-3 after a replug or a dock change, and a rule keyed on
// the name silently stops matching after one. Descriptions survive that, so
// external displays are written as `desc:<make> <model>` whenever that is
// unambiguous.
//
// Internal panels are the exception. Their descriptions are opaque vendor
// codes ("Some Corporation 0x1234") while `eDP-1` never changes, so the name
// is both stabler and more readable.
function outputKey(monitor, monitors) {
  if (!monitor) return ""
  if (monitor.internal) return monitor.name

  var desc = descriptionKey(monitor)
  if (!desc) return monitor.name

  var matches = 0
  for (var i = 0; i < (monitors || []).length; i++) {
    if (descriptionKey(monitors[i]) === desc) matches++
  }
  // Two identical panels can only be told apart by connector or serial.
  return matches === 1 ? "desc:" + desc : monitor.name
}

function descriptionKey(monitor) {
  if (!monitor) return ""
  var make = String(monitor.make || "").trim()
  var model = String(monitor.model || "").trim()
  var joined = (make + " " + model).replace(/\s+/g, " ").trim()
  return joined.length > 0 ? joined : ""
}

function shortLabel(monitor) {
  if (!monitor) return ""
  var model = String(monitor.model || "").trim()
  if (model && !/^0x[0-9a-f]+$/i.test(model)) return model
  return monitor.internal ? "Built-in" : monitor.name
}

// ----------------------------------------------------------------- snapping
//
// Dragging is done in logical pixels. Displays want to sit flush — a one-pixel
// gap between two monitors is a dead strip the pointer can fall into, and an
// overlap makes Hyprland reject or silently reflow the layout. So every drag
// resolves to the nearest edge contact or edge alignment within `threshold`.

function snapPosition(dragged, others, threshold) {
  var limit = Number(threshold) > 0 ? Number(threshold) : 40
  // edgeX/edgeY are the logical coordinates of the shared or aligned edge —
  // where the canvas should draw a guide line while this snap is active.
  var best = { x: dragged.x, y: dragged.y, guideX: null, guideY: null, edgeX: null, edgeY: null }
  var bestDx = limit + 1
  var bestDy = limit + 1

  function considerX(value, guide, edge) {
    var delta = Math.abs(value - dragged.x)
    if (delta < bestDx) { bestDx = delta; best.x = value; best.guideX = guide; best.edgeX = edge }
  }
  function considerY(value, guide, edge) {
    var delta = Math.abs(value - dragged.y)
    if (delta < bestDy) { bestDy = delta; best.y = value; best.guideY = guide; best.edgeY = edge }
  }

  // The origin is always a snap target so a lone display can be re-anchored.
  considerX(0, "origin", 0)
  considerY(0, "origin", 0)

  for (var i = 0; i < (others || []).length; i++) {
    var o = others[i]
    if (!o) continue
    considerX(o.x + o.w, "right-of", o.x + o.w)                // attach to the right edge
    considerX(o.x - dragged.w, "left-of", o.x)                 // attach to the left edge
    considerX(o.x, "align-left", o.x)
    considerX(o.x + o.w - dragged.w, "align-right", o.x + o.w)

    considerY(o.y + o.h, "below", o.y + o.h)
    considerY(o.y - dragged.h, "above", o.y)
    considerY(o.y, "align-top", o.y)
    considerY(o.y + o.h - dragged.h, "align-bottom", o.y + o.h)
  }

  if (bestDx > limit) { best.x = dragged.x; best.guideX = null; best.edgeX = null }
  if (bestDy > limit) { best.y = dragged.y; best.guideY = null; best.edgeY = null }
  best.x = Math.round(best.x)
  best.y = Math.round(best.y)
  if (best.edgeX !== null) best.edgeX = Math.round(best.edgeX)
  if (best.edgeY !== null) best.edgeY = Math.round(best.edgeY)
  return best
}

function rectsOverlap(a, b) {
  return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
}

// Any overlap is a hard error: Hyprland will accept the config and then
// produce a layout the user did not ask for, which is worse than refusing.
function overlaps(monitors) {
  var active = enabledOnly(monitors)
  var found = []
  for (var i = 0; i < active.length; i++) {
    for (var j = i + 1; j < active.length; j++) {
      if (rectsOverlap(rectOf(active[i]), rectOf(active[j]))) {
        found.push([active[i].name, active[j].name])
      }
    }
  }
  return found
}

// Lay every enabled display out left to right, top-aligned. The fallback when
// an arrangement has gone wrong, and the starting point for a fresh setup.
function autoArrange(monitors) {
  var out = []
  var cursor = 0
  for (var i = 0; i < monitors.length; i++) {
    var m = shallowCopy(monitors[i])
    if (!m.enabled) { out.push(m); continue }
    m.x = cursor
    m.y = 0
    cursor += logicalSize(m).w
    out.push(m)
  }
  return out
}

// ------------------------------------------------------------------- output

// Must match BLOCK_START / BLOCK_END in bin/omarchy-monitor-arranger, which
// is what actually splices this block into the file.
var BLOCK_START = "-- >>> omarchy-monitor-arranger >>>"
var BLOCK_END = "-- <<< omarchy-monitor-arranger <<<"

function formatScale(scale) {
  var n = Number(scale)
  if (!isFinite(n) || n <= 0) n = 1
  // Trim trailing zeros: 1.25 stays 1.25, 1.00 becomes 1.
  return String(Math.round(n * 1000) / 1000)
}

// Hyprland requires the logical size (pixels / scale) to be an integer and
// silently nudges any scale that misses, so what gets saved is not what
// reloads. Flag those before the user hits Save.
function scaleIsExact(monitor) {
  var scale = Number(monitor.scale)
  if (!isFinite(scale) || scale <= 0) return true
  var px = rotatedPixels(monitor)
  if (px.w <= 0 || px.h <= 0) return true
  var w = px.w / scale
  var h = px.h / scale
  return Math.abs(w - Math.round(w)) < 1e-6 && Math.abs(h - Math.round(h)) < 1e-6
}

// The closest scale to the monitor's current one that divides both dimensions
// to integers AND has a clean 3-decimal form (a suggestion that drifts again
// the moment formatScale writes it to the config is worse than none). The
// search walks the 0.025 lattice from 0.5 to 4 — the scales a person would
// actually type. Returns null only when the monitor has no geometry.
function nearestExactScale(monitor) {
  var scale = Number(monitor.scale)
  if (!isFinite(scale) || scale <= 0) scale = 1
  var px = rotatedPixels(monitor)
  if (px.w <= 0 || px.h <= 0) return null

  var best = null
  var bestDiff = Infinity
  for (var n = 20; n <= 160; n++) {
    var s = Math.round(n * 25) / 1000   // exact 3-decimal representation
    if (Math.abs(s - scale) < 1e-9) continue
    if (!scaleIsExact({ pixelWidth: px.w, pixelHeight: px.h, scale: s, transform: 0 })) continue
    var diff = Math.abs(s - scale)
    if (diff < bestDiff) { bestDiff = diff; best = s }
  }
  return best
}

function monitorLua(monitor, monitors) {
  var output = outputKey(monitor, monitors)
  if (!monitor.enabled) {
    return 'hl.monitor({ output = "' + output + '", disabled = true })'
  }
  var parts = [
    'output = "' + output + '"',
    'mode = "' + currentModeLabel(monitor) + '"',
    'position = "' + (Number(monitor.x) || 0) + "x" + (Number(monitor.y) || 0) + '"',
    "scale = " + formatScale(monitor.scale)
  ]
  if ((Number(monitor.transform) || 0) !== 0) parts.push("transform = " + (Number(monitor.transform) || 0))
  return "hl.monitor({ " + parts.join(", ") + " })"
}

// Every display is pinned explicitly, including ones the user did not move.
// Leaving any monitor on `position = "auto"` makes Hyprland reflow it around
// the pinned ones on the next reload, which quietly undoes the arrangement.
function luaBlock(monitors, timestamp) {
  var lines = []
  lines.push(BLOCK_START)
  lines.push("-- Generated by omarchy-monitor-arranger on " + (timestamp || "unknown date") + ".")
  lines.push("-- Every display is pinned: leaving one on \"auto\" makes Hyprland")
  lines.push("-- reflow it around the pinned ones and undo this arrangement.")
  lines.push("-- Edits here are replaced the next time you save from the widget;")
  lines.push("-- anything outside these markers is left alone.")

  var box = bounds(monitors)
  lines.push("-- Layout: " + box.w + "x" + box.h + " logical px across "
    + enabledOnly(monitors).length + " display(s).")

  for (var i = 0; i < monitors.length; i++) {
    var m = monitors[i]
    var size = logicalSize(m)
    lines.push("")
    lines.push("-- " + shortLabel(m) + " (" + m.name + ")"
      + (m.enabled ? " " + size.w + "x" + size.h + " logical at " + m.x + "," + m.y
                     + (isPortrait(m.transform) ? ", portrait" : "")
                   : " disabled"))
    lines.push(monitorLua(m, monitors))
  }

  lines.push(BLOCK_END)
  return lines.join("\n")
}

// Live preview goes through `hyprctl eval`, not `hyprctl keyword`. Omarchy
// configures Hyprland in Lua, and the Lua parser rejects `keyword` outright
// with "keyword can't work with non-legacy parsers. Use eval."
function evalCommand(monitor, monitors) {
  return ["hyprctl", "eval", monitorLua(monitor, monitors)]
}

function evalCommands(monitors) {
  var out = []
  for (var i = 0; i < monitors.length; i++) out.push(evalCommand(monitors[i], monitors))
  return out
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    transformSwapsAxes: transformSwapsAxes, transformLabel: transformLabel, isPortrait: isPortrait,
    rotatedPixels: rotatedPixels, logicalSize: logicalSize, rectOf: rectOf, bounds: bounds,
    enabledOnly: enabledOnly, normalizeOrigin: normalizeOrigin, isInternal: isInternal,
    copyMonitors: copyMonitors, scaleIsExact: scaleIsExact, nearestExactScale: nearestExactScale,
    parseMonitors: parseMonitors, parseModes: parseModes, modeLabel: modeLabel,
    currentModeLabel: currentModeLabel, outputKey: outputKey, descriptionKey: descriptionKey,
    shortLabel: shortLabel, snapPosition: snapPosition, rectsOverlap: rectsOverlap,
    overlaps: overlaps, autoArrange: autoArrange, formatScale: formatScale,
    monitorLua: monitorLua, luaBlock: luaBlock,
    evalCommand: evalCommand, evalCommands: evalCommands,
    BLOCK_START: BLOCK_START, BLOCK_END: BLOCK_END
  }
}
