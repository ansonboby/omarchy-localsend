import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

BarWidget {
  id: root

  moduleName: "anson.localsend"

  readonly property var localsend: bar && bar.shell ? bar.shell.serviceFor("anson.localsend") : null
  readonly property color barIconColor: localsend && localsend.incoming
    ? bar.urgent
    : (localsend && localsend.ready ? bar.foreground : Qt.darker(bar.foreground, 1.65))

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }
  function injectPanel() {
    if (!panelLoader.item) return
    panelLoader.item.bar = root.bar
    panelLoader.item.anchorItem = button
    panelLoader.item.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: "LocalSend"
    iconComponent: Component {
      Item {
        LocalSendIcon {
          anchors.centerIn: parent
          iconSize: Style.space(12)
          color: root.barIconColor

          SequentialAnimation on opacity {
            running: root.localsend && root.localsend.incoming !== null
            loops: Animation.Infinite
            NumberAnimation { to: 0.48; duration: 650; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 1.0; duration: 650; easing.type: Easing.InOutQuad }
          }
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) {
        if (root.localsend) root.localsend.refresh()
      } else {
        root.toggle()
      }
    }
  }
}
