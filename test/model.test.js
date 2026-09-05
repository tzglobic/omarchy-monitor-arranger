// Run with: node test/model.test.js
var M = require("../Model.js")

var failures = 0
function check(name, actual, expected) {
  var a = JSON.stringify(actual)
  var e = JSON.stringify(expected)
  if (a === e) return
  failures++
  console.error("FAIL " + name + "\n  expected " + e + "\n  actual   " + a)
}
function ok(name, condition) {
  if (condition) return
  failures++
  console.error("FAIL " + name)
}

// A three-display fixture mirroring a laptop + 4K landscape + rotated Dell.
var FIXTURE = [
  { name: "eDP-1", description: "Sharp Corporation 0x1548", make: "Sharp Corporation",
    model: "0x1548", width: 1920, height: 1200, refreshRate: 59.95, x: 0, y: 0,
    scale: 1.25, transform: 0, disabled: false, focused: false,
    availableModes: ["1920x1200@59.95Hz"] },
  { name: "DP-7", description: "Dell Inc. DELL U2722D CFPTS83", make: "Dell Inc.",
    model: "DELL U2722D", width: 2560, height: 1440, refreshRate: 59.951, x: 4608, y: 0,
    scale: 1.25, transform: 1, disabled: false, focused: false,
    availableModes: ["2560x1440@59.95Hz", "1920x1080@60.00Hz", "1920x1080@59.94Hz"] },
  { name: "DP-9", description: "Philips PHL BDM4037U", make: "Philips",
    model: "PHL BDM4037U", width: 3840, height: 2160, refreshRate: 59.996, x: 1536, y: 0,
    scale: 1.25, transform: 0, disabled: false, focused: true,
    availableModes: ["3840x2160@60.00Hz"] }
]

var mons = M.parseMonitors(FIXTURE)

// --- geometry
check("parses all three", mons.length, 3)
check("landscape logical size", M.logicalSize(mons[0]), { w: 1536, h: 960 })
check("portrait swaps axes", M.logicalSize(mons[1]), { w: 1152, h: 2048 })
ok("transform 1 is portrait", M.isPortrait(1))
ok("transform 3 is portrait", M.isPortrait(3))
ok("transform 2 is not portrait", !M.isPortrait(2))
ok("transform 5 (flipped 90) swaps", M.transformSwapsAxes(5))
check("bounds span the desktop", M.bounds(mons), { x: 0, y: 0, w: 5760, h: 2048 })

// --- identity: descriptions beat connector names for externals
check("internal uses connector name", M.outputKey(mons[0], mons), "eDP-1")
check("external uses description", M.outputKey(mons[1], mons), "desc:Dell Inc. DELL U2722D")

// Two identical panels cannot be told apart by description, so fall back.
var twins = M.parseMonitors([
  { name: "DP-1", make: "Dell Inc.", model: "DELL U2722D", width: 2560, height: 1440,
    x: 0, y: 0, scale: 1, transform: 0, disabled: false, availableModes: [] },
  { name: "DP-2", make: "Dell Inc.", model: "DELL U2722D", width: 2560, height: 1440,
    x: 2560, y: 0, scale: 1, transform: 0, disabled: false, availableModes: [] }
])
check("ambiguous descriptions fall back to name", M.outputKey(twins[0], twins), "DP-1")

// --- mode parsing dedupes rounded refresh rates
// 60.00 and 59.94 both round to 60, so they collapse into a single entry;
// genuinely different rates survive.
var modes = M.parseModes(["1920x1080@60.00Hz", "1920x1080@59.94Hz", "1920x1080@50.00Hz"])
check("near-identical refresh rates collapse", modes.length, 2)
check("distinct rates survive", [M.modeLabel(modes[0]), M.modeLabel(modes[1])],
  ["1920x1080@60", "1920x1080@50"])

// --- copying parsed state
// copyMonitors is the only safe way to duplicate a parsed list. Running
// parseMonitors over its own output zeroes geometry and re-enables disabled
// displays (this was the revert() bug), so the copy must be a deep clone.
var copied = M.copyMonitors(mons)
check("copy preserves geometry", M.logicalSize(copied[0]), M.logicalSize(mons[0]))
check("copy preserves modes", copied[1].modes, mons[1].modes)
ok("copy is deep: monitors", copied[0] !== mons[0])
ok("copy is deep: modes", copied[1].modes[0] !== mons[1].modes[0])
copied[0].x = 999
check("copy does not alias the source", mons[0].x, 0)

var disabledCopy = M.copyMonitors(M.parseMonitors([
  { name: "A", width: 1920, height: 1080, x: 0, y: 0, scale: 1, disabled: true, availableModes: [] }
]))
check("copy preserves disabled state", disabledCopy[0].enabled, false)

// --- snapping
var dragged = { x: 4600, y: 12, w: 1152, h: 2048 }
var others = [{ x: 1536, y: 0, w: 3072, h: 1728 }]
var snapped = M.snapPosition(dragged, others, 40)
check("snaps flush to the right edge", snapped.x, 4608)
check("snaps to top alignment", snapped.y, 0)
check("reports the shared vertical edge", snapped.edgeX, 4608)
check("reports the aligned horizontal edge", snapped.edgeY, 0)

