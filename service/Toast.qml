import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Incoming-offer banner with working Accept/Decline buttons, styled to
// mirror the shell's own NotificationCard (border, icon slot, fonts).
// Stages on the same surface: offer -> accepted -> saved (click opens the
// file's location in the file manager), or declined (brief flash, hides).
QtObject {
  id: stack

  property var incoming: null
  property var transfers: null
  property bool appMode: false
  property bool busy: false
  property var formatBytes: null
  property string dismissedId: ""
  property string _lastSeenId: ""

  // "", "offer", "accepted", "declined", "saved"; "" = hidden
  property string stage: ""
  property string acceptedId: ""
  property string savedPath: ""
  property string receiveLabel: ""

  signal accepted(string id)
  signal declined(string id)

  // Snapshots replace the incoming object (same id) every poll; only a
  // genuinely new offer id may reset the card, or a click's hide would
  // pop back within half a second.
  onIncomingChanged: {
    var id = incoming && incoming.id ? String(incoming.id) : ""
    if (id !== _lastSeenId) {
      _lastSeenId = id
      if (id !== "") {
        dismissedId = ""
        stage = "offer"
        acceptedId = ""
        savedPath = ""
        receiveLabel = ""
        declinedTimer.stop()
        savedTimer.stop()
      } else if (stage === "offer") {
        // Offer vanished without a decision (expiry): hide.
        stage = ""
      }
    }
  }

  onTransfersChanged: syncTransfer()
  onAppModeChanged: if (appMode) reset()

  function reset() {
    stage = ""
    acceptedId = ""
    savedPath = ""
    receiveLabel = ""
    declinedTimer.stop()
    savedTimer.stop()
  }

  // The accepted request becomes a transfer with the SAME id (see
  // transfer_from_pending), so one scan drives the receiving/saved stages.
  function syncTransfer() {
    if (acceptedId === "") return
    var list = transfers instanceof Array ? transfers : []
    for (var i = 0; i < list.length; i++) {
      var t = list[i]
      if (!t || String(t.id) !== acceptedId) continue
      var state = String(t.state || "")
      if (state === "completed") {
        var files = t.files instanceof Array ? t.files : []
        savedPath = files.length > 0 ? String(files[0].destinationPath || "") : ""
        stage = "saved"
        savedTimer.restart()
      } else if (state === "failed" || state === "cancelled") {
        reset()
      } else if (state !== "" && state !== "declined") {
        stage = "accepted"
      }
      return
    }
  }

  function openSaved() {
    if (savedPath === "") return
    // nautilus --select highlights the file; fall back to opening its folder.
    Quickshell.execDetached([
      "bash", "-c",
      "command -v nautilus >/dev/null 2>&1 && nautilus --select \"$1\" || xdg-open \"$(dirname \"$1\")\"",
      "open-saved-file", savedPath
    ])
  }

  property Timer declinedTimer: Timer { interval: 1500; onTriggered: stack.reset() }
  property Timer savedTimer: Timer { interval: 8000; onTriggered: stack.reset() }

  property var surfaces: Variants {
    model: Quickshell.screens

    delegate: PanelWindow {
      id: toast

      required property var modelData

    readonly property var request: stack.incoming && stack.incoming.id
      && !stack.appMode && String(stack.incoming.id) !== stack.dismissedId
      ? stack.incoming : null
    readonly property color bodyColor: Qt.darker(Color.notifications.text, 1.15)

    screen: modelData
    visible: stack.stage === "offer" ? request !== null : stack.stage !== ""

    WlrLayershell.namespace: "omarchy-localsend-toast"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"

    anchors { top: true; bottom: true; left: true; right: true }

    // Invisible surface is click-through; only the card takes input.
    mask: Region { item: card }

    BorderSurface {
      id: card
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.topMargin: Style.space(8)
      // Clear the vertical bar on the right edge.
      anchors.rightMargin: Style.bar.sizeVertical + Style.space(6)
      width: Style.space(380)
      implicitHeight: mainColumn.implicitHeight + borderTop + borderBottom
      radius: Style.cornerRadius
      color: Color.notifications.background
      borderSpec: Border.surfaceSpec(
        "notifications", "border", Color.notifications.border, Math.max(1, Style.space(2)))
      clip: true

      // Saved stage: the whole card opens the file's location.
      MouseArea {
        anchors.fill: parent
        enabled: stack.stage === "saved"
        cursorShape: stack.stage === "saved" ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: stack.openSaved()
      }

      ColumnLayout {
        id: mainColumn
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: card.borderTop
        anchors.leftMargin: card.borderLeft
        anchors.rightMargin: card.borderRight
        spacing: 0

        RowLayout {
          Layout.fillWidth: true
          Layout.leftMargin: Style.space(12)
          Layout.rightMargin: Style.space(12)
          Layout.topMargin: Style.space(10)
          Layout.bottomMargin: stack.stage === "offer" ? Style.space(2) : Style.space(10)
          spacing: Style.space(12)

          Item {
            Layout.preferredWidth: Style.space(40)
            Layout.preferredHeight: Style.space(40)
            Layout.alignment: Qt.AlignVCenter

            Text {
              anchors.centerIn: parent
              text: "󰒊"
              color: Color.notifications.text
              font.family: Style.font.family
              font.pixelSize: Style.font.displayLarge
              textFormat: Text.PlainText
            }
          }

          ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: {
                if (stack.stage === "accepted") return "✓ Accepted"
                if (stack.stage === "declined") return "✕ Declined"
                if (stack.stage === "saved") return "✓ Saved to Downloads"
                return toast.request
                  ? String(toast.request.sender && toast.request.sender.alias ? toast.request.sender.alias : "LocalSend")
                  : ""
              }
              font.family: "Liberation Sans"
              color: Color.notifications.text
              font.pixelSize: Style.font.title
              font.bold: true
              wrapMode: Text.WordWrap
              elide: Text.ElideRight
              maximumLineCount: 2
            }

            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              Layout.topMargin: Style.space(2)
              text: {
                if (stack.stage === "accepted") return stack.receiveLabel
                if (stack.stage === "declined") return "Transfer will not be received"
                if (stack.stage === "saved") return "Click to show in file manager"
                if (!toast.request) return ""
                var files = toast.request.files instanceof Array ? toast.request.files.length : 0
                return toast.request.messagePreview !== null && toast.request.messagePreview !== undefined
                  ? "Wants to share clipboard text"
                  : "Wants to send " + files + (files === 1 ? " file" : " files") + ", "
                    + (stack.formatBytes ? stack.formatBytes(toast.request.totalBytes) : String(toast.request.totalBytes) + " B")
              }
              font.family: "Liberation Sans"
              color: toast.bodyColor
              font.pixelSize: Style.font.title
              wrapMode: Text.WordWrap
              elide: Text.ElideRight
              maximumLineCount: 3
            }
          }
        }

        RowLayout {
          id: actionRow
          visible: stack.stage === "offer"
          Layout.fillWidth: true
          Layout.leftMargin: Style.space(64)
          Layout.rightMargin: Style.space(12)
          Layout.bottomMargin: Style.space(10)
          spacing: Style.space(8)

          component ToastButton: BorderSurface {
            id: button

            property string label: ""
            property color tint
            property bool filled: false
            signal clicked()

            Layout.fillWidth: true
            implicitHeight: Style.space(32)
            color: filled
              ? Style.selectedFillFor(tint, Color.accent)
              : (mouse.containsMouse ? Style.hoverFillFor(tint, Color.accent) : "transparent")
            borderSpec: Border.controlSpec(mouse.containsMouse ? "hover-cursor" : "normal", tint, Color.accent)
            radius: Style.cornerRadius
            opacity: enabled ? 1.0 : 0.45

            Text {
              anchors.centerIn: parent
              text: button.label
              color: button.tint
              font.pixelSize: Style.font.caption
              font.bold: true
              textFormat: Text.PlainText
            }

            MouseArea {
              id: mouse
              anchors.fill: parent
              hoverEnabled: true
              enabled: button.enabled
              cursorShape: button.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
              onClicked: button.clicked()
            }
          }

          ToastButton {
            label: "Accept"
            tint: Color.notifications.text
            filled: true
            enabled: !stack.busy
            onClicked: {
              if (!toast.request) return
              var id = String(toast.request.id)
              var files = toast.request.files instanceof Array ? toast.request.files : []
              var first = files.length > 0 ? String(files[0].name || "") : ""
              stack.acceptedId = id
              stack.receiveLabel = files.length === 1
                ? "Receiving " + first + "…"
                : "Receiving " + files.length + " files…"
              stack.stage = "accepted"
              stack.dismissedId = id
              stack.accepted(id)
            }
          }

          ToastButton {
            label: "Decline"
            tint: Color.urgent
            enabled: !stack.busy
            onClicked: {
              if (!toast.request) return
              var id = String(toast.request.id)
              stack.stage = "declined"
              stack.dismissedId = id
              declinedTimer.restart()
              stack.declined(id)
            }
          }
        }
      }
    }
    }
  }
}
