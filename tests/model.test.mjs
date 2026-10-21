// node --test tests/
// Model.js is a QML library file; strip the pragma and eval it as plain JS.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const src = readFileSync(new URL("../Model.js", import.meta.url), "utf8").replace(".pragma library", "")
const M = new Function(src + `
  return { parseDevices, groupDevices, deviceSubtitle, scrcpyArgs, parseEndpoint, pairVerdict, connectVerdict, parseWlanIp, stateLabel }`)()

test("parseDevices handles usb, wifi, unauthorized, no permissions", () => {
  const out = M.parseDevices(`List of devices attached
R58M1234ABC            device usb:1-2 product:beyond1 model:SM_G973F device:beyond1 transport_id:3
192.168.1.42:5555      device product:beyond1 model:SM_G973F device:beyond1 transport_id:4
ZY22ABCD               unauthorized usb:1-3 transport_id:5
0123456789             no permissions (missing udev rules?); see [http://developer.android.com/tools/device.html] usb:1-4 transport_id:6
`)
  assert.equal(out.length, 4)
  assert.deepEqual(out.map(d => d.transport), ["usb", "wifi", "usb", "usb"])
  assert.equal(out[0].model, "SM G973F")
  assert.equal(out[2].state, "unauthorized")
  assert.equal(out[3].state, "no permissions")
  assert.deepEqual(out.map(d => d.ready), [true, true, false, false])
})

test("scrcpyArgs respects settings", () => {
  const a = M.scrcpyArgs("X", { maxSize: 0, bitrateMbps: 4, turnScreenOff: false, stayAwake: true, audio: false, extraArgs: "--video-codec=h265" })
  assert.deepEqual(a, ["-s", "X", "--window-title", "Android Mirror", "--video-bit-rate=4M", "--stay-awake", "--no-audio", "--video-codec=h265"])
})

test("scrcpyArgs wifi profile trades quality for latency", () => {
  const a = M.scrcpyArgs("192.168.1.5:5555", { maxSize: 1080, bitrateMbps: 8, wifiMaxSize: 800, wifiBitrateMbps: 2, wifiMaxFps: 30, turnScreenOff: true, stayAwake: true, audio: true, extraArgs: "" }, "wifi")
  assert.deepEqual(a, ["-s", "192.168.1.5:5555", "--window-title", "Android Mirror", "--max-size=800", "--video-bit-rate=2M", "--max-fps=30", "--stay-awake", "--no-audio"])
})

test("parseEndpoint", () => {
  assert.equal(M.parseEndpoint("192.168.1.5", 5555).address, "192.168.1.5:5555")
  assert.equal(M.parseEndpoint("192.168.1.5:37123", 0).address, "192.168.1.5:37123")
  assert.equal(M.parseEndpoint("192.168.1.5", 0), null)
  assert.equal(M.parseEndpoint("", 5555), null)
})

test("verdicts", () => {
  assert.equal(M.pairVerdict("Successfully paired to 192.168.1.5:37123 [guid=adb-x]", "", 0).ok, true)
  assert.equal(M.pairVerdict("Failed: Wrong password or connection was dropped.", "", 1).ok, false)
  const prompted = M.pairVerdict("Enter pairing code: error: protocol fault (couldn't read status message): Success", "", 1)
  assert.equal(prompted.ok, false)
  assert.equal(prompted.message, "error: protocol fault (couldn't read status message): Success")
  assert.equal(M.pairVerdict("Enter pairing code: Successfully paired to 192.168.1.5:37123 [guid=adb-x]", "", 0).ok, true)
  assert.equal(M.connectVerdict("connected to 192.168.1.5:5555", "", 0).ok, true)
  assert.equal(M.connectVerdict("already connected to 192.168.1.5:5555", "", 0).ok, true)
  assert.equal(M.connectVerdict("failed to connect to '192.168.1.5:5555': Connection refused", "", 0).ok, false)
})

test("parseWlanIp prefers route src", () => {
  assert.equal(M.parseWlanIp("192.0.0.0/27 dev rmnet_data0 proto kernel scope link src 192.0.0.2\n192.168.31.0/24 dev wlan0 proto kernel scope link src 192.168.31.60", ""), "192.168.31.60")
  assert.equal(M.parseWlanIp("default via 192.168.1.1 dev wlan0 proto static src 192.168.1.42", ""), "192.168.1.42")
  assert.equal(M.parseWlanIp("", "    inet 10.0.0.7/24 brd 10.0.0.255 scope global wlan0"), "10.0.0.7")
})

