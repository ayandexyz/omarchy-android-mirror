pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Process boundary for the panel. Nothing here does anything you could not
// type yourself: `adb devices -l` to list, `adb tcpip` / `adb connect` /
// `adb pair` for Wi-Fi, and one long-lived `scrcpy -s <serial>` for the
// mirror window. Binaries run by absolute path (default or configured), never
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
  Component.onCompleted: checkTools()

  function checkTools() { toolCheck.running = true }

  Process {
    id: toolCheck
    command: ["/usr/bin/sh", "-c", "test -x \"$1\"; a=$?; test -x \"$2\"; s=$?; echo \"$a $s\"", "_", root.adbPath, root.scrcpyPath]
    stdout: StdioCollector {
      onStreamFinished: {
        var parts = String(text).trim().split(" ")
        root.adbMissing = parts[0] !== "0"
        root.scrcpyMissing = parts[1] !== "0"
        if (root.adbMissing) root.loading = false
        else root.refresh()
      }
    }
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
    command: [root.adbPath, "devices", "-l"]
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
  // `steps` is a queue of {name, args, onDone(stdout, stderr, code) -> bool}
  // so "enable Wi-Fi" can chain tcpip → ip lookup → connect.
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
    actionProc.command = [root.adbPath].concat(step.args)
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
    stdout: StdioCollector { id: actionOut }
    stderr: StdioCollector { id: actionErr }
    onExited: function(exitCode) {
      var step = root.steps[0]
      root.steps = root.steps.slice(1)
      var keepGoing = step.onDone(String(actionOut.text || ""), String(actionErr.text || ""), exitCode)
      if (keepGoing !== false) root.nextStep()
    }
  }

  // Android 11+ wireless debugging: phone shows an ip:port + 6-digit code
  // under Developer options → Wireless debugging → Pair device with code.
  function pair(endpointText, code) {
    var ep = Model.parseEndpoint(endpointText, 0)
    var c = String(code || "").trim()
    if (!ep) { actionOk = false; actionMessage = "Enter the pairing address as ip:port"; return }
    if (!/^\d{6}$/.test(c)) { actionOk = false; actionMessage = "Pairing code is 6 digits"; return }
    runSteps("pair", [{
      args: ["pair", ep.address, c],
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
        args: ["-s", serial, "shell", "ip route; ip -f inet addr show wlan0"],
        onDone: function(out, err, code) {
          ip = Model.parseWlanIp(out, out)
          if (ip === "") { root.finishSteps(false, "Could not read the phone's Wi-Fi address. Is Wi-Fi on?"); return false }
          return true
        }
      },
      {
        // adbd takes a moment to come back on TCP.
        args: ["-s", serial, "wait-for-device"],
        onDone: function() { return true }
      },
      {
        args: ["connect", ip + ":" + Model.WIFI_PORT],
        onDone: function(out, err, code) {
          var v = Model.connectVerdict(out, err, code)
          root.finishSteps(v.ok, v.ok ? "Wi-Fi ready at " + ip + ":" + Model.WIFI_PORT + " — you can unplug the cable" : v.message)
          return false
        }
      }
    ])
  }

  // --- mirroring ----------------------------------------------------------------
  function mirror(device) {
    if (!device || !device.ready) return
    if (mirrorProc.running) stopMirror()
    mirrorError = ""
    mirroring = device
    mirrorProc.command = [root.scrcpyPath].concat(Model.scrcpyArgs(device.serial, {
      maxSize: setting("maxSize", 1080),
      bitrateMbps: setting("bitrateMbps", 8),
      turnScreenOff: setting("turnScreenOff", true),
      stayAwake: setting("stayAwake", true),
      audio: setting("audio", true),
      extraArgs: setting("extraArgs", "")
    }))
    mirrorProc.running = true
  }

  function stopMirror() {
    if (mirrorProc.running) mirrorProc.signal(15)
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
