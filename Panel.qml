import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Bar widget for Spotify Wave: a 10-band equalizer plus the desktop spectrum
// visualizer, both driven from one popup panel.
//
// The panel is a view over ~/.local/state/spotify-wave/state.json: the service
// watches the same file, and mutations go through the helper CLI. Nothing here
// talks to Service.qml directly.
Panel {
  id: root
  moduleName: "naimhasim.spotify-wave"
  ipcTarget: "naimhasim.spotify-wave"
  manageIpc: true

  // Bundled helper, resolved relative to this file so the widget works on
  // install without depending on PATH.
  readonly property string scriptDir: Qt.resolvedUrl(".").toString()
    .replace("file://", "").replace(/\/+$/, "")
  readonly property string helper: scriptDir + "/bin/spotify-wave"
  readonly property string stateDir: Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")
  readonly property string settingsPath: stateDir + "/spotify-wave/state.json"

  readonly property var freqs: ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
  readonly property var presetNames: ["Flat", "Bass Boost", "Treble Boost", "Vocal", "Loudness", "Rock"]
  readonly property var styleNames: ["Dots", "Particles", "Bars", "Mirrored", "Wave", "Peaks", "Aurora"]
  readonly property var sourceNames: ["Spotify", "All output"]

  // Mirrors bin/spotify-wave DEFAULTS.
  readonly property var defaultCfg: ({
    eqEnabled: true,
    preamp: 0,
    preset: "Flat",
    bands: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    vizEnabled: true,
    style: "Dots",
    screen: "all",
    sensitivity: 1.0,
    bars: 64,
    height: 320,
    margin: 24,
    dotSize: 6,
    source: "Spotify"
  })

  // Helper-owned state, mirrored here for the UI. The JSON file is the source
  // of truth; `status` repopulates everything on open.
  property bool eqEnabled: true
  property bool sinkPresent: false
  property real preamp: 0
  property var bands: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  property string preset: "Flat"
  property var cfg: root.withDefaults({})

  // Coalescing state for drags.
  property var pendingBands: ({})
  property bool bandsDirty: false
  property bool preampDirty: false
  property var pendingSet: ({})
  property bool setDirty: false
  property bool refreshAfterAction: false
  property var pendingAction: null

  readonly property string statusText: (root.eqEnabled ? "EQ active" : "EQ bypassed")
    + " · " + (root.sinkPresent ? "sink present" : "sink not found")
    + " · " + (root.cfg.vizEnabled ? root.cfg.style + " · " + root.cfg.bars + " bands" : "visualizer off")

  readonly property var screenOptions: {
    var out = [{ value: "all", label: "All screens" }]
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++)
      out.push({ value: String(screens[i].name), label: String(screens[i].name) })
    return out
  }

  function withDefaults(raw) {
    var out = {}
    for (var k in defaultCfg) out[k] = defaultCfg[k]
    var p = raw && typeof raw === "object" ? raw : {}
    for (var k2 in p) if (p[k2] !== undefined && p[k2] !== null) out[k2] = p[k2]
    out.eqEnabled = (out.eqEnabled === true || out.eqEnabled === "true")
    out.vizEnabled = (out.vizEnabled === true || out.vizEnabled === "true")
    out.style = String(out.style || "Dots")
    out.screen = String(out.screen || "all")
    out.source = (String(out.source) === "All output") ? "All output" : "Spotify"
    out.sensitivity = Math.max(0.25, Math.min(3, Number(out.sensitivity) || 1))
    out.bars = Math.max(16, Math.min(64, Math.round(Number(out.bars) || 64)))
    out.height = Math.max(40, Math.min(400, Math.round(Number(out.height) || 320)))
    out.margin = Math.max(0, Math.min(200, Math.round(Number(out.margin) || 24)))
    out.dotSize = Math.max(2, Math.min(24, Math.round(Number(out.dotSize) || 6)))
    return out
  }

  function applySettings(text) {
    var parsed = null
    try { parsed = JSON.parse(String(text || "{}")) } catch (e) { parsed = null }
    root.cfg = root.withDefaults(parsed)
    // Keep the EQ view in sync with the same payload.
    root.eqEnabled = root.cfg.eqEnabled
    root.preamp = Math.round(Number(root.cfg.preamp) || 0)
    var out = []
    for (var i = 0; i < root.freqs.length; i++)
      out.push(Math.round(Number((root.cfg.bands || [])[i]) || 0))
    root.bands = out
    root.preset = String(root.cfg.preset || "Flat")
  }

  // --- helper plumbing -----------------------------------------------------

  function run(proc, parts) {
    var argv = [root.helper].concat(parts)
    var line = argv.map(function(p) { return Util.shellQuote(p) }).join(" ")
    proc.command = ["bash", "-c", line]
    if (!proc.running) proc.running = true
  }

  function refresh() {
    if (!statusProc.running) root.run(statusProc, ["status"])
    if (!findProc.running) root.run(findProc, ["find-node"])
  }

  // --- equalizer -----------------------------------------------------------

  function queueBand(i, v) {
    root.pendingBands[i] = v
    root.bandsDirty = true
    bandTimer.restart()
  }

  function flushBands() {
    bandTimer.stop()
    if (!root.bandsDirty) return
    if (bandProc.running) { bandTimer.restart(); return }
    var parts = ["set"]
    for (var i = 0; i < root.freqs.length; i++) {
      if (root.pendingBands[i] !== undefined) {
        parts.push(String(i))
        parts.push(String(Math.round(Number(root.pendingBands[i]))))
      }
    }
    root.pendingBands = ({})
    root.bandsDirty = false
    if (parts.length > 1) root.run(bandProc, parts)
  }

  function queuePreamp(v) {
    root.preamp = Math.round(Number(v))
    root.preampDirty = true
    preampTimer.restart()
  }

  function flushPreamp() {
    preampTimer.stop()
    if (!root.preampDirty) return
    if (preampProc.running) { preampTimer.restart(); return }
    root.preampDirty = false
    root.run(preampProc, ["preamp", String(Math.round(root.preamp))])
  }

  // Actions are serialized: if one is in flight, defer the latest request and
  // replay it when the process goes idle.
  function runAction(parts) {
    root.refreshAfterAction = true
    if (actionProc.running) { root.pendingAction = parts; return }
    root.run(actionProc, parts)
  }

  function applyPreset(name) {
    root.preset = name
    root.runAction(["preset", name])
  }

  function setBypass(on) {
    root.eqEnabled = !on
    root.runAction([on ? "eq-disable" : "eq-enable"])
  }

  function resetAll() {
    root.runAction(["reset"])
  }

  // --- visualizer ----------------------------------------------------------

  function requestVizEnabled(on) {
    if (on === root.cfg.vizEnabled) return
    var s = {}
    for (var k in root.cfg) s[k] = root.cfg[k]
    s.vizEnabled = on
    root.cfg = s
    root.run(actionProc, ["toggle"])
  }

  function queueSet(key, value) {
    root.pendingSet[key] = String(value)
    root.setDirty = true
    setTimer.restart()
  }

  function flushSet() {
    setTimer.stop()
    if (!root.setDirty) return
    if (setProc.running) { setTimer.restart(); return }
    root.pumpSet()
  }

  function pumpSet() {
    var keys = Object.keys(root.pendingSet)
    if (keys.length === 0) { root.setDirty = false; return }
    var k = keys[0]
    var v = root.pendingSet[k]
    delete root.pendingSet[k]
    root.run(setProc, ["set", k, v])
  }

  function setImmediate(key, value) {
    root.queueSet(key, value)
    root.flushSet()
  }

  Component.onCompleted: {
    // Apply once at load so an existing helper state reaches the sink even
    // before the panel is first opened.
    root.run(applyProc, ["apply"])
    root.refresh()
  }

  onOpenedChanged: if (opened) {
    root.refresh()
    settingsFile.reload()
  }

  // --- processes -----------------------------------------------------------

  Process {
    id: statusProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySettings(text)
    }
  }

  Process {
    id: findProc
    onExited: function(exitCode) { root.sinkPresent = (exitCode === 0) }
  }

  Process {
    id: applyProc
    stdout: StdioCollector { waitForEnd: true }
  }

  Process {
    id: bandProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: if (!running && root.bandsDirty) root.flushBands()
  }

  Process {
    id: preampProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: if (!running && root.preampDirty) root.flushPreamp()
  }

  Process {
    id: actionProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: {
      if (running) return
      if (root.pendingAction !== null) {
        var parts = root.pendingAction
        root.pendingAction = null
        root.run(actionProc, parts)
        return
      }
      if (root.refreshAfterAction) {
        root.refreshAfterAction = false
        root.refresh()
      }
    }
  }

  Process {
    id: setProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: {
      if (running) return
      if (Object.keys(root.pendingSet).length > 0) root.pumpSet()
      else root.setDirty = false
    }
  }

  FileView {
    id: settingsFile
    path: root.settingsPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applySettings(text())
  }

  Timer {
    id: bandTimer
    interval: 70
    onTriggered: root.flushBands()
  }

  Timer {
    id: preampTimer
    interval: 70
    onTriggered: root.flushPreamp()
  }

  Timer {
    id: setTimer
    interval: 70
    onTriggered: root.flushSet()
  }

  // --- bar button ----------------------------------------------------------

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // U+F0FB0, present in the JetBrainsMono Nerd Font the bar resolves to.
    text: "󰾰"
    tooltipText: "Spotify Wave"
    onPressed: function(b) { root.toggle() }
  }

  // --- panel ---------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    contentWidth: panel.fittedContentWidth(Style.space(470))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(680))

    ScrollView {
      id: scrollArea
      anchors.fill: parent
      clip: true
      ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
      ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

      Column {
        id: panelColumn
        width: scrollArea.availableWidth
        spacing: Style.space(14)

        // ---------- Title / status ----------
        Row {
          width: parent.width
          spacing: Style.space(12)

          Text {
            text: "󰾰"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Spotify Wave"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              text: root.statusText
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        // ================== EQUALIZER ==================
        PanelSeparator { foreground: root.bar.foreground }
        PanelSectionHeader {
          text: "EQUALIZER"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
        }

        Row {
          width: parent.width
          spacing: Style.spacing.md

          Text {
            id: preampLabel
            text: "Preamp"
            width: Style.space(84)
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
            anchors.verticalCenter: parent.verticalCenter
          }

          PanelSlider {
            id: preampSlider
            width: parent.width - preampLabel.width - preampValue.width - parent.spacing * 2
            anchors.verticalCenter: parent.verticalCenter
            bar: root.bar
            minimum: -12
            maximum: 12
            step: 1
            integer: true
            value: root.preamp
            onMoved: function(v) { root.queuePreamp(v) }
            onReleased: function(v) { root.queuePreamp(v); root.flushPreamp() }
          }

          Text {
            id: preampValue
            text: (root.preamp > 0 ? "+" : "") + Math.round(root.preamp) + " dB"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignRight
            width: Style.space(52)
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        Item {
          width: parent.width
          height: bandRow.implicitHeight

          Row {
            id: bandRow
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(6)

            Repeater {
              model: root.freqs

              delegate: EqBand {}
            }
          }
        }

        Flow {
          width: parent.width
          spacing: Style.spacing.xs

          Repeater {
            model: root.presetNames

            Button {
              required property string modelData
              text: modelData
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              fontSize: Style.font.caption
              bordered: true
              active: root.preset === modelData
              onClicked: root.applyPreset(modelData)
            }
          }
        }

        Row {
          width: parent.width
          spacing: Style.spacing.sm

          Toggle {
            width: parent.width - resetButton.width - parent.spacing
            label: "Bypass"
            description: root.eqEnabled ? "Equalizer active" : "Equalizer bypassed"
            checked: !root.eqEnabled
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            onClicked: root.setBypass(!root.eqEnabled)
          }

          Button {
            id: resetButton
            text: "Reset"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            fontSize: Style.font.caption
            bordered: true
            anchors.verticalCenter: parent.verticalCenter
            onClicked: root.resetAll()
          }
        }

        // ================== VISUALIZER ==================
        PanelSeparator { foreground: root.bar.foreground }
        PanelSectionHeader {
          text: "VISUALIZER"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
        }

        Toggle {
          width: parent.width
          label: "Visualizer"
          description: root.cfg.vizEnabled ? "Drawing on the desktop" : "Hidden"
          checked: root.cfg.vizEnabled
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          onClicked: root.requestVizEnabled(!root.cfg.vizEnabled)
        }

        Row {
          width: parent.width
          spacing: Style.spacing.md

          Dropdown {
            id: styleDropdown
            width: parent.width - screenDropdown.width - parent.spacing
            label: "Visualizer style"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            options: root.styleNames
            onChanged: function(v) { root.setImmediate("style", v) }
          }

          Dropdown {
            id: screenDropdown
            width: Style.space(200)
            label: "Screen"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            options: root.screenOptions
            onChanged: function(v) { root.setImmediate("screen", v) }
          }

          Binding {
            target: styleDropdown
            property: "value"
            value: root.cfg.style
            restoreMode: Binding.RestoreNone
          }

          Binding {
            target: screenDropdown
            property: "value"
            value: root.cfg.screen
            restoreMode: Binding.RestoreNone
          }
        }

        Row {
          width: parent.width
          spacing: Style.spacing.md

          Dropdown {
            id: sourceDropdown
            width: parent.width
            label: "Source"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            options: root.sourceNames
            onChanged: function(v) { root.setImmediate("source", v) }
          }

          Binding {
            target: sourceDropdown
            property: "value"
            value: root.cfg.source
            restoreMode: Binding.RestoreNone
          }
        }

        NumberRow {
          width: parent.width
          label: "Sensitivity"
          from: 0.25
          to: 3
          step: 0.05
          value: root.cfg.sensitivity
          onEdited: function(v) { root.queueSet("sensitivity", v) }
        }

        NumberRow {
          width: parent.width
          label: "Bands"
          from: 16
          to: 64
          step: 1
          integer: true
          value: root.cfg.bars
          onEdited: function(v) { root.queueSet("bars", v) }
        }

        NumberRow {
          width: parent.width
          label: "Height"
          from: 40
          to: 400
          step: 1
          integer: true
          value: root.cfg.height
          onEdited: function(v) { root.queueSet("height", v) }
        }

        NumberRow {
          width: parent.width
          label: "Margin"
          from: 0
          to: 200
          step: 1
          integer: true
          value: root.cfg.margin
          onEdited: function(v) { root.queueSet("margin", v) }
        }

        NumberRow {
          width: parent.width
          label: "Dot size"
          from: 2
          to: 24
          step: 1
          integer: true
          value: root.cfg.dotSize
          onEdited: function(v) { root.queueSet("dotSize", v) }
        }

        Item { width: parent.width; height: Style.space(4) }
      }
    }
  }

  // One labelled slider row for the visualizer tuning values. Drag updates the
  // label live but only queues a helper call; `released` flushes the debounce.
  component NumberRow: Row {
    id: row
    property string label: ""
    property real from: 0
    property real to: 1
    property real step: 1
    property bool integer: false
    property real value: 0
    signal edited(real value)

    spacing: Style.spacing.md

    Text {
      id: labelText
      text: row.label
      width: Style.space(84)
      color: root.bar.foreground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.body
      anchors.verticalCenter: parent.verticalCenter
    }

    PanelSlider {
      id: slider
      width: row.width - labelText.width - valueText.width - row.spacing * 2
      anchors.verticalCenter: parent.verticalCenter
      bar: root.bar
      minimum: row.from
      maximum: row.to
      step: row.step
      integer: row.integer
      value: row.value
      onMoved: function(v) { row.edited(v) }
      onReleased: function(v) { row.edited(v); root.flushSet() }
    }

    Text {
      id: valueText
      width: Style.space(56)
      text: row.integer ? String(Math.round(slider.liveValue))
        : slider.liveValue.toFixed(2)
      color: root.bar.foreground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.body
      horizontalAlignment: Text.AlignRight
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  // One vertical band slider: track, symmetric fill around 0 dB, handle,
  // value and frequency readouts. Drag emits `queueBand`; the debounce timer
  // in the root coalesces a burst into one helper call.
  component EqBand: Column {
    id: band
    required property int index
    required property string modelData

    width: Style.space(34)
    spacing: Style.space(2)

    Slider {
      id: slider
      orientation: Qt.Vertical
      width: parent.width
      height: Style.space(150)
      from: -12
      to: 12
      stepSize: 1
      snapMode: Slider.SnapAlways
      padding: 0
      onMoved: root.queueBand(band.index, value)
      onPressedChanged: if (!pressed) {
        root.queueBand(band.index, value)
        root.flushBands()
      }

      // Binding instead of a direct `value:` so the Slider's own drag
      // assignment does not destroy the link; external updates (status,
      // presets, reset) still reach an idle slider.
      Binding {
        target: slider
        property: "value"
        value: root.bands[band.index]
        when: !slider.pressed
        restoreMode: Binding.RestoreNone
      }

      background: Item {
        x: (slider.width - width) / 2
        width: Math.max(4, Style.space(6))
        height: slider.height

        Rectangle {
          anchors.fill: parent
          radius: Math.min(width, height) / 2
          color: Style.normalFillFor(root.bar.foreground, Color.accent)
          border.width: 1
          border.color: Style.normalBorderFor(root.bar.foreground, Color.accent)
        }

        Rectangle {
          readonly property real centerY: slider.height / 2
          readonly property real valueY: slider.visualPosition * slider.height
          x: 0
          y: Math.min(centerY, valueY)
          width: parent.width
          height: Math.max(1, Math.abs(centerY - valueY))
          radius: width / 2
          color: root.bar.foreground
        }

        Rectangle {
          y: Math.max(0, Math.round(parent.height / 2 - height / 2))
          width: parent.width
          height: Math.max(1, Style.space(1))
          color: root.bar.background
        }
      }

      handle: Rectangle {
        x: (slider.width - width) / 2
        y: slider.visualPosition * (slider.height - height)
        width: Style.space(12)
        height: Style.space(12)
        radius: width / 2
        color: root.bar.foreground
        border.width: Math.max(1, Style.space(2))
        border.color: root.bar.background
      }
    }

    Text {
      text: (slider.value > 0 ? "+" : "") + Math.round(slider.value)
      color: Qt.darker(root.bar.foreground, 1.4)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignHCenter
      width: parent.width
    }

    Text {
      text: band.modelData
      color: root.bar.foreground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignHCenter
      width: parent.width
    }
  }
}
