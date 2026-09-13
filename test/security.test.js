// Run with: node test/security.test.js (requires Lua 5.1+; LUA may override it).
// Execute generated code in a restricted Lua environment. Payloads only set
// a boolean sentinel; no compositor, user config or shell commands are used.
var assert = require("assert")
var spawnSync = require("child_process").spawnSync
var M = require("../Model.js")
var lua = process.env.LUA || "lua"
var cases = 0

// Independent oracle: construct expected strings from UTF-8 bytes, without
// using the encoder being tested. Small chunks avoid Lua's argument limit.
function bytes(value) {
  var buf = Buffer.from(value, "utf8")
  var parts = []
  for (var i = 0; i < buf.length; i += 64) {
    parts.push("string.char(" + Array.from(buf.subarray(i, i + 64)).join(",") + ")")
  }
  return parts.length ? parts.join(" .. ") : '""'
}

function runLua(script) {
  var result = spawnSync(lua, ["-"], { input: script, encoding: "utf8" })
  if (result.error) throw result.error
  assert.strictEqual(result.status, 0, result.stderr)
  cases++
}

function evaluate(source, expected) {
  var script = [
    "local calls = {}",
    "local env = { injected = false, hl = { monitor = function(m) calls[#calls+1] = m end } }",
    "local source = " + bytes(source),
    "local chunk",
    "if setfenv then chunk = assert(loadstring(source)); setfenv(chunk, env)",
    "else chunk = assert(load(source, 'generated', 't', env)) end",
    "chunk()",
    "assert(env.injected == false, 'metadata executed as Lua')",
    "assert(#calls == " + expected.length + ", 'wrong monitor call count')"
  ]
  expected.forEach(function(fields, index) {
    Object.keys(fields).forEach(function(key) {
      var value = fields[key]
      script.push("assert(calls[" + (index + 1) + "][" + bytes(key) + "] == " +
        (typeof value === "string" ? bytes(value) : String(value)) + ", 'field changed: " + key + "')")
    })
  })
  runLua(script.join("\n"))
}

function monitor(overrides) {
  return Object.assign({ name: "DP-1", make: "Acme", model: "Panel", enabled: true,
    internal: false, pixelWidth: 1920, pixelHeight: 1080, refresh: 60,
    x: 0, y: 0, scale: 1, transform: 0 }, overrides)
}

var payloads = [
  'Panel "quoted"', "Panel 'quoted'", "Panel \\path\\123", "Panel\nnew line",
  "Panel\rnew line", "Panel\r\nnew line", "Panel\tTabbed", "Panel\u00001",
  "Panel\u007f", "Panel\u2028line\u2029end", "Écran 日本語",
  '"}); injected = true; --', "X\ninjected = true\n--",
  "X\rinjected = true\r--", "X\n" + M.BLOCK_END + "\ninjected = true\n--",
  "]]; injected = true; --", "]=]; injected = true; --"
]

payloads.concat(["", String.fromCharCode.apply(null, Array.from({length: 128}, function(_, i) { return i }))]).forEach(function(value) {
  evaluate("hl.monitor({ output = " + M.luaString(value) + " })", [{ output: value }])
})

payloads.forEach(function(value) {
  ;["make", "model"].forEach(function(field) {
    ;[true, false].forEach(function(enabled) {
      var m = monitor({ enabled: enabled })
      m[field] = value
      var key = /[\x00-\x1f\x7f-\x9f\u2028\u2029]/.test(value)
        ? m.name : "desc:" + (m.make + " " + m.model).trim().replace(/\s+/g, " ")
      var expected = enabled ? { output: key, mode: "1920x1080@60", position: "0x0", scale: 1 }
        : { output: key, disabled: true }
      var cmd = M.evalCommand(m, [m])
      assert.deepStrictEqual(cmd.slice(0, 2), ["hyprctl", "eval"])
      evaluate(cmd[2], [expected])
      var block = M.luaBlock([m], value)
      assert.strictEqual(block.split("\n").filter(function(line) { return line === M.BLOCK_END }).length, 1)
      evaluate(block, [expected])
    })
  })
})

;["", "DP-1\n", "DP-1\r", "DP 1", "desc:Panel", "*", "DP,1", "DP-\\1",
  'DP-1"}); injected = true; --', "DP-\u0000", "A".repeat(129), null, 42].forEach(function(name) {
  ;[true, false].forEach(function(internal) {
    ;[true, false].forEach(function(enabled) {
      var bad = monitor({ name: name, internal: internal, enabled: enabled })
      assert.throws(function() { M.outputKey(bad, [bad]) }, /connector/)
      assert.throws(function() { M.evalCommands([monitor(), bad]) }, /connector/)
      assert.throws(function() { M.luaBlock([monitor(), bad]) }, /connector/)
    })
  })
})

;["eDP-1", "LVDS-1", "DSI-1", "DP-1-2", "HDMI-A-1", "Virtual-1", "HEADLESS-1"].forEach(function(name) {
  var m = monitor({ name: name, make: "", model: "" })
  evaluate(M.monitorLua(m, [m]), [{ output: name }])
})
var twins = [monitor(), monitor({ name: "DP-2" })]
evaluate(M.luaBlock(twins), [{ output: "DP-1" }, { output: "DP-2" }])
var internal = monitor({ name: "eDP-1", internal: true, model: "X\ninjected=true\n--" })
evaluate(M.luaBlock([internal]), [{ output: "eDP-1" }])
var mode = monitor({ pixelWidth: '1920"}); injected=true; --' })
evaluate(M.monitorLua(mode, [mode]), [{ mode: mode.pixelWidth + "x1080@60" }])
console.log("security tests passed (" + cases + " Lua executions plus identifier rejection checks)")
