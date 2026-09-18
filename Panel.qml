pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui as Ui
import "Model.js" as Model

// Bar icon + panel for mirroring an Android phone with scrcpy.
//
// Left click: open the panel. Right click: mirror the first ready phone (or
// stop the running mirror). Middle click: refresh the device list.
Ui.Panel {
  id: root
  moduleName: "io.github.ayan-de.android-mirror"
  ipcTarget: "io.github.ayan-de.android-mirror"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var devices: backend.devices
  readonly property var readyDevices: devices.filter(function(d) { return d.ready })
  readonly property var usbDevices: readyDevices.filter(function(d) { return d.transport === "usb" })
  readonly property string stateLabel: Model.stateLabel(devices, backend.mirroring)

  property int cursor: 0
  property bool showPairing: false
  property string pairEndpoint: ""
  property string pairCode: ""
  property string connectEndpoint: ""
  property double nowMs: Date.now()

  implicitWidth: iconButton.implicitWidth
  implicitHeight: iconButton.implicitHeight

  function refreshNow() { backend.refresh() }

  function mirrorSelected() {
    if (backend.mirroring) { backend.stopMirror(); return }
    var d = readyDevices[Math.max(0, Math.min(cursor, readyDevices.length - 1))]
    if (d) backend.mirror(d)
  }

  function handleBarPress(buttonCode) {
    if (buttonCode === Qt.RightButton) { cursor = 0; mirrorSelected(); return }
    if (buttonCode === Qt.MiddleButton) { refreshNow(); return }
    toggle()
  }

  function moveCursor(delta) {
    if (readyDevices.length === 0) return
    cursor = (cursor + delta + readyDevices.length) % readyDevices.length
  }

  MirrorBackend {
    id: backend
    settings: root.settings
  }

  Timer {
    interval: 1000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.nowMs = Date.now()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshNow(); return "ok" }
    // omarchy-shell shell ipc io.github.ayan-de.android-mirror mirror
    function mirror(): string {
      root.cursor = 0
      if (root.readyDevices.length === 0) return "no device"
      root.mirrorSelected()
      return "ok"
    }
    function stop(): string { backend.stopMirror(); return "ok" }
    // omarchy-shell shell ipc io.github.ayan-de.android-mirror fit
    function fit(): string { return backend.refitWindow() ? "ok" : "no device" }
    function install(): string { backend.installTools(); return "ok" }
  }

  Ui.BarIconButton {
    id: iconButton
    anchors.fill: parent
    bar: root.bar
    text: "󰀲"
    active: backend.mirroring !== null
    tooltipText: "Android · " + root.stateLabel
    onPressed: function(buttonCode) { root.handleBarPress(buttonCode) }
  }

  Ui.KeyboardPanel {
    id: panel
    anchorItem: iconButton
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight)

    Ui.PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: (pairEndpointField.visible && pairEndpointField.activeFocus)
        || (pairCodeField.visible && pairCodeField.activeFocus)
        || (connectField.visible && connectField.activeFocus)

      onActivateRequested: root.mirrorSelected()
      onCloseRequested: root.close()
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onTextKey: function(text) {
        if (text === "r") root.refreshNow()
        else if (text === "p") root.showPairing = !root.showPairing
        else if (text === "w" && root.usbDevices.length > 0) backend.enableWifi(root.usbDevices[0].serial)
      }

      Column {
        id: contentColumn
        width: parent.width
        spacing: Style.spacing.lg

        Ui.PanelHero {
          width: parent.width
          foreground: root.foreground
          fontFamily: root.fontFamily
          title: "Android Mirror"
          meta: root.stateLabel
          detail: backend.mirroring ? "live" : ""
          iconComponent: Component {
            Text {
              text: "󰀲"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
        }

        // Missing tools: the one thing fixed by a pacman command.
        Column {
          width: parent.width
          spacing: Style.spacing.xs
          visible: backend.toolsMissing

          Text {
            width: parent.width
            text: (backend.adbMissing && backend.scrcpyMissing) ? "adb and scrcpy are not installed"
              : backend.adbMissing ? "adb is not installed" : "scrcpy is not installed"
            color: root.urgent
            wrapMode: Text.WordWrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.weight: Font.Medium
          }
          Ui.Button {
            text: backend.installLaunched ? "Install again" : "Install"
            iconText: "󰏔"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            tooltipText: "Opens a terminal and asks for your password"
            onClicked: backend.installTools()
          }

          Text {
            width: parent.width
            text: "omarchy pkg add scrcpy android-tools android-udev\nOr point 'adb path' / 'scrcpy path' in the widget settings at your own binaries."
            color: root.dim
            wrapMode: Text.WordWrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // Devices, one row each. Ready ones get a Mirror button.
        Column {
          width: parent.width
          spacing: Style.spacing.xs
          visible: !backend.toolsMissing

          Ui.PanelSectionHeader {
            width: parent.width
            text: "Phones"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            width: parent.width
            visible: root.devices.length === 0
            text: backend.loading && backend.lastSuccessAt <= 0 ? "Looking for phones…"
              : "Plug in a phone with USB debugging on, or connect over Wi-Fi below."
            color: root.dim
            wrapMode: Text.WordWrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Repeater {
            model: root.devices

            delegate: Item {
              id: row
              required property var modelData
              required property int index
              readonly property bool isMirroring: backend.mirroring && backend.mirroring.serial === modelData.serial
              readonly property int readyIndex: root.readyDevices.findIndex(function(d) { return d.serial === modelData.serial })
              readonly property bool selected: modelData.ready && readyIndex === root.cursor
              width: parent ? parent.width : 0
              height: rowText.implicitHeight + Style.spacing.sm

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius
                color: row.selected ? Style.selectedFillFor(root.foreground, Color.accent) : "transparent"
              }

              Column {
                id: rowText
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.xs
                anchors.right: rowActions.left
                anchors.verticalCenter: parent.verticalCenter
                Text {
                  width: parent.width
                  text: Model.deviceTitle(row.modelData)
                  color: row.modelData.ready ? root.foreground : root.dim
                  elide: Text.ElideRight
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.weight: Font.Medium
                }
                Text {
                  width: parent.width
                  text: Model.deviceSubtitle(row.modelData)
                  color: row.modelData.ready ? root.dim : root.urgent
                  elide: Text.ElideRight
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Row {
                id: rowActions
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.spacing.xs

                Ui.PanelActionButton {
                  visible: row.modelData.ready && row.modelData.transport === "usb"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  iconText: "󰖩"
                  tooltipText: "Enable Wi-Fi mirroring for this phone (adb tcpip), then unplug"
                  enabled: !backend.actionBusy
                  onClicked: backend.enableWifi(row.modelData.serial)
                }
                Ui.PanelActionButton {
                  visible: row.modelData.transport === "wifi"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  iconText: "󰅖"
                  tooltipText: "Disconnect"
                  enabled: !backend.actionBusy
                  onClicked: backend.disconnect(row.modelData.serial)
                }
                Ui.Button {
                  visible: row.modelData.ready
                  text: row.isMirroring ? "Stop" : "Mirror"
                  iconText: row.isMirroring ? "󰓛" : "󰐊"
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: row.isMirroring ? backend.stopMirror() : backend.mirror(row.modelData)
                }
              }

              MouseArea {
                anchors.fill: parent
                anchors.rightMargin: rowActions.width
                enabled: row.modelData.ready
                onClicked: root.cursor = row.readyIndex
                onDoubleClicked: backend.mirror(row.modelData)
              }
            }
          }
        }

        // Wi-Fi: connect to a known address, or pair an Android 11+ phone
        // with the code from Wireless debugging (no cable ever needed).
        Column {
          width: parent.width
          spacing: Style.spacing.sm
          visible: !backend.toolsMissing

          Ui.PanelSectionHeader {
            width: parent.width
            text: "Wi-Fi"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Row {
            width: parent.width
            spacing: Style.spacing.sm
            Ui.TextField {
              id: connectField
              width: parent.width - connectButton.width - parent.spacing
              placeholderText: "192.168.1.42:5555"
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              enabled: !backend.actionBusy
              text: root.connectEndpoint
              onTextChanged: if (text !== root.connectEndpoint) root.connectEndpoint = text
              onAccepted: backend.connect(root.connectEndpoint)
              Keys.onEscapePressed: root.close()
            }
            Ui.Button {
              id: connectButton
              text: "Connect"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: root.connectEndpoint.trim() !== "" && !backend.actionBusy
              onClicked: backend.connect(root.connectEndpoint)
            }
          }

          Ui.Button {
            text: root.showPairing ? "Hide pairing" : "Pair a new phone (Android 11+)"
            iconText: "󰌆"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.showPairing = !root.showPairing
          }

          Column {
            width: parent.width
            spacing: Style.spacing.xs
            visible: root.showPairing

            Text {
              width: parent.width
              text: "On the phone: Settings → Developer options → Wireless debugging → Pair device with pairing code. Enter what it shows."
              color: root.dim
              wrapMode: Text.WordWrap
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Row {
              width: parent.width
              spacing: Style.spacing.sm
              Ui.TextField {
                id: pairEndpointField
                width: (parent.width - parent.spacing * 2) * 0.55
                placeholderText: "192.168.1.42:37123"
                foreground: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                enabled: !backend.actionBusy
                text: root.pairEndpoint
                onTextChanged: if (text !== root.pairEndpoint) root.pairEndpoint = text
                onAccepted: pairCodeField.forceActiveFocus()
                Keys.onEscapePressed: root.close()
              }
              Ui.TextField {
                id: pairCodeField
                width: (parent.width - parent.spacing * 2) * 0.25
                placeholderText: "123456"
                foreground: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                enabled: !backend.actionBusy
                text: root.pairCode
                onTextChanged: if (text !== root.pairCode) root.pairCode = text
                onAccepted: backend.pair(root.pairEndpoint, root.pairCode)
                Keys.onEscapePressed: root.close()
              }
              Ui.Button {
                text: "Pair"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: root.pairEndpoint.trim() !== "" && root.pairCode.trim() !== "" && !backend.actionBusy
                onClicked: backend.pair(root.pairEndpoint, root.pairCode)
              }
            }
          }
        }

        // Feedback from the last action or the mirror process.
        Text {
          width: parent.width
          visible: text !== ""
          text: {
            if (backend.actionBusy) return "Running adb " + backend.actionName + "…"
            if (backend.actionMessage !== "") return backend.actionMessage
            if (backend.mirrorError !== "") return backend.mirrorError
            if (backend.fetchError !== "") return backend.fetchError
            return ""
          }
          color: backend.actionBusy ? root.foreground : ((backend.actionOk && backend.mirrorError === "" && backend.fetchError === "") ? Color.accent : root.urgent)
          wrapMode: Text.WordWrap
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Ui.PanelSeparator {
          width: parent.width
          foreground: root.foreground
        }

        Item {
          width: parent.width
          height: Math.max(footerText.implicitHeight, footerActions.implicitHeight)

          Text {
            id: footerText
            anchors.left: parent.left
            anchors.right: footerActions.left
            anchors.rightMargin: Style.spacing.sm
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            text: {
              if (backend.lastSuccessAt <= 0) return backend.loading ? "Checking…" : "Not checked yet"
              return "Updated " + Model.elapsed(backend.lastSuccessAt, root.nowMs) + "  ·  j/k · enter · w · p"
            }
          }

          Row {
            id: footerActions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xs

            // A manual resize keeps its size but breaks the phone's aspect ratio,
            // which scrcpy fills with bands: one click puts the frame back.
            Ui.PanelActionButton {
              visible: backend.mirroring !== null
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconText: "󰊓"
              tooltipText: "Fit window to the phone screen"
              onClicked: backend.refitWindow()
            }
            Ui.PanelActionButton {
              visible: backend.mirroring !== null
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconText: "󰓛"
              tooltipText: "Stop mirroring"
              onClicked: backend.stopMirror()
            }
            Ui.PanelActionButton {
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconText: "󰑐"
              tooltipText: "Refresh now"
              onClicked: root.refreshNow()
            }
          }
        }
      }
    }
  }

  onOpenedChanged: {
    nowMs = Date.now()
    if (opened) {
      refreshNow()
      backend.actionMessage = ""
    }
  }
}
