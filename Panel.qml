import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

// Drag-to-arrange display layout for Omarchy. Reads the live arrangement from
// Hyprland, lets the user rearrange it on a scale canvas, previews changes
// with `hyprctl eval`, and persists them into ~/.config/hypr/monitors.lua.
Panel {
  id: root
  moduleName: "tzglobic.monitor-arranger"
  ipcTarget: "monitor-arranger"
  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits, and expose the layout actions as scriptable methods alongside
  // the usual open/close.
  manageIpc: false

  // `monitors` is the working copy the canvas edits; `liveMonitors` is the
  // last state read back from Hyprland. Revert restores one from the other,
  // and their difference is what makes the Apply/Save buttons meaningful.
  property var monitors: []
  property var liveMonitors: []
  property int selectedIndex: 0
  property bool dirty: false
  property bool mirrorLatched: false
  property string statusMessage: ""
  property string statusKind: "info"   // info | warn | error

  // Live drag state. Held on the root rather than inside the tile so that a
  // drag never has to write back into `monitors` — see MonitorTile.
  property int dragIndex: -1
  property real dragX: 0
  property real dragY: 0
  // Logical coordinate of the currently snapped edge, or null. Drawn as a
  // guide line on the canvas so the user can see what the tile latched onto.
  property var dragEdgeX: null
  property var dragEdgeY: null

  // IPC `arrange` wants fresh data, but the refresh is async: latch the
  // request and run it when the read lands, instead of arranging stale state.
  property bool pendingArrange: false

  // Apply safety net. The live arrangement as it was before Apply, and the
  // seconds left before it is restored unless the user confirms. Applying a
  // bad mode can black out every display, so an unconfirmed Apply reverts on
  // its own — the countdown must not depend on the panel being open.
  property var applySnapshot: null
  property int revertCountdown: 0

  // Keyboard cursor, mirroring the shell's other panels: a section plus an
  // index inside it, shared with pointer hover so both drive one highlight.
  property bool cursorActive: false
  property string focusSection: "displays"
  property int cursorIndex: 0

  readonly property color fg: root.bar ? root.bar.foreground : Color.popups.text
  readonly property string uiFont: root.bar ? root.bar.fontFamily : Style.font.family

  // Plugin-relative path to the helper. Qt hands back a file:// URL; Process
  // needs a plain path.
  readonly property string pluginDir: {
    var url = String(Qt.resolvedUrl("."))
    if (url.indexOf("file://") === 0) url = url.substring(7)
    return url.replace(/\/$/, "")
  }
  readonly property string helper: pluginDir + "/bin/omarchy-monitor-arranger"

  readonly property var selected: (selectedIndex >= 0 && selectedIndex < monitors.length)
    ? monitors[selectedIndex] : null
  readonly property var layoutBounds: Model.bounds(monitors)
  readonly property var overlapPairs: Model.overlaps(monitors)
  readonly property bool hasOverlap: overlapPairs.length > 0

  // Displays mirroring another output (beyond Omarchy's own internal-mirror
  // toggle, which has its own notice). monitorLua writes plain positioned
  // rules, so saving converts these to extended — warn before that happens.
  readonly property var mirroredDisplays: {
    var out = []
    for (var i = 0; i < monitors.length; i++) {
      var m = monitors[i]
      if (m.enabled && m.mirrorOf) out.push(m.name + " mirrors " + m.mirrorOf)
    }
    return out
  }

  readonly property var scalePresets: [1, 1.25, 1.5, 1.6, 2]
  // Short labels so four buttons fit one row at any font scale; the readable
  // name goes in the tooltip.
  readonly property var transformPresets: [
    { value: 0, label: "Normal", name: "Landscape" },
    { value: 1, label: "90°", name: "Portrait" },
    { value: 2, label: "180°", name: "Landscape, upside down" },
    { value: 3, label: "270°", name: "Portrait, other way up" }
  ]

  // ------------------------------------------------------------- data access

  function refresh() {
    refreshProc.running = true
    statusProc.running = true
  }

  function adoptLive(raw) {
    var parsed = Model.parseMonitors(raw)
    liveMonitors = parsed
    // Never adopt mid-drag: reassigning `monitors` rebuilds the Repeater's
    // delegates and drops the press state out from under the gesture.
    if (!dirty && dragIndex < 0) {
      monitors = Model.copyMonitors(parsed)   // independent copy to edit
      clampSelection()
    }
    if (pendingArrange) {
      pendingArrange = false
      autoArrange()
    }
  }

  function clampSelection() {
    if (monitors.length === 0) { selectedIndex = -1; return }
    if (selectedIndex < 0 || selectedIndex >= monitors.length) selectedIndex = 0
  }

  // QML only re-evaluates bindings when the array property is reassigned, so
  // every edit rebuilds the list rather than mutating an element in place.
  function updateMonitor(index, changes) {
    if (index < 0 || index >= monitors.length) return
    var next = []
    for (var i = 0; i < monitors.length; i++) {
      if (i !== index) { next.push(monitors[i]); continue }
      var copy = {}
      for (var key in monitors[i]) copy[key] = monitors[i][key]
      for (var change in changes) copy[change] = changes[change]
      next.push(copy)
    }
    monitors = next
    dirty = true
    setStatus("", "info")
  }

  function setStatus(message, kind) {
    statusMessage = message
    statusKind = kind || "info"
    if (message === "") statusTimer.stop()
    else statusTimer.restart()
  }

  // Status lines are transient. Left up, they permanently occupy a row of the
  // panel and push the action buttons below the fold.
  Timer {
    id: statusTimer
    interval: 6000
    repeat: false
    onTriggered: root.statusMessage = ""
  }

  // ------------------------------------------------------------- edit actions

  function moveTo(index, x, y) {
    updateMonitor(index, { x: Math.round(x), y: Math.round(y) })
  }

  // Keyboard fine-adjustment: Shift+HJKL moves the selected display by a
  // step small enough to matter after a drag has done the coarse work.
  readonly property int nudgeStep: 10
  function nudgeSelected(dx, dy) {
    var m = selected
    if (!m || !m.enabled) return
    moveTo(selectedIndex, m.x + dx * nudgeStep, m.y + dy * nudgeStep)
  }

  function setTransform(index, transform) {
    updateMonitor(index, { transform: transform })
  }

  function setScale(index, scale) {
    updateMonitor(index, { scale: scale })
  }

  function setMode(index, label) {
    var match = String(label).match(/^(\d+)x(\d+)@(\d+)$/)
    if (!match) return
    updateMonitor(index, {
      pixelWidth: parseInt(match[1], 10),
      pixelHeight: parseInt(match[2], 10),
      refresh: parseInt(match[3], 10)
    })
  }

  function toggleEnabled(index) {
    var monitor = monitors[index]
    if (!monitor) return
    // Refuse to switch off the last display: recovering from that needs a TTY.
    if (monitor.enabled && Model.enabledOnly(monitors).length <= 1) {
      setStatus("Can't disable the only active display.", "error")
      return
    }
    updateMonitor(index, { enabled: !monitor.enabled })
  }

  function autoArrange() {
    monitors = Model.normalizeOrigin(Model.autoArrange(monitors))
    dirty = true
    setStatus("Packed left to right — apply to preview.", "info")
  }

  function revert() {
    // Mid-countdown the live session already shows the applied layout, so
    // "revert" means the pre-Apply snapshot: put it back on screen and in
    // the working copy both.
    if (applySnapshot) {
      monitors = Model.copyMonitors(applySnapshot)
      dirty = false
      clampSelection()
      restoreSnapshot("Reverted to the previous arrangement.", "info")
      return
    }
    // copyMonitors, not parseMonitors: liveMonitors is already parsed, and
    // re-parsing it zeroes every display (see Model.copyMonitors).
    monitors = Model.copyMonitors(liveMonitors)
    dirty = false
    clampSelection()
    setStatus("Reverted to the live arrangement.", "info")
  }

  // ------------------------------------------------------------- apply / save

  // One shell invocation for a whole monitor list. `set -e` so the first
  // rejected line aborts the batch and surfaces as a nonzero exit code
  // (hyprctl eval exits 7 on a bad mode or Lua error).
  function evalScriptFor(list) {
    var commands = Model.evalCommands(list)
    var script = ["set -e"]
    for (var i = 0; i < commands.length; i++) {
      script.push("hyprctl eval " + shellQuote(commands[i][2]))
    }
    return ["bash", "-c", script.join("\n")]
  }

  // Hyprland lays monitors out in file order, so a monitor still sitting where
  // another one is being moved to would collide mid-apply. Normalizing to the
  // origin first keeps the whole batch inside positive coordinates.
  function applyLive() {
    if (hasOverlap) {
      setStatus("Displays overlap — move them apart first.", "error")
      return
    }
    monitors = Model.normalizeOrigin(monitors)
    // A second Apply during the countdown keeps the original snapshot: the
    // state worth going back to is the one from before the first Apply.
    if (!applySnapshot) applySnapshot = Model.copyMonitors(liveMonitors)
    revertCountdown = 0
    applyProc.command = evalScriptFor(monitors)
    applyProc.running = true
  }

  function keepApplied() {
    revertCountdown = 0
    applySnapshot = null
    setStatus("Arrangement kept — save to make it permanent.", "info")
  }

  // Push the pre-Apply snapshot back to the compositor. Used by the countdown
  // timeout, by a failed Apply, and by Revert while a countdown is running.
  function restoreSnapshot(message, kind) {
    revertCountdown = 0
    if (!applySnapshot) return
    restoreProc.command = evalScriptFor(applySnapshot)
    restoreProc.running = true
    applySnapshot = null
    setStatus(message, kind)
  }

  function shellQuote(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'"
  }

  function save() {
    if (hasOverlap) {
      setStatus("Displays overlap — move them apart first.", "error")
      return
    }
    // Saving is the strongest form of "keep": cancel any pending auto-revert.
    revertCountdown = 0
    applySnapshot = null
    monitors = Model.normalizeOrigin(monitors)

    var stamp = Qt.formatDateTime(new Date(), "yyyy-MM-dd HH:mm")
    var block = Model.luaBlock(monitors, stamp)

    // Only the generated block crosses this boundary. The helper reads
    // monitors.lua and splices at write time, so an edit made to the file
    // while this panel has been open is not clobbered.
    // $0 is a label, $1 the helper path, $2 the block. The -x probe catches
    // the common broken install (copied without the executable bit) with a
    // named error instead of a silent failure.
    saveProc.command = ["bash", "-c",
      '[ -x "$1" ] || { echo missing-helper; exit 0; }\nprintf "%s\\n" "$2" | "$1" save',
      "arranger", root.helper, block]
    saveProc.running = true
  }

  function clearMirror() {
    mirrorProc.command = [root.helper, "mirror-off"]
    mirrorProc.running = true
  }

  // ------------------------------------------------------------- keyboard nav

  function sectionCount(section) {
    if (section === "displays") return monitors.length
    if (section === "rotation") return transformPresets.length
    if (section === "actions") return 4
    return 0
  }

  readonly property var sectionOrder: ["displays", "rotation", "actions"]

  function moveCursor(delta) {
    if (!cursorActive) { cursorActive = true; return }
    var order = sectionOrder
    var at = order.indexOf(focusSection)
    if (at < 0) at = 0

    // Vertical movement walks rows inside the display list, then steps
    // between sections. The rotation and action rows are single rows, so
    // j/k passes straight through them.
    if (focusSection === "displays") {
      var next = cursorIndex + delta
      if (next >= 0 && next < monitors.length) { cursorIndex = next; selectedIndex = next; return }
    }
    var target = at + (delta > 0 ? 1 : -1)
    if (target < 0 || target >= order.length) return
    focusSection = order[target]
    cursorIndex = (focusSection === "displays")
      ? Math.max(0, Math.min(monitors.length - 1, selectedIndex)) : 0
    if (focusSection === "displays") selectedIndex = cursorIndex
  }

  function moveCursorH(delta) {
    if (!cursorActive) { cursorActive = true; return }
    var max = sectionCount(focusSection) - 1
    if (max < 0) return
    cursorIndex = Math.max(0, Math.min(max, cursorIndex + delta))
    if (focusSection === "displays") selectedIndex = cursorIndex
  }

  function activateCursor() {
    if (focusSection === "displays") { selectedIndex = cursorIndex; return }
    if (focusSection === "rotation") { setTransform(selectedIndex, transformPresets[cursorIndex].value); return }
    if (focusSection === "actions") {
      if (cursorIndex === 0) autoArrange()
      else if (cursorIndex === 1) revert()
      else if (cursorIndex === 2) applyLive()
      else save()
    }
  }

  onOpenedChanged: {
    if (opened) {
      refresh()
      cursorActive = false
      focusSection = "displays"
    }
  }

  // IPC callers can act on the layout without ever opening the panel, so the
  // working copy has to exist from startup, not from first open.
  Component.onCompleted: refresh()

  // ------------------------------------------------------------- ipc

  // Exposed so the arrangement can be driven from a keybind or a script:
  //   omarchy-shell monitor-arranger arrange
  //   omarchy-shell monitor-arranger preview
  //   omarchy-shell monitor-arranger save
  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }

    // The refresh is async: latch the arrange and let adoptLive run it once
    // fresh data lands, instead of arranging a stale working copy (which
    // would also set `dirty` and block the fresh read from being adopted).
    function arrange(): string {
      root.pendingArrange = true
      root.refresh()
      return "arranging"
    }

    // Named `preview`, not `apply`: an IpcHandler function called `apply`
    // collides with Function.prototype.apply and is silently dropped from
    // the registered target.
    function preview(): string {
      if (root.hasOverlap) return "error: displays overlap"
      root.applyLive()
      return "applied"
    }

    // Confirms a pending Apply so the auto-revert countdown stands down.
    function keep(): string {
      if (!root.applySnapshot) return "nothing to keep"
      root.keepApplied()
      return "kept"
    }

    function save(): string {
      if (root.hasOverlap) return "error: displays overlap"
      root.save()
      return "saving"
    }

    function revert(): string {
      root.revert()
      return "reverted"
    }

    function state(): string {
      return JSON.stringify({
        displays: Model.enabledOnly(root.monitors).length,
        bounds: root.layoutBounds,
        dirty: root.dirty,
        mirrorLatched: root.mirrorLatched,
        overlaps: root.overlapPairs,
        revertCountdown: root.revertCountdown
      })
    }
  }

  // ------------------------------------------------------------- processes

  Process {
    id: refreshProc
    command: ["hyprctl", "monitors", "all", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.adoptLive(text)
    }
  }

  Process {
    id: statusProc
    command: [root.helper, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.mirrorLatched = String(text || "").trim() === "mirror-latched"
    }
  }

  Process {
    id: applyProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: applyErrors; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      if (exitCode === 0) {
        // Don't celebrate yet: if the user can't see the result (wrong mode,
        // black screen) the countdown puts everything back on its own.
        root.revertCountdown = 15
      } else {
        console.log("monitor-arranger: apply failed: " + applyErrors.text)
        root.restoreSnapshot("Apply failed — restored the previous arrangement.", "error")
      }
      root.refresh()
    }
  }

  // Applies the pre-Apply snapshot back. Separate from applyProc so a
  // restore's own exit can't be mistaken for a fresh Apply and re-arm the
  // countdown.
  Process {
    id: restoreProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(exitCode, exitStatus) { root.refresh() }
  }

  // Ticks the Apply countdown; runs whether or not the panel is open, since
  // a blacked-out display is exactly the case where it can't be.
  Timer {
    interval: 1000
    repeat: true
    running: root.revertCountdown > 0
    onTriggered: {
      root.revertCountdown--
      if (root.revertCountdown <= 0)
        root.restoreSnapshot("Apply wasn't confirmed — restored the previous arrangement. Your edits are still here.", "warn")
    }
  }

  Process {
    id: saveProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var result = String(text || "").trim()
        if (result === "ok") {
          root.dirty = false
          root.setStatus("Saved to monitors.lua and reloaded.", "info")
        } else if (result === "saved-with-errors") {
          root.dirty = false
          root.setStatus("Saved, but Hyprland reported config errors.", "warn")
        } else if (result === "missing-helper") {
          root.setStatus("Helper missing or not executable: bin/omarchy-monitor-arranger", "error")
        } else {
          root.setStatus("Save failed — see the shell log.", "error")
        }
      }
    }
    onRunningChanged: if (!running) root.refresh()
  }

  Process {
    id: mirrorProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.mirrorLatched = false
        root.setStatus("Mirror toggle cleared — displays are extended again.", "info")
      }
    }
    onRunningChanged: if (!running) root.refresh()
  }

  Timer {
    interval: 4000
    // Never fire mid-drag: adoptLive would reassign `monitors`, rebuild the
    // Repeater's delegates, and drop the press state out of the gesture.
    running: root.opened && !root.dirty && root.dragIndex < 0
    repeat: true
    onTriggered: root.refresh()
  }

  // ------------------------------------------------------------- bar button

  // The bar sizes each slot from its widget's implicit size. Without these the
  // slot collapses to zero width and the icon never appears on the bar, even
  // though the panel itself loads and answers IPC perfectly well.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // A layout grid rather than a monitor glyph: Omarchy's own Display widget
    // usually shares the bar and already owns 󰍹/󰍺, so a monitor icon here
    // would be indistinguishable from it.
    text: "󰕰"
    onPressed: function(b) { root.toggle() }
  }

  // ------------------------------------------------------------- panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.moveCursorH(dx)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      // x mirrors the Active toggle, which pointer users reach in the detail
      // section but keyboard users otherwise can't.
      onDeleteRequested: root.toggleEnabled(root.selectedIndex)
      // Shifted vim keys nudge the selected display; unshifted ones move the
      // cursor via onMoveRequested above.
      onTextKey: function(t) {
        if (t === "H") root.nudgeSelected(-1, 0)
        else if (t === "L") root.nudgeSelected(1, 0)
        else if (t === "K") root.nudgeSelected(0, -1)
        else if (t === "J") root.nudgeSelected(0, 1)
      }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- Hero: icon · title · layout summary ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

            Text {
              id: heroIcon
              text: "󰍺"
              color: root.fg
              font.family: root.uiFont
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(12)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.xxs

              Text {
                text: "Display arrangement"
                color: root.fg
                font.family: root.uiFont
                font.pixelSize: Style.font.title
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                text: {
                  var count = Model.enabledOnly(root.monitors).length
                  var box = root.layoutBounds
                  return count + (count === 1 ? " display · " : " displays · ")
                    + box.w + "×" + box.h + " logical px"
                    + (root.dirty ? " · unsaved" : "")
                }
                color: Qt.darker(root.fg, 1.4)
                font.family: root.uiFont
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          // ---------- Canvas ----------
          Rectangle {
            id: canvasFrame
            width: parent.width
            implicitHeight: Style.space(168)
            radius: Style.cornerRadius
            color: Style.normalFillFor(root.fg, Color.accent)
            border.width: Style.normalBorderWidth
            border.color: Style.normalBorderFor(root.fg, Color.accent)
            // A display dragged past the current bounds is clipped to the
            // frame rather than painted over the controls below it.
            clip: true

            // Logical-pixels-to-screen-pixels factor. The bounds are inflated
            // before fitting so there is room to drag a display outside the
            // current arrangement and attach it on the far side.
            readonly property real inset: Style.space(10)
            readonly property real headroom: 1.25
            readonly property real availW: width - inset * 2
            readonly property real availH: height - inset * 2
            readonly property var box: root.layoutBounds
            readonly property real k: {
              if (box.w <= 0 || box.h <= 0) return 0.02
              return Math.min(availW / (box.w * headroom), availH / (box.h * headroom))
            }
            readonly property real drawW: box.w * k
            readonly property real drawH: box.h * k
            readonly property real originX: inset + (availW - drawW) / 2
            readonly property real originY: inset + (availH - drawH) / 2

            Text {
              anchors.centerIn: parent
              visible: Model.enabledOnly(root.monitors).length === 0
              text: "No active displays"
              color: Qt.darker(root.fg, 1.4)
              font.family: root.uiFont
              font.pixelSize: Style.font.bodySmall
            }

            // Snap guides: a line on the edge the dragged tile latched onto.
            // z above the tiles, or the line vanishes exactly where it
            // matters — along the edge shared with the neighbour.
            Rectangle {
              z: 1
              visible: root.dragIndex >= 0 && root.dragEdgeX !== null
              x: canvasFrame.originX + (Number(root.dragEdgeX) - canvasFrame.box.x) * canvasFrame.k
              y: 0
              width: 1
              height: canvasFrame.height
              color: Color.accent
              opacity: 0.7
            }
            Rectangle {
              z: 1
              visible: root.dragIndex >= 0 && root.dragEdgeY !== null
              x: 0
              y: canvasFrame.originY + (Number(root.dragEdgeY) - canvasFrame.box.y) * canvasFrame.k
              width: canvasFrame.width
              height: 1
              color: Color.accent
              opacity: 0.7
            }

            Repeater {
              model: root.monitors

              // Disabled displays stay on the canvas as parked ghosts so they
              // can still be clicked and re-enabled; hiding them left the
              // Active toggle unreachable by pointer.
              MonitorTile {
                required property var modelData
                required property int index
                monitor: modelData
                tileIndex: index
                frame: canvasFrame
              }
            }
          }

          // ---------- Warnings ----------
          //
          // The mirror toggle is the one that bites: Omarchy loads
          // `default.hypr.toggles` after `hypr.monitors`, so while it is
          // latched it overrides whatever this widget writes.
          // The Apply confirmation. Not a transient status: it stays until
          // the user keeps the layout or the countdown restores the old one.
          Notice {
            visible: root.revertCountdown > 0
            icon: "󰔟"
            text: "Keep this arrangement? Reverting in " + root.revertCountdown + "s."
            actionText: "Keep"
            kind: "warn"
            onActivated: root.keepApplied()
          }

          Notice {
            visible: root.mirrorLatched
            icon: "󰍹"
            text: "Laptop mirroring is on. It overrides saved layouts."
            actionText: "Turn off"
            kind: "warn"
            onActivated: root.clearMirror()
          }

          Notice {
            visible: root.hasOverlap
            icon: "󰀦"
            text: {
              if (root.overlapPairs.length === 0) return ""
              var pair = root.overlapPairs[0]
              return "Displays overlap: " + pair[0] + " and " + pair[1] + "."
            }
            actionText: "Auto-arrange"
            kind: "error"
            onActivated: root.autoArrange()
          }

          Notice {
            visible: root.mirroredDisplays.length > 0
            icon: "󰍺"
            text: root.mirroredDisplays.join(" · ")
              + ". Saving writes positioned rules, which turns mirroring into extending."
            kind: "warn"
            actionText: ""
          }

          Notice {
            visible: root.statusMessage !== ""
            // warn shares the alert glyph: its tint is already urgent, and an
            // info icon under an urgent tint reads as a broken theme.
            icon: root.statusKind === "info" ? "󰋼" : "󰀦"
            text: root.statusMessage
            kind: root.statusKind
            actionText: ""
          }

          PanelSeparator { foreground: root.fg }

          // ---------- Selected display ----------
          Column {
            width: parent.width
            spacing: Style.spacing.rowGap
            visible: root.selected !== null

            PanelSectionHeader {
              foreground: root.fg
              fontFamily: root.uiFont
              text: root.selected
                ? Model.shortLabel(root.selected).toUpperCase() + " · " + root.selected.name
                : ""
            }

            Text {
              width: parent.width
              visible: root.selected !== null
              text: root.selected ? Model.outputKey(root.selected, root.monitors) : ""
              color: Qt.darker(root.fg, 1.4)
              font.family: root.uiFont
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Toggle {
              width: parent.width
              label: "Active"
              description: root.selected && root.selected.enabled
                ? "Included in the desktop layout" : "Switched off"
              checked: root.selected ? root.selected.enabled : false
              foreground: root.fg
              fontFamily: root.uiFont
              onClicked: root.toggleEnabled(root.selectedIndex)
            }

            Dropdown {
              width: parent.width
              label: "Resolution"
              foreground: root.fg
              fontFamily: root.uiFont
              enabled: root.selected && root.selected.enabled
              value: root.selected ? Model.currentModeLabel(root.selected) : ""
              options: {
                if (!root.selected) return []
                var out = []
                var modes = root.selected.modes || []
                for (var i = 0; i < modes.length; i++) out.push(Model.modeLabel(modes[i]))
                // A monitor's current mode is not always in availableModes
                // (Hyprland accepts modes the EDID does not advertise).
                var current = Model.currentModeLabel(root.selected)
                if (out.indexOf(current) === -1) out.unshift(current)
                return out
              }
              onChanged: function(value) { root.setMode(root.selectedIndex, value) }
            }

            Dropdown {
              width: parent.width
              label: "Scale"
              foreground: root.fg
              fontFamily: root.uiFont
              enabled: root.selected && root.selected.enabled
              value: root.selected ? Model.formatScale(root.selected.scale) : ""
              options: {
                var out = []
                for (var i = 0; i < root.scalePresets.length; i++)
                  out.push(Model.formatScale(root.scalePresets[i]))
                if (root.selected) {
                  var current = Model.formatScale(root.selected.scale)
                  if (out.indexOf(current) === -1) out.push(current)
                }
                return out
              }
              onChanged: function(value) { root.setScale(root.selectedIndex, parseFloat(value)) }
            }

            // Hyprland silently nudges a scale that doesn't divide the pixel
            // size to an integer, so the saved value and the reloaded value
            // drift apart. Flag it, and suggest the nearest scale that won't.
            Text {
              width: parent.width
              visible: root.selected && root.selected.enabled && !Model.scaleIsExact(root.selected)
              text: {
                if (!root.selected) return ""
                var s = Model.nearestExactScale(root.selected)
                var base = "Scale " + Model.formatScale(root.selected.scale) + " doesn't divide "
                  + root.selected.pixelWidth + "×" + root.selected.pixelHeight
                  + " evenly — Hyprland will adjust it."
                return s !== null ? base + " Closest exact: " + Model.formatScale(s) + "." : base
              }
              color: Qt.darker(root.fg, 1.4)
              font.family: root.uiFont
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            // ---------- Orientation ----------
            Column {
              width: parent.width
              spacing: Style.spacing.labelGap

              PanelSectionHeader {
                foreground: root.fg
                fontFamily: root.uiFont
                text: "ORIENTATION"
              }

              Row {
                id: rotationRow
                width: parent.width
                spacing: Style.spacing.sm
                readonly property real cellWidth:
                  (width - spacing * (root.transformPresets.length - 1)) / root.transformPresets.length

                Repeater {
                  model: root.transformPresets

                  Button {
                    required property var modelData
                    required property int index
                    width: rotationRow.cellWidth
                    text: modelData.label
                    tooltipText: modelData.name
                    fontSize: Style.font.caption
                    foreground: root.fg
                    fontFamily: root.uiFont
                    horizontalPadding: Style.spacing.xs
                    verticalPadding: Style.spacing.controlPaddingY
                    bordered: true
                    enabled: root.selected && root.selected.enabled
                    active: root.selected && (root.selected.transform || 0) === modelData.value
                    hasCursor: root.cursorActive && root.focusSection === "rotation" && root.cursorIndex === index
                    onClicked: root.setTransform(root.selectedIndex, modelData.value)
                    onHovered: function(isHovered) {
                      if (!isHovered) return
                      root.cursorActive = true
                      root.focusSection = "rotation"
                      root.cursorIndex = index
                    }
                  }
                }
              }
            }
          }

          PanelSeparator { foreground: root.fg }

          // ---------- Actions ----------
          Row {
            id: actionRow
            width: parent.width
            spacing: Style.spacing.sm
            readonly property real cellWidth: (width - spacing * 3) / 4

            ActionButton {
              width: actionRow.cellWidth
              text: "Arrange"
              actionIndex: 0
              onClicked: root.autoArrange()
            }
            ActionButton {
              width: actionRow.cellWidth
              text: "Revert"
              actionIndex: 1
              enabled: root.dirty
              onClicked: root.revert()
            }
            ActionButton {
              width: actionRow.cellWidth
              text: "Apply"
              actionIndex: 2
              enabled: !root.hasOverlap
              onClicked: root.applyLive()
            }
            ActionButton {
              width: actionRow.cellWidth
              text: "Save"
              actionIndex: 3
              enabled: !root.hasOverlap
              highlight: true
              onClicked: root.save()
            }
          }

          Text {
            width: parent.width
            text: "Apply previews with auto-revert · Save writes monitors.lua · Shift+HJKL nudges"
            color: Qt.darker(root.fg, 1.4)
            font.family: root.uiFont
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }
    }
  }

  // ------------------------------------------------------------- components

  // A display on the canvas. Position comes from the model, except for the
  // tile currently being dragged: that one reads the root's live drag
  // coordinates instead. Committing every mouse move back into `monitors`
  // would reassign the array, rebuild the Repeater delegates, and drop the
  // press state mid-gesture.
  component MonitorTile: Rectangle {
    id: tile
    property var monitor: null
    property int tileIndex: -1
    property var frame: null

    readonly property bool dragging: root.dragIndex === tileIndex
    readonly property bool isSelected: root.selectedIndex === tileIndex
    readonly property real logicalX: dragging ? root.dragX : (monitor ? monitor.x : 0)
    readonly property real logicalY: dragging ? root.dragY : (monitor ? monitor.y : 0)
    readonly property var logicalSize: monitor ? Model.logicalSize(monitor) : { w: 0, h: 0 }

    // A disabled display has no place in the layout, but hiding it entirely
    // made it unselectable — and its Active toggle unreachable — by pointer.
    // Park it as a small ghost along the frame's bottom edge instead.
    readonly property bool parked: monitor ? !monitor.enabled : false
    readonly property int parkSlot: {
      var n = 0
      for (var i = 0; i < tileIndex && i < root.monitors.length; i++)
        if (root.monitors[i] && !root.monitors[i].enabled) n++
      return n
    }
    readonly property real parkW: Style.space(56)
    readonly property real parkH: Style.space(34)

    x: !frame ? 0 : parked
      ? frame.inset + parkSlot * (parkW + Style.space(6))
      : frame.originX + (logicalX - frame.box.x) * frame.k
    y: !frame ? 0 : parked
      ? frame.height - frame.inset - parkH
      : frame.originY + (logicalY - frame.box.y) * frame.k
    width: !frame ? 0 : (parked ? parkW : logicalSize.w * frame.k)
    height: !frame ? 0 : (parked ? parkH : logicalSize.h * frame.k)

    radius: Style.cornerRadius
    color: isSelected ? Style.selectedFillFor(root.fg, Color.accent)
                      : Style.normalFillFor(root.fg, Color.accent)
    border.width: isSelected ? Math.max(1, Style.space(2)) : Style.normalBorderWidth
    border.color: isSelected ? Color.accent : Style.normalBorderFor(root.fg, Color.accent)
    opacity: parked ? 0.45 : (dragging ? 0.85 : 1.0)

    Behavior on x { enabled: !tile.dragging; NumberAnimation { duration: 90 } }
    Behavior on y { enabled: !tile.dragging; NumberAnimation { duration: 90 } }

    Column {
      anchors.centerIn: parent
      width: parent.width - Style.space(8)
      spacing: 0

      Text {
        width: parent.width
        text: tile.monitor ? Model.shortLabel(tile.monitor) : ""
        color: root.fg
        font.family: root.uiFont
        font.pixelSize: Style.font.caption
        font.bold: tile.isSelected
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        // Hidden on tiles too small to hold two lines of text; parked tiles
        // always show "off" so the ghost explains itself.
        visible: tile.parked || tile.height > Style.space(38)
        text: tile.parked ? "off" : tile.logicalSize.w + "×" + tile.logicalSize.h
        color: Qt.darker(root.fg, 1.4)
        font.family: root.uiFont
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
      }
    }

    MouseArea {
      id: tileMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: tile.parked ? Qt.PointingHandCursor
                               : (pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor)

      property real originLogicalX: 0
      property real originLogicalY: 0
      property point origin

      onPressed: function(mouse) {
        root.selectedIndex = tile.tileIndex
        root.cursorActive = true
        root.focusSection = "displays"
        root.cursorIndex = tile.tileIndex
        // A parked ghost is click-to-select only; there is nowhere sensible
        // to drag a display that occupies no space in the layout.
        if (tile.parked) return
        originLogicalX = tile.monitor.x
        originLogicalY = tile.monitor.y
        origin = mapToItem(tile.frame, mouse.x, mouse.y)
        root.dragX = originLogicalX
        root.dragY = originLogicalY
        root.dragIndex = tile.tileIndex
      }

      onPositionChanged: function(mouse) {
        if (!pressed || root.dragIndex !== tile.tileIndex || !tile.frame || tile.frame.k <= 0) return
        var here = mapToItem(tile.frame, mouse.x, mouse.y)
        var size = tile.logicalSize
        var wanted = {
          x: originLogicalX + (here.x - origin.x) / tile.frame.k,
          y: originLogicalY + (here.y - origin.y) / tile.frame.k,
          w: size.w,
          h: size.h
        }

        var others = []
        for (var i = 0; i < root.monitors.length; i++) {
          if (i === tile.tileIndex || !root.monitors[i].enabled) continue
          others.push(Model.rectOf(root.monitors[i]))
        }

        // Snap tolerance is defined on screen so it feels the same however
        // far the canvas is zoomed out.
        var snapped = Model.snapPosition(wanted, others, Style.space(14) / tile.frame.k)
        var box = tile.frame.box
        root.dragX = Math.max(box.x - size.w, Math.min(box.x + box.w, snapped.x))
        root.dragY = Math.max(box.y - size.h, Math.min(box.y + box.h, snapped.y))
        // Guides only survive if the clamp didn't move the tile off its snap.
        root.dragEdgeX = (snapped.guideX !== null && root.dragX === snapped.x) ? snapped.edgeX : null
        root.dragEdgeY = (snapped.guideY !== null && root.dragY === snapped.y) ? snapped.edgeY : null
      }

      onReleased: {
        if (root.dragIndex !== tile.tileIndex) return
        var x = root.dragX
        var y = root.dragY
        root.dragIndex = -1
        root.dragEdgeX = null
        root.dragEdgeY = null
        if (x !== tile.monitor.x || y !== tile.monitor.y) {
          root.moveTo(tile.tileIndex, x, y)
          root.monitors = Model.normalizeOrigin(root.monitors)
        }
      }

      onCanceled: {
        root.dragIndex = -1
        root.dragEdgeX = null
        root.dragEdgeY = null
      }
    }
  }

  // Inline banner for a condition the user should act on. `kind` picks the
  // tint: warn and error borrow the palette's urgent role so themes stay in
  // control of what "something is wrong" looks like.
  component Notice: Rectangle {
    id: notice
    property string icon: "󰋼"
    property string text: ""
    property string actionText: ""
    property string kind: "info"
    signal activated()

    readonly property color tint: kind === "info" ? root.fg : Color.urgent

    width: parent ? parent.width : 0
    implicitHeight: noticeRow.implicitHeight + Style.spacing.xl
    radius: Style.cornerRadius
    color: Qt.rgba(tint.r, tint.g, tint.b, kind === "error" ? 0.14 : 0.08)
    border.width: Style.normalBorderWidth
    border.color: Qt.rgba(tint.r, tint.g, tint.b, 0.35)

    Row {
      id: noticeRow
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        text: notice.icon
        color: notice.tint
        font.family: root.uiFont
        font.pixelSize: Style.font.subtitle
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        text: notice.text
        color: root.fg
        font.family: root.uiFont
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - Style.space(8) * 2 - Style.space(18)
          - (noticeAction.visible ? noticeAction.width : 0)
      }

      Button {
        id: noticeAction
        visible: notice.actionText !== ""
        text: notice.actionText
        fontSize: Style.font.caption
        foreground: notice.tint
        fontFamily: root.uiFont
        bordered: true
        horizontalPadding: Style.spacing.sm
        verticalPadding: Style.spacing.xs
        anchors.verticalCenter: parent.verticalCenter
        onClicked: notice.activated()
      }
    }
  }

  component ActionButton: Button {
    id: action
    property int actionIndex: -1
    property bool highlight: false

    fontSize: Style.font.caption
    foreground: root.fg
    fontFamily: root.uiFont
    horizontalPadding: Style.spacing.xs
    verticalPadding: Style.spacing.controlPaddingY
    bordered: true
    active: highlight && root.dirty
    opacity: enabled ? 1.0 : 0.4
    hasCursor: root.cursorActive && root.focusSection === "actions" && root.cursorIndex === actionIndex
    onHovered: function(isHovered) {
      if (!isHovered) return
      root.cursorActive = true
      root.focusSection = "actions"
      root.cursorIndex = action.actionIndex
    }
  }
}
