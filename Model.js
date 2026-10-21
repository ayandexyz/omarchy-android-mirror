// Pure functions for the Android Mirror plugin. No Qt, no processes: this
// file is what the panel and backend reason with, and what tests/ can run
// under plain node.

.pragma library

var DEFAULT_ADB = "/usr/bin/adb"
var DEFAULT_SCRCPY = "/usr/bin/scrcpy"
var SDK_ADB = "~/Android/Sdk/platform-tools/adb"
var WIFI_PORT = 5555

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
    // A serial is Wi-Fi if it is ip:port (tcpip mode), or an mDNS-style adbd
    // identity ("adb-<guid>._adb-tls-connect._tcp"), which is how Android 11+
    // wireless-debugging transports appear. Without the mDNS check those
    // transports get mislabeled as USB.
    var wifi = /^\d+\.\d+\.\d+\.\d+:\d+$/.test(serial) || /^\[?[0-9a-f:]+\]?:\d+$/i.test(serial)
      || serial.indexOf("_adb-tls") !== -1 || /^adb-[0-9a-f]{8,}/i.test(serial)
    out.push({
      serial: serial,
      state: state,
      transport: wifi ? "wifi" : "usb",
      model: (meta.model || "").replace(/_/g, " "),
      // Stable physical identity: adb reports device:<product-device> for
      // every transport of the same hardware, so USB / tcpip / mDNS views of
      // one phone group together.
      deviceKey: meta.device || (meta.model || "").replace(/_/g, " ") || serial,
      product: meta.product || "",
      transportId: meta.transport_id || "",
      ready: state === "device"
    })
  }
  return out
}

// Collapse transports of the same physical phone into one row: adb lists a
// device once per channel (USB, tcpip ip:port, wireless-debugging mDNS), so
// a phone reachable two ways otherwise appears twice and inflates counts.
// Groups keep first-seen order. The preferred channel for mirroring is USB
// when a ready one exists (lower latency, higher-quality profile), else the
// first ready Wi-Fi transport.
function groupDevices(devices) {
  var groups = []
  var byKey = {}
  for (var i = 0; i < devices.length; i++) {
    var d = devices[i]
    var key = d.deviceKey || d.serial
    var g = byKey[key]
    if (!g) {
      g = byKey[key] = {
        key: key,
        serial: key,
        model: d.model,
        transports: [],
        ready: false,
        preferred: null,
        usbTransport: null,
        wifiReady: false,
        wifiTransports: []
      }
      groups.push(g)
    }
    if (!g.model && d.model) g.model = d.model
    g.transports.push(d)
    if (d.transport === "usb") {
      if (!g.usbTransport) g.usbTransport = d
      if (d.ready && !g.preferred) g.preferred = d
    } else {
      g.wifiTransports.push(d)
      if (d.ready) g.wifiReady = true
      if (d.ready && !g.wifiPreferred) g.wifiPreferred = d
    }
    if (d.ready) g.ready = true
  }
  for (var j = 0; j < groups.length; j++)
    if (!groups[j].preferred) groups[j].preferred = groups[j].wifiPreferred
  return groups
}

function deviceTitle(d) {
  if (!d) return ""
  if (d.model !== "") return d.model
  return d.serial
}

function deviceSubtitle(d, mirroring) {
  if (!d) return ""
  if (!d.transports) {
    var bits = [d.transport === "wifi" ? "Wi-Fi" : "USB", d.serial]
    if (!d.ready) bits.push(stateHint(d.state))
    if (mirroring && mirroring.serial === d.serial)
      bits.push("live over " + (mirroring.transport === "wifi" ? "Wi-Fi" : "USB"))
    return bits.join(" · ")
  }
  // Group row: one tag per channel; Wi-Fi tags carry the address when adb
  // reports it (ip:port — mDNS serials are opaque guids). Bare "Wi-Fi" tags
  // collapse when an addressed one exists; a channel that is not ready
  // carries its state hint. USB tags come first (preferred channel).
  var usbTags = []
  var wifiTags = []
  for (var i = 0; i < d.transports.length; i++) {
    var t = d.transports[i]
    var isWifi = t.transport === "wifi"
    var hasAddress = isWifi && /^\d+\.\d+\.\d+\.\d+:\d+$/.test(t.serial)
    var tag = (isWifi ? "Wi-Fi" : "USB") + (hasAddress ? " " + t.serial : "")
      + (t.ready ? "" : " (" + stateHint(t.state) + ")")
    var bucket = isWifi ? wifiTags : usbTags
    if (bucket.indexOf(tag) === -1) bucket.push(tag)
  }
  if (wifiTags.indexOf("Wi-Fi") !== -1 && wifiTags.length > 1)
    wifiTags.splice(wifiTags.indexOf("Wi-Fi"), 1)
  var out = usbTags.concat(wifiTags).join(" · ")
  if (mirroring)
    for (var j = 0; j < d.transports.length; j++)
      if (d.transports[j].serial === mirroring.serial) {
        var mt = d.transports[j]
        var mtIsWifi = mt.transport === "wifi"
        var mtHasAddress = mtIsWifi && /^\d+\.\d+\.\d+\.\d+:\d+$/.test(mt.serial)
        var liveLabel = (mtIsWifi ? "Wi-Fi" : "USB") + (mtHasAddress ? " " + mt.serial : "")
          + (mt.ready ? "" : " (" + stateHint(mt.state) + ")")
        var all = usbTags.concat(wifiTags)
        var rest = []
        for (var k = 0; k < all.length; k++)
          if (all[k] !== liveLabel) rest.push(all[k])
        return ["live over " + liveLabel].concat(rest).join(" · ")
      }
  return out
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
function stateLabel(devices, mirroring) {
  if (mirroring) return "Mirroring " + (mirroring.model || mirroring.serial)
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