test("stateLabel", () => {
  assert.equal(M.stateLabel([], null), "No phone connected")
  assert.equal(M.stateLabel([{ ready: true }], null), "1 phone ready")
  assert.equal(M.stateLabel([], { model: "Pixel 8" }), "Mirroring Pixel 8")
})

test("parseDevices labels mDNS wireless-debugging transports as wifi", () => {
  const out = M.parseDevices(`List of devices attached
adb-12ab34cd56ef7890._adb-tls-connect._tcp device product:RMX1931EEA model:RMX1931 device:RMX1931L1 transport_id:8
`)
  assert.equal(out[0].transport, "wifi")
  assert.equal(out[0].deviceKey, "RMX1931L1")
})

test("groupDevices collapses transports of one phone into a single group", () => {
  const devs = M.parseDevices(`List of devices attached
192.168.1.42:5555      device product:beyond1 model:SM_G973F device:beyond1 transport_id:4
adb-12ab34cd56ef7890._adb-tls-connect._tcp device product:beyond1 model:SM_G973F device:beyond1 transport_id:8
R58M1234ABC            device usb:1-2 product:beyond1 model:SM_G973F device:beyond1 transport_id:3
ZY22ABCD               unauthorized usb:1-3 transport_id:5
`)
  const groups = M.groupDevices(devs)
  assert.equal(groups.length, 2)
  assert.equal(groups[0].key, "beyond1")
  assert.equal(groups[0].transports.length, 3)
  assert.equal(groups[0].ready, true)
  // USB is the preferred channel even when Wi-Fi transports came first.
  assert.equal(groups[0].preferred.serial, "R58M1234ABC")
  assert.equal(groups[0].usbTransport.serial, "R58M1234ABC")
  assert.equal(groups[0].wifiTransports.length, 2)
  assert.equal(M.deviceSubtitle(groups[0]), "USB · Wi-Fi 192.168.1.42:5555")
  assert.equal(groups[1].key, "ZY22ABCD")
  assert.equal(groups[1].ready, false)
  assert.match(M.deviceSubtitle(groups[1]), /tap Allow on the phone/)
})

test("groupDevices keeps distinct phones apart when device: is missing", () => {
  const devs = M.parseDevices(`List of devices attached
0123456789ABCDEF       device transport_id:7
192.168.1.9:5555       device transport_id:8
`)
  const groups = M.groupDevices(devs)
  assert.equal(groups.length, 2)
  assert.equal(groups[0].key, "0123456789ABCDEF")
  assert.equal(groups[1].key, "192.168.1.9:5555")
  assert.equal(M.deviceSubtitle(groups[1]), "Wi-Fi 192.168.1.9:5555")
})

test("deviceSubtitle names the channel a live session rides on", () => {
  const devs = M.parseDevices(`List of devices attached
R58M1234ABC            device usb:1-2 product:beyond1 model:SM_G973F device:beyond1 transport_id:3
192.168.1.42:5555      device product:beyond1 model:SM_G973F device:beyond1 transport_id:4
`)
  const group = M.groupDevices(devs)[0]
  assert.equal(M.deviceSubtitle(group), "USB · Wi-Fi 192.168.1.42:5555")
  // The live channel leads; the available channels follow without repeating it.
  assert.equal(
    M.deviceSubtitle(group, { serial: "192.168.1.42:5555", transport: "wifi" }),
    "live over Wi-Fi 192.168.1.42:5555 · USB")
  assert.equal(
    M.deviceSubtitle(group, { serial: "R58M1234ABC", transport: "usb" }),
    "live over USB · Wi-Fi 192.168.1.42:5555")
  // Single channel: no redundancy.
  const wifiOnly = M.groupDevices(M.parseDevices(`List of devices attached
192.168.1.9:5555       device product:beyond1 model:SM_G973F device:beyond1 transport_id:6
`))[0]
  assert.equal(
    M.deviceSubtitle(wifiOnly, { serial: "192.168.1.9:5555", transport: "wifi" }),
    "live over Wi-Fi 192.168.1.9:5555")
})
