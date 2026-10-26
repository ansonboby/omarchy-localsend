import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Incoming-offer banner with working Accept/Decline buttons. Omarchy's own
// toast daemon renders no action buttons, so the plugin draws its own
// banner; no separate system notification is sent for offers.
Variants {
  id: stack

  property var incoming: null
  property bool appMode: false
  property bool busy: false
  property var formatBytes: null

  signal accepted(string id)
  signal declined(string id)

  // A fresh offer re-shows the banner even after an earlier one was dismissed.
  onIncomingChanged: dismissedId = ""

  model: Quickshell.screens

  PanelWindow {
    id: toast

    required property var modelData

    readonly property var request: stack.incoming && stack.incoming.id
      && !stack.appMode && String(stack.incoming.id) !== stack.dismissedId
      ? stack.incoming : null
    readonly property color fg: Color.notifications.text
    readonly property color dim: Qt.darker(fg, 1.55)

    screen: modelData
    visible: request !== null

    WlrLayershell.namespace: "omarchy-localsend-toast"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"

    anchors { top: true; bottom: true; left: true; right: true }

    // Invisible surface is click-through; only the banner takes input.
    mask: Region { item: banner }

    Rectangle {
      id: banner
      anchors.bottom: parent.bottom
      anchors.right: parent.right
      anchors.bottomMargin: Style.space(8)
      // Clear the vertical bar on the right edge.
      anchors.rightMargin: Style.bar.sizeVertical + Style.space(6)
      width: bannerRow.implicitWidth + Style.space(16)
      height: Style.space(52)
      radius: Style.cornerRadius
      color: Color.notifications.background

      Row {
        id: bannerRow
        anchors.fill: parent
        anchors.leftMargin: Style.space(12)
        spacing: Style.space(10)

        Text {
          width: Style.space(24)
          height: parent.height
          verticalAlignment: Text.AlignVCenter
          text: "󰒊"
          color: toast.fg
          font.family: Style.font.family
          textFormat: Text.PlainText
        }

        Column {
          width: Style.space(180)
          height: bannerRow.height
          spacing: Style.space(1)

          Text {
            width: parent.width
            height: parent.height / 2
            verticalAlignment: Text.AlignVCenter
            text: toast.request ? String(toast.request.sender && toast.request.sender.alias ? toast.request.sender.alias : "LocalSend") : ""
            color: toast.fg
            font.bold: true
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
            textFormat: Text.PlainText
          }

          Text {
            width: parent.width
            height: parent.height / 2
            verticalAlignment: Text.AlignVCenter
            text: {
              if (!toast.request) return ""
              var files = toast.request.files instanceof Array ? toast.request.files.length : 0
              return toast.request.messagePreview !== null && toast.request.messagePreview !== undefined
                ? "wants to share clipboard text"
                : "wants to send " + files + (files === 1 ? " file" : " files") + ", "
                  + (stack.formatBytes ? stack.formatBytes(toast.request.totalBytes) : String(toast.request.totalBytes) + " B")
            }
            color: toast.dim
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            textFormat: Text.PlainText
          }
        }

        component ToastButton: BorderSurface {
          id: button

          property string label: ""
          property color tint
          property bool filled: false
          signal clicked()

          width: Style.space(76)
          height: parent.height
          implicitHeight: parent.height
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
          id: acceptButton
          label: "Accept"
          tint: toast.fg
          filled: true
          enabled: !stack.busy
          onClicked: {
            if (!toast.request) return
            var id = String(toast.request.id)
            stack.dismissedId = id
            stack.accepted(id)
          }
        }

        ToastButton {
          id: declineButton
          label: "Decline"
          tint: Color.urgent
          enabled: !stack.busy
          onClicked: {
            if (!toast.request) return
            var id = String(toast.request.id)
            stack.dismissedId = id
            stack.declined(id)
          }
        }
      }
    }
  }
}
