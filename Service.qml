import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import Qt5Compat.GraphicalEffects

// Idle Fade
//
// The first-party omarchy.idle service jumps straight from "lit" to
// screensaver to lock. This service adds the ramp in between: once the
// session has been idle for `startSeconds`, the backlight walks down a
// perceptual curve over `durationSeconds` until it sits at `minPercent`
// of the panel maximum. Any real activity restores the level that was in
// use when the fade began.
//
// Smoothness is paced by perceived change, not by the clock. The eye needs
// roughly a 1% relative change to notice a step, so the ramp ticks cheaply
// and only spends a `brightnessctl` call (~4ms) once the target has drifted
// `stepPercent` away from what the panel is showing. Steps end up sparse
// while the screen is bright and dense near the floor, which is where an
// evenly-timed ramp visibly chunks.
//
// A vignette overlay closes in alongside the backlight ramp, so the screen
// darkens from the edges toward the middle rather than uniformly. It is a
// click-through layer-shell surface per screen, which also gives external
// monitors a fade even though only the internal panel has a backlight.
Item {
  id: root

  // Declared so the plugin loader can inject them; unused otherwise.
  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"
  readonly property string configPath: home + "/.config/omarchy/idle-fade.json"
  readonly property string statePath: runtimeDir + "/omarchy-idle-fade.state"
  readonly property string stayAwakeDir: home + "/.local/state/omarchy/indicators"
  readonly property string screensaverClass: "org.omarchy.screensaver"

  property var config: ({})
  property bool stayAwake: false
  property int maxLevel: 0
  property int startLevel: -1
  property int lastWritten: -1
  property real lastWriteAt: 0
  property int writeCount: 0
  property real fadeStartedAt: 0
  property real fadeDurationMs: 0
  property bool fading: false
  property bool previewing: false
  property var screensaverWindows: ({})
  property int screensaverWindowCount: 0
  property real vignetteProgress: 0
  property real maxProgress: 0
  property bool waking: false
  property real eyeOpen: 0
  property real eyeWidth: 0
  property real wakeVeil: 1
  property var wakeFrames: []
  property int wakeIndex: 0
  property var wakeFrom: ({})
  property real wakeFrameStartedAt: 0
  property real wakeStartedAt: 0
  property real wakeTotalMs: 0
  property int wakeFromLevel: -1
  property bool released: false
  property bool vignetteShowing: false
  property string lastEvent: "starting"
  property string lastEventAt: ""

  function clampNum(value, fallback, lo, hi) {
    var n = Number(value)
    if (!isFinite(n)) n = fallback
    return Math.min(hi, Math.max(lo, n))
  }

  // ------------------------------------------------------------- config
  readonly property bool configEnabled: config.enabled === undefined ? true : !!config.enabled
  readonly property int startSeconds: Math.round(clampNum(config.startSeconds, 60, 5, 7200))
  readonly property int durationSeconds: Math.round(clampNum(config.durationSeconds, 240, 5, 7200))
  readonly property real minPercent: clampNum(config.minPercent, 1, 0, 100)
  readonly property real curve: clampNum(config.curve, 1.6, 0.2, 8)
  readonly property int tickMs: Math.round(clampNum(config.tickMs, 50, 16, 2000))
  readonly property real stepPercent: clampNum(config.stepPercent, 0.5, 0.05, 20)
  readonly property int minWriteMs: Math.round(clampNum(config.minWriteMs, 25, 5, 2000))
  readonly property string device: String(config.device || "")

  // An app holding a Wayland idle-inhibitor blocks idle entirely. Browsers
  // and editors hold one far more often than people expect, so allow
  // opting out rather than silently never dimming.
  readonly property bool respectInhibitors:
    config.respectInhibitors === undefined ? true : !!config.respectInhibitors

  readonly property var vignetteConfig: config.vignette || ({})
  readonly property bool vignetteEnabled: vignetteConfig.enabled === undefined ? true : !!vignetteConfig.enabled
  readonly property real vignetteStartFraction: clampNum(vignetteConfig.startFraction, 0.2, 0, 0.95)
  readonly property real vignetteCurve: clampNum(vignetteConfig.curve, 1.5, 0.2, 8)
  readonly property real vignetteSoftness: clampNum(vignetteConfig.softness, 0.55, 0.05, 0.95)
  readonly property real vignetteOpenRadius: clampNum(vignetteConfig.openRadius, 1.5, 1, 4)
  readonly property real vignetteQuantize: clampNum(vignetteConfig.quantize, 0.002, 0.0002, 0.1)

  readonly property var wakeConfig: config.wake || ({})
  readonly property bool wakeEnabled: wakeConfig.enabled === undefined ? true : !!wakeConfig.enabled
  readonly property int wakeBlinks: Math.round(clampNum(wakeConfig.blinks, 2, 0, 5))
  readonly property real wakeSpeed: clampNum(wakeConfig.speed, 1, 0.2, 4)
  readonly property real wakeMinProgress: clampNum(wakeConfig.minProgress, 0.5, 0, 1)
  readonly property real wakeStepPercent: clampNum(wakeConfig.stepPercent, 2, 0.1, 25)
  readonly property int releaseMs: Math.round(clampNum(wakeConfig.releaseMs, 1200, 100, 8000))

  // The tunnel and the eyelid share one gradient: during a fade both radii
  // shrink together, but on wake the horizontal one stays wide while the
  // vertical one works the lid, which is what makes it read as an eye
  // rather than a camera iris.
  readonly property real vignetteHFactor: Math.max(0.002, root.waking
    ? root.vignetteOpenRadius * root.eyeWidth : root.vignetteRadiusFactor)
  readonly property real vignetteVFactor: Math.max(0.002, root.waking
    ? root.vignetteOpenRadius * root.eyeOpen : root.vignetteRadiusFactor)
  readonly property real vignetteOpacity: root.waking
    ? root.wakeVeil : Math.min(1, root.vignetteProgress * 5)

  // 1 closes the tunnel to nothing. Never exactly 0, so the gradient keeps a
  // sane radius for the shader.
  readonly property real vignetteRadiusFactor:
    Math.max(0.002, root.vignetteOpenRadius * Math.pow(1 - root.vignetteProgress, root.vignetteCurve))

  readonly property bool armed: configEnabled && !stayAwake && maxLevel > 0
  readonly property int minLevel: Math.max(1, Math.round(maxLevel * minPercent / 100))

  function logEvent(event, details) {
    root.lastEventAt = new Date().toISOString()
    root.lastEvent = event + (details ? ": " + details : "")
    console.log("idle-fade " + root.lastEventAt + " " + root.lastEvent)
  }

  function deviceArgs() {
    return root.device ? ["-d", root.device] : []
  }

  function brightnessctl(tail) {
    return ["brightnessctl", "-m", "-q"].concat(deviceArgs()).concat(tail)
  }

  // Perceptual ramp: a straight linear walk feels like it plummets and then
  // crawls, so ease it. curve 1.6 holds near the starting level for the first
  // quarter and spends the back half in the dark end.
  function levelAt(progress, from) {
    var p = Math.min(1, Math.max(0, progress))
    var bottom = Math.min(root.minLevel, from)
    return Math.max(1, Math.round(bottom + (from - bottom) * Math.pow(1 - p, root.curve)))
  }

  // Write only once the target has drifted far enough to be seen, and never
  // faster than minWriteMs, so a compressed preview cannot storm the CPU.
  function worthWriting(level, now) {
    if (level === root.lastWritten) return false
    if (now - root.lastWriteAt < root.minWriteMs) return false
    if (root.lastWritten <= 0) return true
    return Math.abs(Math.log(level / root.lastWritten)) >= root.stepPercent / 100
  }

  // The tunnel lags the backlight: nothing happens until the fade is
  // `startFraction` in, then the clear centre shrinks on its own curve.
  // Progress is quantized so a slow close costs a few repaints per second
  // instead of one per tick.
  function updateVignette(progress) {
    if (!root.vignetteEnabled || root.screensaverWindowCount > 0) {
      root.vignetteShowing = false
      return
    }
    var span = 1 - root.vignetteStartFraction
    var vp = span > 0 ? (Math.min(1, Math.max(0, progress)) - root.vignetteStartFraction) / span : 1
    vp = Math.min(1, Math.max(0, vp))
    var stepped = Math.round(vp / root.vignetteQuantize) * root.vignetteQuantize
    if (stepped !== root.vignetteProgress) root.vignetteProgress = stepped
    root.vignetteShowing = vp > 0
  }

  function hideVignette() {
    root.vignetteShowing = false
    root.vignetteProgress = 0
  }

  // Eyes coming open: a first squint, then `blinks` shut-and-wider cycles,
  // then all the way open as the overlay dissolves.
  function buildWakeFrames(smooth) {
    // A handoff is not a waking-up: another plugin wants the screen, so
    // open straight out rather than blinking at nobody.
    if (smooth) return [{ open: 1.7, width: 1.6, veil: 0, ms: root.releaseMs, ease: 'out' }]
    var s = root.wakeSpeed
    var frames = [{ open: 0.45, width: 1, ms: 200 * s, ease: 'out' }]
    for (var i = 0; i < root.wakeBlinks; i++) {
      var last = i === root.wakeBlinks - 1
      frames.push({ open: 0.04, width: 1, ms: 90 * s, ease: 'in' })
      frames.push({ open: last ? 1 : 0.8, width: 1, ms: 170 * s, ease: 'out' })
    }
    frames.push({ open: 1.7, width: 1.6, veil: 0, ms: 340 * s, ease: 'out' })
    return frames
  }

  function ease(kind, t) {
    var c = Math.min(1, Math.max(0, t))
    return kind === 'in' ? c * c : 1 - Math.pow(1 - c, 3)
  }

  function shouldPlayWake() {
    return root.wakeEnabled && root.vignetteEnabled && root.maxProgress >= root.wakeMinProgress
  }

  function beginWake(smooth) {
    root.wakeFrames = buildWakeFrames(smooth)
    root.wakeTotalMs = root.wakeFrames.reduce(function (sum, f) { return sum + f.ms }, 0)
    root.wakeIndex = 0
    root.wakeFromLevel = root.lastWritten > 0 ? root.lastWritten : root.minLevel
    root.eyeOpen = 0
    root.eyeWidth = 0
    root.wakeVeil = 1
    root.wakeFrom = { open: 0, width: 0, veil: 1 }
    root.waking = true
    root.vignetteShowing = true
    root.wakeStartedAt = Date.now()
    root.wakeFrameStartedAt = root.wakeStartedAt
    logEvent('wake-start', (smooth ? 'smooth release' : root.wakeBlinks + ' blinks')
      + ' over ' + Math.round(root.wakeTotalMs) + 'ms')
    wakeTimer.start()
  }

  function tickWake() {
    if (!root.waking) return
    var now = Date.now()
    var frame = root.wakeFrames[root.wakeIndex]
    if (!frame) { finishWake(); return }

    var t = frame.ms > 0 ? (now - root.wakeFrameStartedAt) / frame.ms : 1
    var e = ease(frame.ease, t)
    var toVeil = frame.veil === undefined ? root.wakeFrom.veil : frame.veil
    root.eyeOpen = root.wakeFrom.open + (frame.open - root.wakeFrom.open) * e
    root.eyeWidth = root.wakeFrom.width + (frame.width - root.wakeFrom.width) * e
    root.wakeVeil = root.wakeFrom.veil + (toVeil - root.wakeFrom.veil) * e

    // Light floods back geometrically, so it climbs the way the eye reads it.
    if (root.startLevel > root.wakeFromLevel) {
      var overall = root.wakeTotalMs > 0 ? (now - root.wakeStartedAt) / root.wakeTotalMs : 1
      var eased = ease('out', overall)
      var level = Math.round(root.wakeFromLevel
        * Math.pow(root.startLevel / root.wakeFromLevel, eased))
      if (level !== root.lastWritten && now - root.lastWriteAt >= root.minWriteMs
        && Math.abs(Math.log(level / root.lastWritten)) >= root.wakeStepPercent / 100) {
        applyLevel(level, false)
      }
    }

    if (t < 1) return

    root.wakeFrom = { open: frame.open, width: frame.width, veil: toVeil }
    root.wakeIndex++
    root.wakeFrameStartedAt = now
    if (root.wakeIndex >= root.wakeFrames.length) finishWake()
  }

  function finishWake() {
    wakeTimer.stop()
    root.waking = false
    hideVignette()
    if (root.startLevel > 0) applyLevel(root.startLevel, true)
    clearState()
    logEvent('wake-done', 'restored ' + root.startLevel)
    root.startLevel = -1
    root.lastWritten = -1
    root.maxProgress = 0
  }

  function applyLevel(level, force) {
    var setter = force ? restoreProcess : stepProcess
    // A dropped step is harmless; the next tick recomputes from the clock.
    if (setter.running && !force) return
    root.lastWritten = level
    root.lastWriteAt = Date.now()
    root.writeCount++
    setter.command = brightnessctl(["set", String(level)])
    setter.running = true
  }

  // -------------------------------------------------------------- fading
  function beginFade(durationMs, isPreview) {
    if (root.fading || root.waking || currentProbe.running) return
    if (!root.armed) return
    root.fadeDurationMs = durationMs
    root.previewing = !!isPreview
    currentProbe.command = brightnessctl(["get"]).filter(function (arg) { return arg !== "-q" })
    currentProbe.running = true
  }

  function startFadeFrom(level) {
    if (level <= root.minLevel) {
      logEvent("fade-skip", "already at or below floor (" + level + " <= " + root.minLevel + ")")
      root.previewing = false
      return
    }
    root.startLevel = level
    root.lastWritten = level
    root.lastWriteAt = Date.now()
    root.writeCount = 0
    root.maxProgress = 0
    root.fadeStartedAt = Date.now()
    root.fading = true
    hideVignette()
    writeState(level)
    logEvent("fade-start", "from=" + level + " floor=" + root.minLevel
      + " over=" + Math.round(root.fadeDurationMs / 1000) + "s step=" + root.stepPercent + "%")
    fadeTimer.interval = root.tickMs
    fadeTimer.restart()
  }

  function tick() {
    if (!root.fading) return
    var now = Date.now()
    var progress = root.fadeDurationMs > 0 ? (now - root.fadeStartedAt) / root.fadeDurationMs : 1
    var level = levelAt(progress, root.startLevel)

    root.maxProgress = Math.max(root.maxProgress, Math.min(1, progress))
    updateVignette(progress)

    if (progress >= 1) {
      fadeTimer.stop()
      if (level !== root.lastWritten) applyLevel(level, true)
      logEvent("fade-complete", "level=" + root.lastWritten + " writes=" + root.writeCount)
      return
    }

    if (worthWriting(level, now)) applyLevel(level, false)
  }

  function endFade(restore, reason) {
    fadeTimer.stop()
    previewTimer.stop()
    if (!root.fading) {
      root.previewing = false
      return
    }
    logEvent("fade-end", (reason || "requested") + (restore ? " restore=" + root.startLevel : " restore=no")
      + " writes=" + root.writeCount)
    root.fading = false
    root.previewing = false

    // Deep enough under to be worth waking up from: let the eyes do it.
    // finishWake() owns the restore and the state file from here.
    if (restore && shouldPlayWake()) {
      beginWake()
      return
    }

    hideVignette()
    if (restore && root.startLevel > 0) applyLevel(root.startLevel, true)
    clearState()
    root.startLevel = -1
    root.lastWritten = -1
    root.maxProgress = 0
  }

  function writeState(level) {
    stateWriter.command = ["bash", "-c", 'printf %s "$2" > "$1"', "bash", root.statePath, String(level)]
    stateWriter.running = true
  }

  function clearState() {
    stateCleaner.command = ["bash", "-c", 'rm -f "$1"', "bash", root.statePath]
    stateCleaner.running = true
  }

  // ---------------------------------------------------------- idle wiring
  function handleIdleChanged() {
    if (idleMonitor.isIdle) {
      if (!root.armed || root.released) return
      beginFade(root.durationSeconds * 1000, false)
      return
    }

    root.released = false

    if (!root.fading || root.previewing) return

    // Launching the screensaver can register as compositor activity. While a
    // screensaver window is up the screen is meant to stay dark; its own
    // closewindow event brings the brightness back.
    if (root.screensaverWindowCount > 0) {
      logEvent("activity-ignored", "screensaver is up")
      return
    }

    endFade(true, "activity")
  }

  function setScreensaverWindow(address, visible) {
    var key = String(address || "")
    if (!key) return
    var next = {}
    var count = 0
    for (var existing in root.screensaverWindows) {
      if (existing !== key && root.screensaverWindows[existing]) {
        next[existing] = true
        count++
      }
    }
    if (visible) {
      next[key] = true
      count++
    }
    root.screensaverWindows = next
    root.screensaverWindowCount = count
  }

  function eventParts(event, count) {
    try {
      if (event && event.parse) return event.parse(count)
    } catch (error) {
    }
    return String(event && event.data ? event.data : "").split(",")
  }

  function handleHyprlandEvent(event) {
    var name = String(event && event.name ? event.name : "")
    if (name === "openwindow") {
      var open = eventParts(event, 4)
      if (String(open[2] || "") === root.screensaverClass) {
        setScreensaverWindow(open[0], true)
        hideVignette()
      }
    } else if (name === "closewindow") {
      var address = String(eventParts(event, 1)[0] || "")
      if (!root.screensaverWindows[address]) return
      setScreensaverWindow(address, false)
      if (root.fading && root.screensaverWindowCount === 0) endFade(true, "screensaver-dismissed")
    }
  }

  onArmedChanged: if (!root.armed && root.fading) endFade(true, "disarmed")

  IdleMonitor {
    id: idleMonitor
    enabled: root.armed
    timeout: root.startSeconds
    respectInhibitors: root.respectInhibitors
    onIsIdleChanged: root.handleIdleChanged()
  }

  Timer {
    id: fadeTimer
    interval: root.tickMs
    repeat: true
    onTriggered: root.tick()
  }

  Timer {
    id: wakeTimer
    interval: 16
    repeat: true
    onTriggered: root.tickWake()
  }

  Timer {
    id: previewTimer
    repeat: false
    onTriggered: root.endFade(true, "preview-done")
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) { root.handleHyprlandEvent(event) }
  }

  // ----------------------------------------------------------- processes
  Process {
    id: maxProbe
    stdout: SplitParser {
      onRead: function (line) {
        var value = parseInt(String(line).trim(), 10)
        if (isFinite(value) && value > 0) {
          root.maxLevel = value
          root.logEvent("backlight", "max=" + value + " device=" + (root.device || "default"))
        }
      }
    }
  }

  Process {
    id: currentProbe
    stdout: SplitParser {
      onRead: function (line) {
        var value = parseInt(String(line).trim(), 10)
        if (isFinite(value) && value > 0) root.startFadeFrom(value)
      }
    }
  }

  Process { id: stepProcess }
  Process { id: restoreProcess }
  Process { id: stateWriter }
  Process { id: stateCleaner }

  // If the shell died mid-fade the panel would still be dark. The pre-fade
  // level is parked in the runtime dir, so recover it on startup.
  Process {
    id: stateRecovery
    command: ["bash", "-c", 'f="$1"; [ -f "$f" ] && cat "$f"; rm -f "$f"; exit 0', "bash", root.statePath]
    stdout: SplitParser {
      onRead: function (line) {
        var value = parseInt(String(line).trim(), 10)
        if (!isFinite(value) || value <= 0) return
        root.logEvent("recover", "restoring pre-fade level " + value)
        root.applyLevel(value, true)
        root.lastWritten = -1
      }
    }
  }

  // Stay Awake (the bar indicator) suppresses screensaver and lock; it should
  // suppress dimming too. The state file is watched through its directory
  // because the file itself comes and goes.
  Process {
    id: stayAwakeProbe
    command: ["bash", "-c", '[ -f "$1" ] && echo yes || echo no', "bash", root.stayAwakeDir + "/stay-awake"]
    stdout: SplitParser {
      onRead: function (line) { root.stayAwake = String(line).trim() === "yes" }
    }
  }

  FileView {
    id: stayAwakeWatcher
    path: root.stayAwakeDir
    watchChanges: true
    printErrors: false
    onFileChanged: if (!stayAwakeProbe.running) stayAwakeProbe.running = true
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadConfig(text())
    onLoadFailed: root.loadConfig("")
    onFileChanged: reload()
  }

  function loadConfig(raw) {
    var parsed = {}
    if (raw) {
      try {
        parsed = JSON.parse(raw) || {}
      } catch (error) {
        logEvent("config-error", String(error))
        return
      }
    }
    root.config = parsed
    logEvent("config", "start=" + root.startSeconds + "s duration=" + root.durationSeconds
      + "s floor=" + root.minPercent + "% step=" + root.stepPercent + "% enabled=" + root.configEnabled)
  }

  Component.onCompleted: {
    maxProbe.command = brightnessctl(["max"]).filter(function (arg) { return arg !== "-q" })
    maxProbe.running = true
    stayAwakeProbe.running = true
    stateRecovery.running = true
    logEvent("service-ready")
  }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      required property var modelData

      screen: modelData
      visible: root.vignetteShowing
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "omarchy-idle-fade"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      // Visual only: an empty input region keeps the tunnel from swallowing
      // the very click meant to dismiss it.
      mask: Region {}

      RadialGradient {
        anchors.fill: parent
        // Ramp the whole overlay in from nothing, otherwise the corners pop
        // the moment the gradient first reaches them.
        opacity: root.vignetteOpacity
        horizontalRadius: width / 2 * root.vignetteHFactor
        verticalRadius: height / 2 * root.vignetteVFactor
        gradient: Gradient {
          GradientStop { position: 0; color: "transparent" }
          GradientStop { position: root.vignetteSoftness; color: "transparent" }
          GradientStop {
            position: root.vignetteSoftness + (1 - root.vignetteSoftness) * 0.55
            color: Qt.rgba(0, 0, 0, 0.45)
          }
          GradientStop { position: 1; color: "black" }
        }
      }
    }
  }

  IpcHandler {
    target: "idle-fade"

    function status(): string {
      return JSON.stringify({
        enabled: root.configEnabled,
        armed: root.armed,
        stayAwake: root.stayAwake,
        idle: idleMonitor.isIdle,
        fading: root.fading,
        previewing: root.previewing,
        startSeconds: root.startSeconds,
        durationSeconds: root.durationSeconds,
        minPercent: root.minPercent,
        curve: root.curve,
        tickMs: root.tickMs,
        stepPercent: root.stepPercent,
        minWriteMs: root.minWriteMs,
        device: root.device || "default",
        maxLevel: root.maxLevel,
        minLevel: root.minLevel,
        startLevel: root.startLevel,
        currentWritten: root.lastWritten,
        writes: root.writeCount,
        waking: root.waking,
        released: root.released,
        wakeBlinks: root.wakeBlinks,
        maxProgress: Math.round(root.maxProgress * 1000) / 1000,
        vignette: root.vignetteEnabled,
        vignetteShowing: root.vignetteShowing,
        vignetteProgress: Math.round(root.vignetteProgress * 1000) / 1000,
        screensaverWindows: root.screensaverWindowCount,
        lastEvent: root.lastEvent,
        lastEventAt: root.lastEventAt
      })
    }

    // Run the whole ramp compressed into a few seconds, then restore.
    function preview(seconds: string): string {
      if (root.fading) return "busy"
      if (!root.armed) return "disarmed"
      var span = Math.round(root.clampNum(seconds, 10, 1, 120)) * 1000
      root.beginFade(span, true)
      previewTimer.interval = span + 1200
      previewTimer.restart()
      return "ok"
    }

    function restore(): string {
      root.endFade(true, "ipc")
      return "ok"
    }

    // Hand the screen back to another idle plugin: restore the brightness
    // and open the vignette smoothly, then stay out of the way until the
    // next real activity.
    function release(): string {
      root.released = true
      if (!root.fading && !root.waking) return "idle"
      if (root.waking) return "waking"
      fadeTimer.stop()
      previewTimer.stop()
      root.fading = false
      root.previewing = false
      beginWake(true)
      return "ok"
    }
  }
}
