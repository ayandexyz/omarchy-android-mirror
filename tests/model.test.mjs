// node --test tests/
// Model.js is a QML library file; strip the pragma and eval it as plain JS.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const src = readFileSync(new URL("../Model.js", import.meta.url), "utf8").replace(".pragma library", "")
const M = new Function(src + `
  return { parseDevices, scrcpyArgs, webcamArgs, parseLoopback, parseEndpoint, pairVerdict, connectVerdict, parseWlanIp, stateLabel, WEBCAM_DEVICE, WEBCAM_LABEL }`)()

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
  assert.equal(M.stateLabel([], null, { model: "Pixel 8" }), "Webcam Pixel 8")
  assert.equal(M.stateLabel([], { model: "Pixel 8" }, { model: "Pixel 8" }), "Mirroring + webcam Pixel 8")
})

test("webcamArgs: no window, fixed size, loopback sink", () => {
  const a = M.webcamArgs("X", { cameraFacing: "front", cameraSize: "1280x720", cameraFps: 30, bitrateMbps: 8, wifiBitrateMbps: 2 }, "usb")
  assert.deepEqual(a, ["-s", "X", "--video-source=camera", "--no-window", "--no-audio",
    "--camera-facing=front", "--camera-size=1280x720", "--camera-fps=30", "--video-bit-rate=8M", "--v4l2-sink=" + M.WEBCAM_DEVICE])
})

test("webcamArgs: wifi bitrate, mirror, torch only on back, custom device, bad size falls back", () => {
  const a = M.webcamArgs("X", { cameraFacing: "back", cameraSize: "huge", cameraFps: 500, cameraMirror: true, cameraTorch: true, bitrateMbps: 8, wifiBitrateMbps: 2, webcamDevice: "/dev/video9" }, "wifi")
  assert.deepEqual(a, ["-s", "X", "--video-source=camera", "--no-window", "--no-audio",
    "--camera-facing=back", "--camera-size=1280x720", "--camera-fps=120", "--video-bit-rate=2M",
    "--capture-orientation=@flip0", "--camera-torch", "--v4l2-sink=/dev/video9"])
  const front = M.webcamArgs("X", { cameraFacing: "front", cameraTorch: true, cameraFps: 30, bitrateMbps: 8 })
  assert.ok(!front.includes("--camera-torch"))
})

test("parseLoopback", () => {
  assert.equal(M.parseLoopback("ready\t" + M.WEBCAM_LABEL + "\n", M.WEBCAM_LABEL, "/dev/video42").state, "ready")
  assert.equal(M.parseLoopback("ready\tOmarchy Phone Camera", M.WEBCAM_LABEL, "/dev/video42").state, "foreign")
  assert.equal(M.parseLoopback("notloaded", M.WEBCAM_LABEL, "/dev/video42").state, "notloaded")
  assert.equal(M.parseLoopback("missing", M.WEBCAM_LABEL, "/dev/video42").state, "missing")
  assert.equal(M.parseLoopback("", M.WEBCAM_LABEL, "/dev/video42").state, "missing")
})
