// Pure functions for the Android Mirror plugin. No Qt, no processes: this
// file is what the panel and backend reason with, and what tests/ can run
// under plain node.

.pragma library

var DEFAULT_ADB = "/usr/bin/adb"
var DEFAULT_SCRCPY = "/usr/bin/scrcpy"
var SDK_ADB = "~/Android/Sdk/platform-tools/adb"
var WIFI_PORT = 5555
// The v4l2loopback node the webcam feature writes to, and the name apps show
// for it. bin/setup-webcam.sh creates it; both are overridable in settings.
var WEBCAM_DEVICE = "/dev/video42"
var WEBCAM_LABEL = "Android Mirror Camera"
// scrcpy's camera source needs Android 12 (API 31).
var CAMERA_MIN_SDK = 31

function clamp(value, lo, hi) {
  var n = Number(value)
  if (!isFinite(n)) return lo
  return Math.max(lo, Math.min(hi, n))
}

// `adb devices -l` prints one line per device:
//   R58M1234ABC   device usb:1-2 product:beyond1 model:SM_G973F device:beyond1 transport_id:3
//   192.168.1.42:5555   device product:... model:... transport_id:4
//   R58M1234ABC   unauthorized usb:1-2 transport_id:5
// States: device | unauthorized | offline | no permissions | authorizing
function parseDevices(text) {
  var out = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line === "" || line.indexOf("List of devices") === 0 || line.charAt(0) === "*") continue
    var parts = line.split(/\s+/)
    if (parts.length < 2) continue
    var serial = parts[0]
    var state = parts[1]
    // "no permissions" is two words; rejoin and drop the udev hint that follows.
    if (state === "no" && parts[2] === "permissions") state = "no permissions"
    var meta = {}
    for (var j = 2; j < parts.length; j++) {
      var kv = parts[j].split(":")
      if (kv.length === 2) meta[kv[0]] = kv[1]
    }
    var wifi = /^\d+\.\d+\.\d+\.\d+:\d+$/.test(serial) || /^\[?[0-9a-f:]+\]?:\d+$/i.test(serial)
    out.push({
      serial: serial,
      state: state,
      transport: wifi ? "wifi" : "usb",
      model: (meta.model || "").replace(/_/g, " "),
      product: meta.product || "",
      transportId: meta.transport_id || "",
      ready: state === "device"
    })
  }
  return out
}

function deviceTitle(d) {
  if (!d) return ""
  if (d.model !== "") return d.model
  return d.serial
}

function deviceSubtitle(d) {
  if (!d) return ""
  var bits = [d.transport === "wifi" ? "Wi-Fi" : "USB", d.serial]
  if (!d.ready) bits.push(stateHint(d.state))
  return bits.join(" · ")
}

function stateHint(state) {
  switch (state) {
    case "unauthorized": return "tap Allow on the phone"
    case "offline": return "offline — replug or reconnect"
    case "no permissions": return "udev: no USB permission"
    case "authorizing": return "authorizing…"
    default: return state
  }
}

// One-line summary for the bar tooltip / hero meta.
function stateLabel(devices, mirroring, webcam) {
  var name = function(d) { return d.model || d.serial }
  if (mirroring && webcam) return "Mirroring + webcam " + name(mirroring)
  if (mirroring) return "Mirroring " + name(mirroring)
  if (webcam) return "Webcam " + name(webcam)
  var ready = devices.filter(function(d) { return d.ready }).length
  if (devices.length === 0) return "No phone connected"
  if (ready === 0) return devices.length + " device(s), none ready"
  return ready + (ready === 1 ? " phone ready" : " phones ready")
}

// Over Wi-Fi the phone's uplink is the bottleneck (a 2.4 GHz link manages
// maybe 10-15 Mbps in practice), so the Wi-Fi profile trades pixels for
// latency: smaller frame, lower bitrate, capped fps, no audio stream. It also
// keeps the screen on: with no cable there is no charger, --stay-awake is
// ignored, and a dark phone dozes and drops off Wi-Fi mid-session.
function scrcpyArgs(serial, s, transport) {
  var wifi = transport === "wifi"
  var args = ["-s", serial, "--window-title", "Android Mirror"]
  var maxSize = Math.round(clamp(wifi ? s.wifiMaxSize : s.maxSize, 0, 4096))
  if (maxSize > 0) args.push("--max-size=" + maxSize)
  var mbps = Math.round(clamp(wifi ? s.wifiBitrateMbps : s.bitrateMbps, 1, 50))
  args.push("--video-bit-rate=" + mbps + "M")
  if (wifi) {
    var fps = Math.round(clamp(s.wifiMaxFps, 0, 120))
    if (fps > 0) args.push("--max-fps=" + fps)
  }
  if (s.turnScreenOff && !wifi) args.push("--turn-screen-off")
  if (s.stayAwake) args.push("--stay-awake")
  if (!s.audio || wifi) args.push("--no-audio")
  var extra = String(s.extraArgs || "").trim()
  if (extra !== "") args = args.concat(extra.split(/\s+/))
  return args
}