var leftSnap = M.snapPosition({ x: 1536 - 1152 + 8, y: 0, w: 1152, h: 2048 }, others, 40)
check("left-of snap puts the guide on the neighbour's left edge", leftSnap.edgeX, 1536)

var far = M.snapPosition({ x: 9000, y: 9000, w: 100, h: 100 }, others, 40)
check("leaves distant drags alone", { x: far.x, y: far.y }, { x: 9000, y: 9000 })
check("no snap means no guides", { ex: far.edgeX, ey: far.edgeY }, { ex: null, ey: null })

// --- scale exactness
ok("1.25 divides 3840x2160", M.scaleIsExact({ pixelWidth: 3840, pixelHeight: 2160, scale: 1.25, transform: 0 }))
ok("1.6 divides 3840x2400", M.scaleIsExact({ pixelWidth: 3840, pixelHeight: 2400, scale: 1.6, transform: 0 }))
ok("1.5 does not divide 2560x1440", !M.scaleIsExact({ pixelWidth: 2560, pixelHeight: 1440, scale: 1.5, transform: 0 }))
ok("exactness follows the rotated axes", M.scaleIsExact({ pixelWidth: 2560, pixelHeight: 1440, scale: 1.25, transform: 1 }))
check("suggests the nearest exact scale", M.nearestExactScale({ pixelWidth: 2560, pixelHeight: 1440, scale: 1.5, transform: 0 }), 1.6)
ok("suggestion is itself exact", M.scaleIsExact({ pixelWidth: 2560, pixelHeight: 1440, scale: M.nearestExactScale({ pixelWidth: 2560, pixelHeight: 1440, scale: 1.5, transform: 0 }), transform: 0 }))
// Awkward panels (1366x768) have almost no exact fractional scales; the
// nearest sane suggestion is integer scale.
check("awkward panels fall back to an integer scale", M.nearestExactScale({ pixelWidth: 1366, pixelHeight: 768, scale: 1.25, transform: 0 }), 1)

// --- overlap detection
var overlapping = M.parseMonitors([
  { name: "A", width: 1920, height: 1080, x: 0, y: 0, scale: 1, disabled: false, availableModes: [] },
  { name: "B", width: 1920, height: 1080, x: 1000, y: 0, scale: 1, disabled: false, availableModes: [] }
])
check("detects overlap", M.overlaps(overlapping).length, 1)
check("clean layout has no overlaps", M.overlaps(mons).length, 0)

// A disabled monitor occupies no space and cannot overlap anything.
var withDisabled = M.parseMonitors([
  { name: "A", width: 1920, height: 1080, x: 0, y: 0, scale: 1, disabled: false, availableModes: [] },
  { name: "B", width: 1920, height: 1080, x: 0, y: 0, scale: 1, disabled: true, availableModes: [] }
])
check("disabled monitors do not overlap", M.overlaps(withDisabled).length, 0)

// --- normalize origin
var shifted = M.normalizeOrigin(M.parseMonitors([
  { name: "A", width: 1920, height: 1080, x: -1920, y: -100, scale: 1, disabled: false, availableModes: [] },
  { name: "B", width: 1920, height: 1080, x: 0, y: -100, scale: 1, disabled: false, availableModes: [] }
]))
check("origin normalized to 0,0", { x: shifted[0].x, y: shifted[0].y }, { x: 0, y: 0 })
check("relative offset preserved", shifted[1].x, 1920)

// --- auto arrange
var arranged = M.autoArrange(mons)
check("auto-arrange packs left to right", [arranged[0].x, arranged[1].x, arranged[2].x], [0, 1536, 2688])
check("auto-arrange has no overlaps", M.overlaps(arranged).length, 0)

// --- lua generation
var block = M.luaBlock(mons, "2026-09-05")
ok("emits portrait transform", block.indexOf("transform = 1") !== -1)
ok("pins every position", block.indexOf('position = "4608x0"') !== -1)
ok("no auto positions leak in", block.indexOf('position = "auto"') === -1)
ok("scale trims trailing zeros", block.indexOf("scale = 1.25") !== -1)

var disabledLua = M.monitorLua({ name: "DP-3", enabled: false, internal: false, make: "Acme", model: "X1" },
  [{ name: "DP-3", make: "Acme", model: "X1" }])
check("disabled monitors emit disabled = true", disabledLua,
  'hl.monitor({ output = "desc:Acme X1", disabled = true })')

// --- eval uses `eval`, never `keyword` (the Lua parser rejects keyword)
var cmd = M.evalCommand(mons[1], mons)
check("eval command shape", [cmd[0], cmd[1]], ["hyprctl", "eval"])
ok("eval carries an hl.monitor call", cmd[2].indexOf("hl.monitor(") === 0)

if (failures > 0) {
  console.error("\n" + failures + " test(s) failed")
  process.exit(1)
}
console.log("all model tests passed")
