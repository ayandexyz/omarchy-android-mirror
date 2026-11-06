// Exercise the backend's JavaScript handlers with fake processes and timers.
// This does not instantiate QML, start adb/scrcpy, or contact a phone.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { createContext, runInContext } from "node:vm"

const source = readFileSync(new URL("../MirrorBackend.qml", import.meta.url), "utf8")
const model = readFileSync(new URL("../Model.js", import.meta.url), "utf8").replace(".pragma library", "")
const Model = new Function(model + "; return { scrcpyArgs, lockArgs, keyguardShowing }")()
const manifest = JSON.parse(readFileSync(new URL("../manifest.json", import.meta.url), "utf8"))
const device = { serial: "TEST_DEVICE", transport: "usb", ready: true }

function backend(settings = {}) {
  const context = createContext({
    Model, settings, console: { log() {} },
    resolvedAdb: "/test/adb", scrcpyPath: "/test/scrcpy", ruleScript: "/test/rule",
    mirroring: null, mirrorError: "", orientation: -1, mirrorAdb: "", lockOnExit: false,
    lockSerial: "", lockAdb: "", lockAttempts: 0, actionBusy: false,
    ruleProc: { running: false },
    mirrorProc: { running: false, signal(n) { this.lastSignal = n } },
    lockProc: { running: false }, lockNotify: { running: false },
    mirrorErr: { text: "" }, lockOut: { text: "" },
    lockRetryTimer: { running: false, start() { this.running = true } }
  })
  context.root = context
  for (const name of ["setting", "mirror", "stopMirror", "lockPhone", "checkPhoneLock", "finishPhoneLock"]) {
    const fn = source.match(new RegExp(`  function ${name}\\([^]*?\\n  }`))
    assert.ok(fn, `backend function ${name} exists`)
    runInContext(fn[0], context)
  }
  for (const [id, name] of [["mirrorProc", "mirrorExited"], ["lockProc", "lockExited"]]) {
    const handler = source.slice(source.indexOf(`    id: ${id}\n`)).match(/onExited: (function\([^]*?\n    })/)
    assert.ok(handler, `exit handler for ${id} exists`)
    context[name] = runInContext(`(${handler[1]})`, context)
  }
  context.exitMirror = (code = 0, status = 0) => {
    context.mirrorProc.running = false
    context.mirrorExited(code, status)
  }
  context.exitLock = (text, code = 0) => {
    context.lockProc.running = false
    context.lockOut.text = text
    context.lockExited(code)
  }
  context.retry = () => {
    assert.equal(context.lockRetryTimer.running, true)
    context.lockRetryTimer.running = false
    context.checkPhoneLock()
  }
  return context
}

test("lock-on-close defaults agree between schema and backend", () => {
  assert.equal(manifest.barWidget.defaults.lockOnClose, true)
  assert.equal(manifest.barWidget.schema.find(s => s.key === "lockOnClose").defaultValue, true)
  const b = backend()
  b.mirror(device)
  assert.equal(b.lockOnExit, true)
  assert.ok(b.mirrorProc.command.includes("--power-off-on-close"))
})

test("all mirror exits lock the captured session, independently of panel actions", () => {
  for (const [code, status] of [[0, 0], [1, 0], [15, 1]]) {
    const b = backend()
    b.mirror(device)
    b.settings.lockOnClose = false
    b.resolvedAdb = "/test/changed-adb"
    b.actionBusy = true
    b.exitMirror(code, status)
    assert.equal(b.mirroring, null)
    assert.equal(b.lockSerial, device.serial)
    assert.equal(b.lockAttempts, 1)
    assert.deepEqual(Array.from(b.lockProc.command), [
      "/usr/bin/timeout", "--kill-after=1s", "3s", "/test/adb",
      "-s", "TEST_DEVICE", "shell", "input keyevent KEYCODE_SLEEP; dumpsys window"
    ])
    b.exitLock("isKeyguardShowing=true")
    assert.equal(b.lockSerial, "")
    assert.equal(b.lockNotify.running, false)
  }
})

test("opt-out skips both cleanup flag and post-session lock", () => {
  const b = backend({ lockOnClose: false })
  b.mirror(device)
  assert.equal(b.mirrorProc.command.includes("--power-off-on-close"), false)
  b.settings.lockOnClose = true
  b.exitMirror()
  assert.equal(b.lockProc.running, false)
  assert.equal(b.lockSerial, "")
})

test("stop only signals scrcpy; locking starts after it exits", () => {
  const b = backend()
  b.stopMirror()
  assert.equal(b.lockProc.running, false)
  b.mirror(device)
  b.stopMirror()
  assert.equal(b.mirrorProc.lastSignal, 15)
  assert.equal(b.lockProc.running, false)
  b.exitMirror(15, 1)
  assert.equal(b.lockProc.running, true)
})

test("another mirror cannot overwrite an active or locking session", () => {
  const b = backend()
  const other = { ...device, serial: "OTHER_TEST_DEVICE" }
  b.mirror(device)
  b.mirror(other)
  assert.equal(b.mirroring.serial, device.serial)
  assert.equal(b.mirrorProc.lastSignal, 15)
  b.exitMirror()
  b.mirror(other)
  assert.equal(b.mirrorProc.running, false)
  assert.equal(b.lockSerial, device.serial)
  b.exitLock("isKeyguardShowing=true")
  b.mirror(other)
  assert.equal(b.mirroring.serial, other.serial)
})

test("three unconfirmed attempts notify without claiming the phone is unlocked", () => {
  const b = backend()
  b.mirror(device)
  b.mirrorErr.text = "ERROR: connection lost"
  b.exitMirror(1)
  b.exitLock("isKeyguardShowing=false")
  b.retry()
  b.exitLock("", 124) // timeout
  b.retry()
  b.exitLock("isKeyguardShowing=true", 1) // failed adb is not confirmation
  assert.equal(b.lockAttempts, 3)
  assert.equal(b.lockRetryTimer.running, false)
  assert.equal(b.lockSerial, "")
  assert.equal(b.lockAdb, "")
  assert.equal(b.lockNotify.running, true)
  assert.match(b.mirrorError, /^ERROR: connection lost\nCould not confirm the phone locked\./)
  assert.doesNotMatch(b.mirrorError, /phone is unlocked/i)
  assert.match(source, /id: lockRetryTimer\s+interval: 1000\s+repeat: false\s+onTriggered: root\.checkPhoneLock\(\)/)
})

test("a later confirmation ends retries without a warning", () => {
  const b = backend()
  b.mirror(device)
  b.exitMirror()
  b.exitLock("") // no keyguard field / phone without a lock screen
  b.retry()
  b.exitLock("isKeyguardShowing=true")
  assert.equal(b.lockAttempts, 2)
  assert.equal(b.lockSerial, "")
  assert.equal(b.lockRetryTimer.running, false)
  assert.equal(b.lockNotify.running, false)
  assert.equal(b.mirrorError, "")
})
