pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Process boundary for the panel. Nothing here does anything you could not
// type yourself: `adb devices -l` to list, `adb tcpip` / `adb connect` /
// `adb pair` for Wi-Fi, one long-lived `scrcpy -s <serial>` for the mirror
// window and another with `--video-source=camera --v4l2-sink` for the
// webcam. Binaries run by absolute path (default or configured), never
// by PATH lookup, because a shell plugin runs unsandboxed as the user.
Item {
  id: root
  visible: false

  property var settings: ({})

  // --- state the panel reads ---------------------------------------------
  property var devices: []
  property bool loading: false
  property string fetchError: ""
  property double lastSuccessAt: 0

  property bool adbMissing: false
  property bool scrcpyMissing: false
  readonly property bool toolsMissing: adbMissing || scrcpyMissing

  // One adb action at a time (pair / connect / tcpip / disconnect).
  property bool actionBusy: false
  property string actionName: ""
  property string actionMessage: ""
  property bool actionOk: true

  // The device being mirrored, or null. scrcpy owns the window; when the
  // user closes it the process exits and this clears.
  property var mirroring: null
  property string mirrorError: ""

  // The device whose camera is on the v4l2loopback node, or null.
  property var webcam: null
  property string webcamError: ""
  // ready | foreign | notloaded | missing — see Model.parseLoopback.
  property string loopbackState: "missing"
  property string loopbackMessage: ""
  readonly property bool loopbackReady: loopbackState === "ready"
  readonly property string webcamDevice: String(setting("webcamDevice", "")).trim() || Model.WEBCAM_DEVICE
  // The panel's front/back toggle overrides the setting for this session.
  property string facingOverride: ""
  readonly property string cameraFacing: facingOverride || (setting("cameraFacing", "back") === "back" ? "back" : "front")

  readonly property int refreshIntervalSec: Math.round(Model.clamp(setting("refreshIntervalSec", 10), 3, 300))
  readonly property string adbPath: String(setting("adbPath", "")).trim() || Model.DEFAULT_ADB
  readonly property string scrcpyPath: String(setting("scrcpyPath", "")).trim() || Model.DEFAULT_SCRCPY

  signal refreshed()

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  // --- tool presence --------------------------------------------------------
  // Re-checked whenever the configured path changes, and on every refresh
  // while a tool is reported missing so installing it heals the panel.
  onAdbPathChanged: checkTools()
  onScrcpyPathChanged: checkTools()
  Component.onCompleted: { checkTools(); checkLoopback() }

  function checkTools() { toolCheck.running = true }

  // The adb actually used: the configured one, else /usr/bin/adb, else the
  // Android SDK's platform-tools copy (Android Studio users have that one).
  property string resolvedAdb: ""

  Process {
    id: toolCheck
    command: ["/usr/bin/sh", "-c",
      "adb=''; for c in \"$1\" \"$3\"; do [ -n \"$c\" ] && [ -x \"$c\" ] && { adb=$c; break; }; done; " +
      "test -x \"$2\"; s=$?; printf '%s\\t%s\\n' \"$adb\" \"$s\"",
      "_", root.adbPath, root.scrcpyPath, Model.SDK_ADB.replace("~", Quickshell.env("HOME"))]
    stdout: StdioCollector {
      onStreamFinished: {
        var parts = String(text).trim().split("\t")
        root.resolvedAdb = parts[0] || ""
        root.adbMissing = root.resolvedAdb === ""
        root.scrcpyMissing = parts[1] !== "0"
        if (root.adbMissing) root.loading = false
        else root.refresh()
      }
    }
  }

  // While something is missing, re-check every few seconds so the panel
  // heals itself as soon as the install terminal finishes.
  Timer {
    interval: 3000
    running: root.toolsMissing
    repeat: true
    onTriggered: root.checkTools()
  }

  // --- install -------------------------------------------------------------
  property bool installLaunched: false

  function installTools() {
    if (installProc.running) return
    installLaunched = true
    installProc.running = true
  }

  Process {
    id: installProc
    command: ["/usr/bin/omarchy-launch-floating-terminal-with-presentation",
      "omarchy pkg add scrcpy android-tools android-udev"]
    onExited: root.checkTools()
  }

  // --- virtual camera ---------------------------------------------------------
  // The loopback node is what apps pick as the camera; it must exist before
  // scrcpy can write to it. Probed on start, whenever the configured node
  // changes, and every few seconds while it is not ready so finishing the
  // setup terminal heals the panel.
  onWebcamDeviceChanged: checkLoopback()

  function checkLoopback() { if (!loopbackProbe.running) loopbackProbe.running = true }

  Process {
    id: loopbackProbe
    command: ["/usr/bin/sh", "-c",
      "d=$1; n=/sys/class/video4linux/${d#/dev/}/name; " +
      "if [ -e \"$d\" ] && [ -r \"$n\" ]; then printf 'ready\\t%s\\n' \"$(cat \"$n\")\"; " +
      "elif pacman -Q v4l2loopback-dkms >/dev/null 2>&1; then echo notloaded; else echo missing; fi",
      "_", root.webcamDevice]
    stdout: StdioCollector {
      onStreamFinished: {
        var v = Model.parseLoopback(text, Model.WEBCAM_LABEL, root.webcamDevice)
        root.loopbackState = v.state
        root.loopbackMessage = v.message
      }
    }
  }

  Timer {
    interval: 3000
    running: !root.loopbackReady
    repeat: true
    onTriggered: root.checkLoopback()
  }

  property bool setupLaunched: false
  readonly property string setupScript: String(Qt.resolvedUrl("bin/setup-webcam.sh")).replace(/^file:\/\//, "")

  function setupWebcam() {
    if (setupProc.running) return
    setupLaunched = true
    setupProc.running = true
  }

  Process {
    id: setupProc
    command: ["/usr/bin/omarchy-launch-floating-terminal-with-presentation",
      root.setupScript, root.webcamDevice, Model.WEBCAM_LABEL]
    onExited: root.checkLoopback()
  }

  // --- device list ------------------------------------------------------------
  function refresh() {
    if (devicesProc.running) return
    // Nothing to poll without adb; re-check so installing it heals the panel.
    if (adbMissing) { checkTools(); return }
    loading = true
    devicesProc.running = true
  }

  Process {
    id: devicesProc
    command: [root.resolvedAdb, "devices", "-l"]
    stdout: StdioCollector { id: devicesOut }
    stderr: StdioCollector { id: devicesErr }
    onExited: function(exitCode) {
      root.loading = false
      if (exitCode !== 0) {
        root.fetchError = String(devicesErr.text || "").trim() || ("adb devices exited " + exitCode)
        return
      }
      root.fetchError = ""
      root.devices = Model.parseDevices(devicesOut.text)
      root.lastSuccessAt = Date.now()
      root.refreshed()
    }
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: !root.adbMissing
    repeat: true
    onTriggered: root.refresh()
  }

  // --- one-shot adb actions -------------------------------------------------
  // `steps` is a queue of {name, args, stdin?, onDone(stdout, stderr, code) -> bool}
  // so "enable Wi-Fi" can chain tcpip → ip lookup → connect. `stdin` is a
  // line written to the process once it starts, for input that must not be
  // on the command line.
  property var steps: []
  property var stepOut: ({})

  function runSteps(name, list) {
    if (actionBusy) return
    actionBusy = true
    actionOk = true
    actionName = name
    actionMessage = ""
    steps = list
    stepOut = {}
    nextStep()
  }

  function nextStep() {
    if (steps.length === 0) {
      actionBusy = false
      actionName = ""
      refresh()
      return
    }
    var step = steps[0]
    // args may be a function so a later step can use what an earlier one found.
    var args = typeof step.args === "function" ? step.args() : step.args
    actionProc.command = [root.resolvedAdb].concat(args)
    actionProc.secret = step.stdin || ""
    actionProc.stdinEnabled = actionProc.secret !== ""
    actionProc.running = true
  }

  function finishSteps(ok, message) {
    steps = []
    actionOk = ok
    actionMessage = message
    nextStep()
  }

  Process {
    id: actionProc
    // Written to stdin on start and dropped; never stored, logged or shown.
    property string secret: ""
    stdout: StdioCollector { id: actionOut }
    stderr: StdioCollector { id: actionErr }
    onStarted: {
      if (secret !== "") write(secret + "\n")
      secret = ""
    }
    onExited: function(exitCode) {
      var step = root.steps[0]
      var verdict = step.onDone(String(actionOut.text || ""), String(actionErr.text || ""), exitCode)
      if (verdict === "retry" && step.retries > 0) {
        step.retries -= 1
        retryTimer.interval = step.retryDelayMs || 500
        retryTimer.start()
        return
      }
      root.steps = root.steps.slice(1)
      if (verdict === "retry") root.finishSteps(false, "The phone did not come back after switching adb to TCP. Replug it and try again.")
      else if (verdict !== false) root.nextStep()
    }
  }

  Timer {
    id: retryTimer
    repeat: false
    onTriggered: root.nextStep()
  }

  // Android 11+ wireless debugging: phone shows an ip:port + 6-digit code
  // under Developer options → Wireless debugging → Pair device with code.
  // The code answers adb's "Enter pairing code:" prompt over stdin; argv is
  // world-readable in /proc, a private pipe is not.
  function pair(endpointText, code) {
    var ep = Model.parseEndpoint(endpointText, 0)
    var c = String(code || "").trim()
    if (!ep) { actionOk = false; actionMessage = "Enter the pairing address as ip:port"; return }
    if (!/^\d{6}$/.test(c)) { actionOk = false; actionMessage = "Pairing code is 6 digits"; return }
    runSteps("pair", [{
      args: ["pair", ep.address],
      stdin: c,
      onDone: function(out, err, code) {
        var v = Model.pairVerdict(out, err, code)
        root.finishSteps(v.ok, v.message)
        return false
      }
    }])
  }

  function connect(endpointText) {
    var ep = Model.parseEndpoint(endpointText, Model.WIFI_PORT)
    if (!ep) { actionOk = false; actionMessage = "Enter the address as ip[:port]"; return }
    runSteps("connect", [{
      args: ["connect", ep.address],
      onDone: function(out, err, code) {
        var v = Model.connectVerdict(out, err, code)
        root.finishSteps(v.ok, v.message)
        return false
      }
    }])
  }

  function disconnect(serial) {
    runSteps("disconnect", [{
      args: ["disconnect", serial],
      onDone: function(out, err, code) {
        root.finishSteps(code === 0, code === 0 ? "Disconnected " + serial : String(err || out).trim())
        return false
      }
    }])
  }

  // Classic path for any Android version: with the phone on USB, switch adbd
  // to TCP, read the phone's wlan IP, and connect to it. After this the cable
  // can come out. Survives until the phone reboots.
  function enableWifi(serial) {
    var ip = ""
    runSteps("wifi", [
      {
        args: ["-s", serial, "tcpip", String(Model.WIFI_PORT)],
        onDone: function(out, err, code) {
          if (code !== 0) { root.finishSteps(false, String(err || out).trim() || "adb tcpip failed"); return false }
          return true
        }
      },
      {
        // tcpip restarts adbd on the phone, so for a few seconds the shell
        // answers "error: closed" (wait-for-device returns before it even
        // drops off the bus). Retry until it is back.
        args: ["-s", serial, "shell", "ip route; ip -f inet addr show wlan0"],
        retries: 20,
        retryDelayMs: 500,
        onDone: function(out, err, code) {
          if (code !== 0) return "retry"
          ip = Model.parseWlanIp(out, out)
          if (ip === "") { root.finishSteps(false, "Could not read the phone's Wi-Fi address. Is Wi-Fi on?"); return false }
          return true
        }
      },
      {
        args: function() { return ["connect", ip + ":" + Model.WIFI_PORT] },
        onDone: function(out, err, code) {
          var v = Model.connectVerdict(out, err, code)
          root.finishSteps(v.ok, v.ok ? "Wi-Fi ready at " + ip + ":" + Model.WIFI_PORT + " — you can unplug the cable" : v.message)
          return false
        }
      }
    ])
  }

  // --- mirroring ----------------------------------------------------------------
  readonly property string ruleScript: String(Qt.resolvedUrl("bin/hypr-window-rule.sh")).replace(/^file:\/\//, "")
  Process { id: ruleProc; command: [root.ruleScript] }

  function mirror(device) {
    if (!device || !device.ready) return
    if (mirrorProc.running) stopMirror()
    // Float + pin the window without the user editing Hyprland config.
    ruleProc.running = true
    mirrorError = ""
    orientation = -1
    mirroring = device
    mirrorProc.command = [root.scrcpyPath].concat(Model.scrcpyArgs(device.serial, {
      maxSize: setting("maxSize", 1080),
      bitrateMbps: setting("bitrateMbps", 8),
      wifiMaxSize: setting("wifiMaxSize", 800),
      wifiBitrateMbps: setting("wifiBitrateMbps", 2),
      wifiMaxFps: setting("wifiMaxFps", 30),
      turnScreenOff: setting("turnScreenOff", true),
      stayAwake: setting("stayAwake", true),
      audio: setting("audio", true),
      extraArgs: setting("extraArgs", "")
    }, device.transport))
    mirrorProc.running = true
  }

  // --- orientation -----------------------------------------------------------
  // Wayland gives scrcpy no way to resize its own window, so a rotated phone
  // ends up letterboxed inside a portrait window. Poll the phone while the
  // mirror runs and let bin/fit-window.sh swap the window's dimensions.
  property int orientation: -1
  readonly property string fitScript: String(Qt.resolvedUrl("bin/fit-window.sh")).replace(/^file:\/\//, "")

  Timer {
    interval: 1500
    running: root.mirroring !== null && !root.adbMissing
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!orientationProc.running) orientationProc.running = true
  }

  Process {
    id: orientationProc
    command: [root.resolvedAdb, "-s", root.mirroring ? root.mirroring.serial : "", "shell",
      "dumpsys display 2>/dev/null | grep -m1 -oE 'mCurrentOrientation=[0-9]'"]
    stdout: StdioCollector { id: orientationOut }
    onExited: function(exitCode) {
      if (exitCode !== 0 || !root.mirroring) return
      var m = String(orientationOut.text || "").match(/mCurrentOrientation=([0-9])/)
      if (!m) return
      var o = parseInt(m[1], 10)
      if (o === root.orientation) return
      root.orientation = o
      fitProc.command = [root.fitScript, (o % 2 === 1) ? "landscape" : "portrait"]
      fitProc.running = true
    }
  }

  Process { id: fitProc }

  function stopMirror() {
    if (mirrorProc.running) mirrorProc.signal(15)
  }

  // --- webcam -------------------------------------------------------------------
  // Same phone can mirror and be a webcam at once: scrcpy runs one server per
  // connection. The SDK check first is because scrcpy's own error for an old
  // phone is a stack trace, not a sentence.
  function startWebcam(device) {
    if (!device || !device.ready) return
    if (!loopbackReady) { webcamError = loopbackMessage; return }
    webcamError = ""
    runSteps("camera check", [{
      args: ["-s", device.serial, "shell", "getprop ro.build.version.sdk"],
      onDone: function(out, err, code) {
        var sdk = parseInt(String(out || "").trim(), 10)
        if (code !== 0 || !isFinite(sdk)) { root.finishSteps(false, "Could not read the Android version of " + device.serial); return false }
        if (sdk < Model.CAMERA_MIN_SDK) { root.finishSteps(false, "Webcam needs Android 12+; " + Model.deviceTitle(device) + " runs API " + sdk); return false }
        // Switching phones: let the running scrcpy exit first (relaunch).
        if (webcamProc.running) { root.relaunch = device; root.stopWebcam() }
        else root.launchWebcam(device)
        root.finishSteps(true, "")
        return false
      }
    }])
  }

  function launchWebcam(device) {
    webcam = device
    webcamProc.command = [root.scrcpyPath].concat(Model.webcamArgs(device.serial, {
      cameraFacing: root.cameraFacing,
      cameraSize: setting("cameraSize", "1280x720"),
      cameraFps: setting("cameraFps", 30),
      cameraMirror: setting("cameraMirror", false),
      cameraTorch: setting("cameraTorch", false),
      bitrateMbps: setting("bitrateMbps", 8),
      wifiBitrateMbps: setting("wifiBitrateMbps", 2),
      webcamDevice: root.webcamDevice
    }, device.transport))
    webcamProc.running = true
  }

  function stopWebcam() {
    if (webcamProc.running) webcamProc.signal(15)
  }

  // Front ↔ back. If the camera is live, restart it so the switch is one
  // click; scrcpy has no runtime camera switch.
  function flipCamera() {
    facingOverride = cameraFacing === "back" ? "front" : "back"
    if (!webcam) return
    relaunch = webcam
    stopWebcam()
  }

  // Device to start again once the current scrcpy has actually exited.
  property var relaunch: null

  Process {
    id: webcamProc
    stderr: StdioCollector { id: webcamErr }
    onExited: function(exitCode, exitStatus) {
      var was = root.webcam
      root.webcam = null
      if (root.relaunch) {
        var again = root.relaunch
        root.relaunch = null
        root.launchWebcam(again)
        return
      }
      if (exitCode !== 0 && exitStatus === 0) {
        var text = String(webcamErr.text || "").trim().split("\n")
        var last = ""
        for (var i = text.length - 1; i >= 0; i--) if (/ERROR|WARN/.test(text[i])) { last = text[i]; break }
        root.webcamError = last || ("scrcpy exited " + exitCode + (was ? " for " + was.serial : ""))
      }
    }
  }

  Process {
    id: mirrorProc
    stderr: StdioCollector { id: mirrorErr }
    onExited: function(exitCode, exitStatus) {
      var was = root.mirroring
      root.mirroring = null
      // 0 is the user closing the window; SIGTERM from stopMirror is fine too.
      if (exitCode !== 0 && exitStatus === 0) {
        var text = String(mirrorErr.text || "").trim().split("\n")
        // scrcpy's last ERROR/WARN line is the useful one.
        var last = ""
        for (var i = text.length - 1; i >= 0; i--) if (/ERROR|WARN/.test(text[i])) { last = text[i]; break }
        root.mirrorError = last || ("scrcpy exited " + exitCode + (was ? " for " + was.serial : ""))
      }
    }
  }
}