// Phone camera → v4l2loopback, no window. The capture size is fixed rather
// than "max-size" because Chromium keeps the loopback open across calls and
// copes badly with a format change under it; front/back and fps are the
// user's, bitrate follows the transport like the mirror does. Audio and
// playback are off: the frames go to the device node, nowhere else.
function webcamArgs(serial, s, transport) {
  var wifi = transport === "wifi"
  var args = ["-s", serial, "--video-source=camera", "--no-window", "--no-audio"]
  args.push("--camera-facing=" + (s.cameraFacing === "back" ? "back" : "front"))
  var size = /^\d{3,4}x\d{3,4}$/.test(String(s.cameraSize || "")) ? s.cameraSize : "1280x720"
  args.push("--camera-size=" + size)
  var fps = Math.round(clamp(s.cameraFps, 1, 120))
  args.push("--camera-fps=" + fps)
  var mbps = Math.round(clamp(wifi ? s.wifiBitrateMbps : s.bitrateMbps, 1, 50))
  args.push("--video-bit-rate=" + mbps + "M")
  if (s.cameraMirror) args.push("--capture-orientation=@flip0")
  if (s.cameraTorch && s.cameraFacing === "back") args.push("--camera-torch")
  args.push("--v4l2-sink=" + (String(s.webcamDevice || "").trim() || WEBCAM_DEVICE))
  return args
}

// Output of the loopback probe in MirrorBackend: one of
//   ready\t<card label>     the node exists and is a v4l2 device
//   notloaded               package installed, module not loaded (or no node)
//   missing                 v4l2loopback-dkms is not installed
// Returns {state, label, message} where state is ready|foreign|notloaded|missing.
function parseLoopback(text, wantLabel, device) {
  var t = String(text || "").trim()
  if (t.indexOf("ready\t") === 0) {
    var label = t.slice(6).trim()
    if (label === wantLabel) return { state: "ready", label: label, message: "" }
    return { state: "foreign", label: label, message: device + " exists but is \"" + label + "\", not \"" + wantLabel + "\". Point 'webcam device' at the right node or re-run Set up." }
  }
  if (t === "notloaded") return { state: "notloaded", label: "", message: "v4l2loopback is installed but " + device + " does not exist. Run Set up to register it (or reboot)." }
  return { state: "missing", label: "", message: "The virtual camera is not set up yet." }
}

// Host and port typed by the user for pair/connect. Accepts "ip", "ip:port",
// or "ip port"; port defaults to WIFI_PORT for connect and is required for pair.
function parseEndpoint(text, defaultPort) {
  var t = String(text || "").trim().replace(/\s+/, ":")
  if (t === "") return null
  var m = t.match(/^(.+?)(?::(\d{1,5}))?$/)
  if (!m) return null
  var port = m[2] ? parseInt(m[2], 10) : defaultPort
  if (!port || port < 1 || port > 65535) return null
  return { host: m[1], port: port, address: m[1] + ":" + port }
}

// adb pair prints "Successfully paired to 192.168.1.5:37123 [guid=...]" on
// success and "Failed: ..." otherwise, both on stdout, after the
// "Enter pairing code:" prompt the code was typed into.
function pairVerdict(stdout, stderr, exitCode) {
  var s = String(stdout || "").replace(/Enter pairing code:\s*/g, "") + "\n" + String(stderr || "")
  if (/Successfully paired/i.test(s)) return { ok: true, message: "Paired. Now connect using the Wi-Fi debugging address shown on the phone." }
  var fail = s.match(/(Failed:.*|error:.*|cannot.*|.*refused.*)/i)
  return { ok: false, message: fail ? fail[1].trim() : (exitCode === 0 ? "Pairing did not confirm." : "adb pair exited " + exitCode) }
}

function connectVerdict(stdout, stderr, exitCode) {
  var s = String(stdout || "") + "\n" + String(stderr || "")
  if (/^connected to|already connected/im.test(s)) return { ok: true, message: s.trim().split("\n")[0] }
  var fail = s.match(/(failed to connect.*|cannot connect.*|error:.*|.*refused.*|.*timed? ?out.*)/i)
  return { ok: false, message: fail ? fail[1].trim() : (exitCode === 0 ? s.trim() : "adb connect exited " + exitCode) }
}

// `adb shell ip route` → "192.168.1.0/24 dev wlan0 proto kernel scope link src 192.168.1.42"
// Mobile data adds an rmnet_data0 line with its own src, so only a wlan0 line
// counts. Some ROMs omit `src`; fall back to `ip -f inet addr show wlan0`.
function parseWlanIp(routeText, addrText) {
  var lines = String(routeText || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].indexOf("dev wlan0") === -1) continue
    var m = lines[i].match(/\bsrc\s+(\d+\.\d+\.\d+\.\d+)/)
    if (m) return m[1]
  }
  var a = String(addrText || "").match(/inet\s+(\d+\.\d+\.\d+\.\d+)/)
  return a ? a[1] : ""
}

function elapsed(fromMs, nowMs) {
  var s = Math.max(0, Math.round((nowMs - fromMs) / 1000))
  if (s < 5) return "just now"
  if (s < 60) return s + "s ago"
  var m = Math.round(s / 60)
  if (m < 60) return m + "m ago"
  return Math.round(m / 60) + "h ago"
}
