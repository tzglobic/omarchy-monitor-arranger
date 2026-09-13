// Exercise the actual QML action functions with process stubs, without a
// compositor. In particular, rejection must preserve the rollback state.
var assert = require("assert")
var fs = require("fs")
var vm = require("vm")
var M = require("../Model.js")
var qml = fs.readFileSync(require("path").join(__dirname, "../Panel.qml"), "utf8")
function action(name) {
  var start = qml.indexOf("  function " + name + "(")
  assert(start >= 0)
  var end = qml.indexOf("\n  }", start)
  return qml.slice(start, end + 4)
}
function context() {
  var m = { name: "DP-1", make: "Acme", model: "Panel", enabled: true,
    pixelWidth: 1920, pixelHeight: 1080, refresh: 60, x: 0, y: 0, scale: 1, transform: 0 }
  var c = {
    Model: M, hasOverlap: false, monitors: [m], liveMonitors: [m],
    applySnapshot: [m], revertCountdown: 12,
    applyProc: {}, saveProc: {}, restoreProc: {},
    root: { helper: "/stub/helper" }, Qt: { formatDateTime: function() { return "2026-09-13" } }
  }
  c.setStatus = function(message, kind) { c.statusMessage = message; c.statusKind = kind }
  vm.createContext(c)
  vm.runInContext(["evalScriptFor", "shellQuote", "applyLive", "save", "restoreSnapshot"].map(action).join("\n"), c)
  return c
}
;["applyLive", "save"].forEach(function(name) {
  var c = context()
  var snapshot = c.applySnapshot
  c.monitors = [Object.assign({}, c.monitors[0], { name: 'DP-1"\ninjected=true' })]
  var monitors = c.monitors
  assert.strictEqual(c[name](), false)
  assert.strictEqual(c.statusKind, "error")
  assert.strictEqual(c.applySnapshot, snapshot)
  assert.strictEqual(c.revertCountdown, 12)
  assert.strictEqual(c.monitors, monitors)
  assert.strictEqual(c.applyProc.running, undefined)
  assert.strictEqual(c.saveProc.running, undefined)
  assert.strictEqual(c.applyProc.command, undefined)
  assert.strictEqual(c.saveProc.command, undefined)

  c = context()
  assert.strictEqual(c[name](), true)
  assert.strictEqual(c[name === "save" ? "saveProc" : "applyProc"].running, true)
})
var c = context()
c.applySnapshot = [Object.assign({}, c.monitors[0], { name: "" })]
assert.strictEqual(c.applyLive(), false, "invalid rollback must prevent preview")
c.restoreSnapshot("restore", "info")
assert.strictEqual(c.restoreProc.running, undefined)
assert(c.applySnapshot, "failed rollback must retain its snapshot")
console.log("panel security action tests passed")
