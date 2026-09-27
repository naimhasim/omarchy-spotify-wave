import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons

// Desktop spectrum visualizer.
//
// Audio is never decoded here: cava runs against the helper-provided config
// and prints one ASCII frame per line ("12;45;...\n"). We parse that on stdout
// and drive a bottom-anchored, click-through layer surface per screen.
//
// Everything the bar widget changes lives in
// ~/.local/state/spotify-wave/state.json, which this service watches.
// The bar widget never talks to this object directly.
Item {
  id: root

  // --- paths ---------------------------------------------------------------

  // Resolved relative to this file so the plugin works from any install dir.
  readonly property string pluginDir: Qt.resolvedUrl(".").toString()
    .replace("file://", "").replace(/\/+$/, "")
  readonly property string cavaConfig: pluginDir + "/config/cava"
  readonly property string helper: pluginDir + "/bin/spotify-wave"
  readonly property string stateDir: Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")
  readonly property string settingsPath: stateDir + "/spotify-wave/state.json"

  // --- settings ------------------------------------------------------------

  // Defaults only apply before the helper has written state.json; they mirror
  // bin/spotify-wave DEFAULTS. The file is the single source of truth shared
  // with Panel.qml.
  readonly property var defaultCfg: ({
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

  property var cfg: root.withDefaults({})
  property bool settingsLoaded: false

  function withDefaults(raw) {
    var out = {}
    for (var k in defaultCfg) out[k] = defaultCfg[k]
    var p = raw && typeof raw === "object" ? raw : {}
    for (var k2 in p) if (p[k2] !== undefined && p[k2] !== null) out[k2] = p[k2]
    out.vizEnabled = (out.vizEnabled === true || out.vizEnabled === "true")
    out.style = String(out.style || "Dots")
    out.screen = String(out.screen || "all")
    out.sensitivity = Math.max(0.25, Math.min(3, Number(out.sensitivity) || 1))
    out.bars = Math.max(16, Math.min(64, Math.round(Number(out.bars) || 64)))
    out.height = Math.max(40, Math.min(400, Math.round(Number(out.height) || 320)))
    out.margin = Math.max(0, Math.min(200, Math.round(Number(out.margin) || 24)))
    out.dotSize = Math.max(2, Math.min(24, Math.round(Number(out.dotSize) || 6)))
    out.source = (String(out.source) === "All output") ? "All output" : "Spotify"
    return out
  }

  function applySettings(text) {
    var parsed = null
    try { parsed = JSON.parse(String(text || "{}")) } catch (e) { parsed = null }
    root.cfg = root.withDefaults(parsed)
    root.settingsLoaded = true
  }

  FileView {
    id: settingsFile
    path: root.settingsPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applySettings(text())
    // Absent file: keep defaults and let retryTimer reload once the helper
    // creates it (FileView cannot watch a file that does not exist yet).
  }

  Timer {
    id: retryTimer
    interval: 2000
    repeat: true
    running: !root.settingsLoaded
    onTriggered: settingsFile.reload()
  }

  // --- cava ----------------------------------------------------------------

  // 0..ascii_max_range from cava's default; the helper's config sets
  // ascii_max_range = 1000.
  readonly property int asciiMax: 1000
  property var levels: []
  property var _smooth: []
  // Per-band falling peak caps for the Peaks style. Mutated in place each
  // frame; bindings re-evaluate because root.levels changes alongside it.
  property var _peak: []
  // Drift phase for the Aurora ribbons; animated by auroraPhase below.
  property real phase: 0
  // Number of bands cava actually emits (read from config/cava) and the last
  // requested bar count, tracked separately: a restart is only worthwhile when
  // the request changes, while rendering always follows what cava sends.
  property int activeBars: 64
  property int lastCfgBars: -1
  property string lastCfgSource: ""
  // Last `source =` actually read from config/cava. The helper resolves the
  // setting against the live sinks, so this can change without the `source`
  // setting changing; cava must restart then.
  property string activeCavaSource: ""
  property bool cavaChecked: false
  property bool cavaAvailable: false
  // Set once bin/spotify-wave ensure-source has finished, so config/cava is
  // resolved before cava starts.
  property bool setupDone: false
  // True while we stop cava on purpose (disable / bars change / teardown) so
  // onRunningChanged can tell an intentional stop from an unexpected death.
  property bool _stopping: false
  // Consecutive source-mismatch heals since the last clean check. Bounds the
  // restart loop when the pipewire fallback keeps winning.
  property int sourceHealCount: 0

  // Computed live (not a binding): inside onCfgChanged a cfg-dependent binding
  // can still hold the pre-change value, which made the process lifecycle lag
  // one toggle behind.
  function shouldRun() {
    return root.setupDone && root.cfg.vizEnabled && root.cavaChecked && root.cavaAvailable
  }

  function zeroLevels(n) {
    var a = []
    for (var i = 0; i < n; i++) a.push(0)
    return a
  }

  function resetLevels() {
    root._smooth = root.zeroLevels(root.activeBars)
    root.levels = root.zeroLevels(root.activeBars)
    root._peak = root.zeroLevels(root.activeBars)
  }

  function levelAt(i) {
    return root.levels[i] || 0
  }

  function peakAt(i) {
    return root._peak[i] || 0
  }

  // Average of a fractional slice [a, b) of the band array, used by Aurora to
  // derive coarse bass/mid/high envelopes without allocating per frame.
  function bandAvg(a, b) {
    var n = root.levels.length
    if (n === 0) return 0
    var lo = Math.max(0, Math.floor(n * a))
    var hi = Math.min(n, Math.ceil(n * b))
    if (hi <= lo) return 0
    var s = 0
    for (var i = lo; i < hi; i++) s += root.levels[i] || 0
    return s / (hi - lo)
  }

  function bass() { return root.bandAvg(0, 0.25) }
  function mid()  { return root.bandAvg(0.25, 0.75) }
  function high() { return root.bandAvg(0.75, 1) }

  // cava emits one frame per stdout line. The first line can carry terminal
  // escape pollution, so any frame whose parsed band count differs from the
  // configured count is dropped rather than resampled.
  function consumeFrame(line) {
    var parts = String(line).split(";")
    var vals = []
    for (var i = 0; i < parts.length; i++) {
      var n = parseInt(parts[i], 10)
      if (Number.isFinite(n)) vals.push(n)
    }
    if (vals.length !== root.activeBars) return
    if (root._smooth.length !== vals.length) {
      root._smooth = root.zeroLevels(vals.length)
      root._peak = root.zeroLevels(vals.length)
    }

    var out = []
    var sens = root.cfg.sensitivity
    for (var j = 0; j < vals.length; j++) {
      var v = (vals[j] / root.asciiMax) * sens
      if (v < 0) v = 0
      else if (v > 1) v = 1
      var prev = root._smooth[j] || 0
      // Asymmetric EMA: fast attack, slow release. Removes dot jitter without
      // adding per-frame animation objects.
      var a = v > prev ? 0.65 : 0.22
      var sm = prev + (v - prev) * a
      root._smooth[j] = sm
      // Peak cap: follow rises instantly, fall by a constant ~0.006/frame.
      root._peak[j] = Math.max(sm, (root._peak[j] || 0) - 0.006)
      out.push(sm)
    }
    root.levels = out
  }

  // Stop cava explicitly: SIGTERM first, then running=false (Quickshell's
  // setter also terminates). A one-shot timer SIGKILLs if it somehow survives.
  function stopCava() {
    sourceCheckTimer.stop()
    cavaBackoffTimer.stop()
    if (!cavaProc.running) return
    cavaProc.signal(15)
    cavaProc.running = false
    cavaKillTimer.restart()
  }

  // One-shot after cava starts: confirm it actually captured the configured
  // source. cava 0.10.7 method=pipewire can silently fall back to the default
  // monitor (stream-restore latch), so a mismatch is healed by a restart.
  function runSourceCheck() {
    if (!root.shouldRun()) return
    if (sourceCheck.running) return
    sourceCheck.running = true
  }

  function syncCava() {
    if (root.shouldRun() && !cavaProc.running) cavaProc.running = true
    else if (!root.shouldRun() && cavaProc.running) {
      root._stopping = true
      root.stopCava()
    }
  }

  // The helper owns config/cava; read its `bars` so the length filter and the
  // strip match what cava really sends even before the helper regenerates the
  // file for a new bar count. Also read `source`: when the resolved monitor
  // changes, cava is restarted to follow it.
  function applyCavaConfig(text) {
    var t = String(text || "")
    var m = t.match(/^\s*bars\s*=\s*(\d+)/m)
    var n = m ? parseInt(m[1], 10) : 0
    if (n > 0) {
      root.activeBars = Math.max(1, Math.min(256, n))
      root.resetLevels()
    }
    var sm = t.match(/^\s*source\s*=\s*([^\s#;]+)/m)
    var src = sm ? sm[1] : ""
    if (src && src !== root.activeCavaSource) {
      var had = root.activeCavaSource !== ""
      root.activeCavaSource = src
      root.sourceHealCount = 0
      if (had && cavaProc.running) {
        // As with a `source` setting change, the restart happens in
        // onRunningChanged once the old process has exited.
        root._stopping = true
        root.stopCava()
      }
    }
  }

  FileView {
    id: cavaConfigFile
    path: root.cavaConfig
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applyCavaConfig(text())
  }

  // Resolve the configured cava source before cava starts. `ensure-source`
  // rewrites config/cava if the resolved monitor differs and prints
  // changed/same; it is a cheap helper call, not a service restart.
  Process {
    id: ensureProc
    command: ["bash", "-c", "exec " + Util.shellQuote(root.helper) + " ensure-source"]
    onExited: function(code) {
      root.setupDone = true
      if (root.cfg.vizEnabled && !root.cavaChecked) cavaCheck.running = true
      root.syncCava()
    }
  }

  // Feature probe: cava present AND the helper's config written. Re-run on
  // enable and by retryTimer when missing (cheap, 10s), never in a tight loop.
  Process {
    id: cavaCheck
    command: ["bash", "-c",
      "command -v cava >/dev/null 2>&1 && test -f " + Util.shellQuote(root.cavaConfig)]
    onExited: function(code) {
      root.cavaChecked = true
      root.cavaAvailable = (code === 0)
      root.syncCava()
    }
  }

  Process {
    id: cavaProc
    command: ["bash", "-c", "exec cava -p " + Util.shellQuote(root.cavaConfig)]
    stdout: SplitParser {
      onRead: function(line) { root.consumeFrame(line) }
    }
    onRunningChanged: {
      if (running) {
        // Give the pipewire link a moment, then verify the capture source.
        if (root.shouldRun()) sourceCheckTimer.restart()
        return
      }
      cavaKillTimer.stop()
      root.resetLevels()
      if (!root.shouldRun()) {
        root._stopping = false
        return
      }
      if (root._stopping) {
        // Intentional stop (bars change): retry promptly once the old
        // process has actually exited.
        root._stopping = false
        cavaRestartTimer.restart()
      } else {
        // Unexpected death: clear availability and re-probe only after a fixed
        // backoff. Probing immediately would re-start cava as fast as it dies
        // (a tight spawn->die loop); the 10s cavaRetryTimer still covers the
        // missing-binary case.
        root.cavaAvailable = false
        cavaBackoffTimer.restart()
      }
    }
  }

  // Source verification. Exit 0 = match (reset the heal budget), 1 = mismatch,
  // 2 = unknown (no cava / no pactl) -> do nothing.
  Process {
    id: sourceCheck
    command: ["bash", "-c", "exec " + Util.shellQuote(root.helper) + " verify-source"]
    onExited: function(code) {
      if (code === 0) { root.sourceHealCount = 0; return }
      if (code !== 1) return
      if (!root.shouldRun()) return
      if (root.sourceHealCount >= 2) {
        console.warn("spotify-wave: cava source mismatch persists")
        return
      }
      root.sourceHealCount += 1
      root._stopping = true
      root.stopCava()
    }
  }

  Timer {
    id: sourceCheckTimer
    interval: 1500
    repeat: false
    onTriggered: root.runSourceCheck()
  }

  Timer {
    id: cavaKillTimer
    interval: 500
    repeat: false
    onTriggered: if (cavaProc.running) cavaProc.signal(9)
  }

  Timer {
    id: cavaRestartTimer
    // Give the helper a beat to regenerate the config with the new bar count
    // before cava re-reads it.
    interval: 200
    onTriggered: root.syncCava()
  }

  // One-shot backoff after an unexpected cava death (see onRunningChanged).
  // The probe runs after ~3s, so repeated instant failures restart cava at
  // most once per backoff instead of back-to-back.
  Timer {
    id: cavaBackoffTimer
    interval: 3000
    repeat: false
    onTriggered: if (root.cfg.vizEnabled && !cavaProc.running) cavaCheck.running = true
  }

  Timer {
    id: cavaRetryTimer
    interval: 10000
    repeat: true
    running: root.cfg.vizEnabled && !root.cavaAvailable
    onTriggered: if (!cavaCheck.running) cavaCheck.running = true
  }

  onCfgChanged: {
    // `bars` and `source` both live in the helper-owned config/cava, so either
    // change means cava must re-read the file.
    var restart = false
    if (root.cfg.bars !== root.lastCfgBars) {
      root.lastCfgBars = root.cfg.bars
      restart = true
    }
    if (root.cfg.source !== root.lastCfgSource) {
      root.lastCfgSource = root.cfg.source
      root.sourceHealCount = 0
      restart = true
    }
    if (restart && cavaProc.running) {
      // Restart happens in onRunningChanged once the old process exits, so
      // the 200 ms timer can never fire while running is still true.
      root._stopping = true
      root.stopCava()
    }
    if (root.cfg.vizEnabled && root.setupDone && !root.cavaChecked) cavaCheck.running = true
    if (!root.cfg.vizEnabled) cavaBackoffTimer.stop()
    root.syncCava()
  }

  Component.onCompleted: {
    root.lastCfgBars = root.cfg.bars
    root.lastCfgSource = root.cfg.source
    root.resetLevels()
    // Resolve config/cava first; cava starts from ensureProc.onExited.
    ensureProc.running = true
  }

  // Teardown: mark the pending cava stop intentional so it does not kick off
  // recovery while shutting down.
  Component.onDestruction: root._stopping = true

  // --- geometry ------------------------------------------------------------

  function slotWidth(w) { return w / Math.max(1, root.activeBars) }
  function centerX(i, w) { return (i + 0.5) * root.slotWidth(w) }

  readonly property Component styleComponent: {
    switch (root.cfg.style) {
      case "Particles": return particlesComponent
      case "Bars": return barsComponent
      case "Mirrored": return mirroredComponent
      case "Peaks": return peaksComponent
      case "Aurora": return auroraComponent
      case "Wave": return null
      case "Dots":
      default: return dotsComponent
    }
  }

  // Every style is loaded by a full-surface Loader (which resizes its item to
  // the Loader's own width/height). So each Component root is a plain Item
  // carrying only bandIndex, and the visible shape is a child that keeps its
  // own width/height/x/y bindings. The root Item is made full-surface by the
  // Loader, so it reads pw/ph from parent and the shape binds to those — never
  // putting a size binding on the root, which the Loader would clobber.
  // (The `surface` id is not reachable here: it lives in a Variants delegate
  // scope, not this document/component scope.)

  // Dots: one filled circle per band, rising and growing with level.
  Component {
    id: dotsComponent
    Item {
      id: dotRoot
      property int bandIndex: 0
      readonly property real lvl: root.levelAt(bandIndex)
      readonly property real r: Math.max(1, root.cfg.dotSize * (0.35 + 0.65 * lvl) / 2)
      readonly property real pw: parent ? parent.width : 0
      readonly property real ph: parent ? parent.height : 0

      Rectangle {
        width: dotRoot.r * 2
        height: dotRoot.r * 2
        radius: dotRoot.r
        x: root.centerX(dotRoot.bandIndex, dotRoot.pw) - dotRoot.r
        y: dotRoot.ph - dotRoot.r - dotRoot.lvl * Math.max(0, dotRoot.ph - 2 * dotRoot.r)
        color: Color.accent
        opacity: 0.4 + 0.6 * dotRoot.lvl
      }
    }
  }

  // Bars: bottom-anchored columns.
  Component {
    id: barsComponent
    Item {
      id: barRoot
      property int bandIndex: 0
      readonly property real lvl: root.levelAt(bandIndex)
      readonly property real pw: parent ? parent.width : 0
      readonly property real ph: parent ? parent.height : 0
      readonly property real w: Math.max(1, root.slotWidth(pw) * 0.66)

      Rectangle {
        width: barRoot.w
        height: Math.max(1, barRoot.lvl * barRoot.ph)
        radius: Math.min(barRoot.w / 2, 3)
        x: root.centerX(barRoot.bandIndex, barRoot.pw) - barRoot.w / 2
        y: barRoot.ph - height
        color: Color.accent
        opacity: 0.45 + 0.55 * barRoot.lvl
      }
    }
  }

  // Mirrored: columns growing both ways from the vertical centre.
  Component {
    id: mirroredComponent
    Item {
      id: mirrorRoot
      property int bandIndex: 0
      readonly property real lvl: root.levelAt(bandIndex)
      readonly property real pw: parent ? parent.width : 0
      readonly property real ph: parent ? parent.height : 0
      readonly property real w: Math.max(1, root.slotWidth(pw) * 0.66)

      Rectangle {
        width: mirrorRoot.w
        height: Math.max(1, mirrorRoot.lvl * mirrorRoot.ph)
        radius: Math.min(mirrorRoot.w / 2, 3)
        x: root.centerX(mirrorRoot.bandIndex, mirrorRoot.pw) - mirrorRoot.w / 2
        y: mirrorRoot.ph / 2 - height / 2
        color: Color.accent
        opacity: 0.5 + 0.5 * mirrorRoot.lvl
      }
    }
  }

  // Peaks: bottom-anchored column plus a falling cap that tracks the maximum.
  Component {
    id: peaksComponent
    Item {
      id: peakRoot
      property int bandIndex: 0
      readonly property real lvl: root.levelAt(bandIndex)
      readonly property real pk: root.peakAt(bandIndex)
      readonly property real pw: parent ? parent.width : 0
      readonly property real ph: parent ? parent.height : 0
      readonly property real w: Math.max(1, root.slotWidth(pw) * 0.66)
      readonly property real capH: Math.max(2, Math.min(3, w * 0.35))

      Rectangle {
        width: peakRoot.w
        height: Math.max(1, peakRoot.lvl * peakRoot.ph)
        radius: Math.min(peakRoot.w / 2, 3)
        x: root.centerX(peakRoot.bandIndex, peakRoot.pw) - peakRoot.w / 2
        y: peakRoot.ph - height
        color: Color.accent
        opacity: 0.45 + 0.55 * peakRoot.lvl
      }

      Rectangle {
        width: peakRoot.w
        height: peakRoot.capH
        radius: peakRoot.capH / 2
        x: root.centerX(peakRoot.bandIndex, peakRoot.pw) - peakRoot.w / 2
        y: peakRoot.ph - peakRoot.capH - peakRoot.pk * Math.max(0, peakRoot.ph - peakRoot.capH)
        color: Color.foreground
        opacity: 0.55 + 0.45 * peakRoot.pk
      }
    }
  }

  // Aurora: a few wide gradient ribbons drifting horizontally. Bass/mid/high
  // averages steer each ribbon's height and opacity; root.phase slowly drifts.
  // Only the first delegate draws — ribbons span the whole surface, so drawing
  // them once avoids 64 identical copies.
  Component {
    id: auroraComponent
    Item {
      id: auroraRoot
      property int bandIndex: 0
      readonly property real pw: parent ? parent.width : 0
      readonly property real ph: parent ? parent.height : 0

      Item {
        id: ribbons
        anchors.fill: parent
        visible: auroraRoot.bandIndex === 0
        opacity: 0.85

        // Bass ribbon: low, warm, strongest movement.
        Rectangle {
          width: ribbons.width
          height: ribbons.height * 0.34
          x: 0
          y: (ribbons.height - height) * (0.60 - 0.30 * root.bass())
            + Math.sin(root.phase) * ribbons.height * 0.04
          opacity: 0.20 + 0.55 * root.bass()
          gradient: Gradient {
            GradientStop { position: 0.0; color: "transparent" }
            GradientStop { position: 0.5; color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.55) }
            GradientStop { position: 1.0; color: "transparent" }
          }
        }

        // Mid ribbon: middle band, opposite drift.
        Rectangle {
          width: ribbons.width
          height: ribbons.height * 0.30
          x: 0
          y: (ribbons.height - height) * (0.42 - 0.24 * root.mid())
            + Math.sin(root.phase + 1.7) * ribbons.height * 0.05
          opacity: 0.16 + 0.48 * root.mid()
          gradient: Gradient {
            GradientStop { position: 0.0; color: "transparent" }
            GradientStop { position: 0.5; color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.45) }
            GradientStop { position: 1.0; color: "transparent" }
          }
        }

        // High ribbon: upper, cool, fastest phase.
        Rectangle {
          width: ribbons.width
          height: ribbons.height * 0.24
          x: 0
          y: (ribbons.height - height) * (0.26 - 0.18 * root.high())
            + Math.sin(root.phase + 3.3) * ribbons.height * 0.06
          opacity: 0.14 + 0.42 * root.high()
          gradient: Gradient {
            GradientStop { position: 0.0; color: "transparent" }
            GradientStop { position: 0.5; color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.40) }
            GradientStop { position: 1.0; color: "transparent" }
          }
        }

        // Top shimmer: blended accent/foreground, phase-only drift.
        Rectangle {
          width: ribbons.width
          height: ribbons.height * 0.18
          x: 0
          y: (ribbons.height - height) * 0.10
            + Math.sin(root.phase * 1.4 + 0.8) * ribbons.height * 0.05
          opacity: 0.12 + 0.22 * (root.mid() + root.high()) * 0.5
          gradient: Gradient {
            GradientStop { position: 0.0; color: "transparent" }
            GradientStop { position: 0.5; color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.30) }
            GradientStop { position: 1.0; color: "transparent" }
          }
        }
      }
    }
  }

  // Particles: a dot plus a short rising trail. Trail dots are static objects
  // whose geometry/opacity are bound to the level, so nothing is created or
  // destroyed per audio frame.
  Component {
    id: particlesComponent
    Item {
      id: part
      property int bandIndex: 0
      readonly property real lvl: root.levelAt(bandIndex)
      readonly property real pw: parent ? parent.width : 0
      readonly property real ph: parent ? parent.height : 0
      readonly property real r: Math.max(1, root.cfg.dotSize * 0.5)
      readonly property real cx: root.centerX(bandIndex, pw)
      readonly property real baseCy: ph - r
      readonly property real travel: Math.max(0, ph - 2 * r)

      Rectangle {
        width: part.r * 2
        height: width
        radius: part.r
        x: part.cx - part.r
        y: part.baseCy - part.r - part.lvl * part.travel
        color: Color.accent
        opacity: 0.5 + 0.5 * part.lvl
      }

      Repeater {
        model: 3
        Rectangle {
          required property int index
          readonly property real k: index + 1
          width: Math.max(1, part.r * 2 * (1 - k / 5))
          height: width
          radius: width / 2
          x: part.cx - width / 2
          y: part.baseCy - part.r - part.lvl * part.travel - k * part.r * 1.1
          color: Color.foreground
          opacity: Math.max(0, part.lvl - k * 0.15) * 0.45
        }
      }
    }
  }

  // Slow drift for the Aurora ribbons; only runs while that style is active.
  NumberAnimation {
    target: root
    property: "phase"
    from: 0
    to: Math.PI * 2
    duration: 14000
    loops: Animation.Infinite
    running: root.cfg.style === "Aurora"
  }

  // --- surfaces ------------------------------------------------------------

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: strip
      required property var modelData

      readonly property bool onThisScreen: root.cfg.screen === "all"
        || root.cfg.screen === modelData.name

      screen: modelData
      visible: root.cfg.vizEnabled && root.cavaAvailable && onThisScreen
      anchors { left: true; right: true; bottom: true }
      implicitHeight: root.cfg.height + 2 * root.cfg.margin
      color: "transparent"

      // Background-layer windows have been observed to lose their committed
      // buffer with updatesEnabled=false; the visualizer animates anyway, so
      // leave updates on (same caution as omarchy.background).
      updatesEnabled: true

      WlrLayershell.namespace: "naimhasim-spotify-wave"
      WlrLayershell.layer: WlrLayer.Bottom
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore

      // Empty input region: the strip is fully click-through, so it never
      // swallows desktop clicks (mirrors omarchy.osd's mask: Region {}).
      mask: Region {}

      Item {
        id: surface
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: root.cfg.margin
        anchors.rightMargin: root.cfg.margin
        anchors.bottomMargin: root.cfg.margin
        height: root.cfg.height

        Repeater {
          model: root.activeBars

          delegate: Loader {
            id: bandLoader
            required property int index
            width: parent.width
            height: parent.height
            sourceComponent: root.styleComponent
            onLoaded: if (item) item.bandIndex = index
          }
        }

        // A hidden layer window releases the Canvas texture and a plain
        // requestPaint() does not bring it back (verified on Qt 6.11), so the
        // Canvas is created only while the strip is actually visible. That
        // makes a re-show behave exactly like first load, when painting works.
        Loader {
          id: waveLoader
          anchors.fill: parent
          active: root.cfg.style === "Wave" && strip.visible
          sourceComponent: waveComponent
        }

        Component {
          id: waveComponent
          Canvas {
            id: waveCanvas
            anchors.fill: parent
            antialiasing: true
            // Both attributes the stroke depends on are explicit reactive
            // properties, so every change (theme accent, dot size) repaints
            // instead of only the current level frame. QML color.toString()
            // yields "#rrggbb", which Canvas accepts verbatim.
            readonly property color waveColor: Color.accent
            readonly property real waveLineWidth: Math.max(1, root.cfg.dotSize * 0.4)
            onWaveColorChanged: requestPaint()
            onWaveLineWidthChanged: requestPaint()
            // The first paint lands before the surface is exposed and has its
            // final size, so defer a repaint past layout. Never rely on
            // onLevelsChanged alone: cava may not have produced a frame yet.
            function repaintSoon() { Qt.callLater(requestPaint) }
            onVisibleChanged: if (visible) repaintSoon()
            Component.onCompleted: repaintSoon()
            onWidthChanged: if (visible) repaintSoon()
            onHeightChanged: if (visible) repaintSoon()
            onPaint: {
              var n = root.activeBars
              var ctx = getContext("2d")
              ctx.clearRect(0, 0, width, height)
              if (n < 2) return
              var lw = waveLineWidth
              ctx.lineWidth = lw
              ctx.lineJoin = "round"
              ctx.strokeStyle = waveColor.toString()
              ctx.beginPath()
              for (var i = 0; i < n; i++) {
                var x = root.centerX(i, width)
                var y = height - lw - root.levelAt(i) * Math.max(0, height - 2 * lw)
                if (i === 0) ctx.moveTo(x, y)
                else ctx.lineTo(x, y)
              }
              ctx.stroke()
            }
            Connections {
              target: root
              function onLevelsChanged() { if (waveCanvas.visible) waveCanvas.requestPaint() }
            }
          }
        }
      }
    }
  }
}
