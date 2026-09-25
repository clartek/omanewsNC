import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "clartek.omanewsnc"

  readonly property var service: panelLoader.item ? panelLoader.item.service : null
  readonly property bool syncing: service ? service.syncing : false
  readonly property bool syncError: service ? service.syncError : false
  readonly property int unreadCount: service ? service.unreadCount : 0
  readonly property bool authenticated: service ? service.authenticated : false
  readonly property color iconColor: syncError
    ? (bar ? bar.urgent : Color.urgent)
    : authenticated && unreadCount > 0
      ? (bar ? bar.barForeground : Color.foreground)
      : Qt.darker(bar ? bar.barForeground : Color.foreground, 1.55)
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true
    : false

  function plain(value) {
    return String(value || "").replace(/[\u0000-\u001f\u007f]/g, " ").replace(/</g, "‹").replace(/>/g, "›").replace(/&/g, "＆")
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

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
    slotSize: root.unreadCount > 0 ? Style.space(38) : Style.bar.iconSlot
    tooltipText: root.service
      ? (!root.authenticated
          ? "OmanewsNC: Sign in required"
          : (root.unreadCount > 0
              ? "OmanewsNC: " + root.unreadCount + " unread article" + (root.unreadCount > 1 ? "s" : "")
              : "OmanewsNC: All caught up"))
      : "OmanewsNC: Loading…"

    iconComponent: Component {
      Item {
        anchors.fill: parent

        NextcloudNewsIcon {
          anchors.left: root.unreadCount > 0 ? parent.left : undefined
          anchors.centerIn: root.unreadCount > 0 ? undefined : parent
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: root.unreadCount > 0 ? Style.space(2) : 0
          iconSize: Style.space(14)
          color: root.iconColor
          syncing: root.syncing
          error: root.syncError
        }

        Rectangle {
          id: badge
          visible: root.authenticated && root.unreadCount > 0
          anchors.right: parent.right
          anchors.rightMargin: Style.space(1)
          anchors.verticalCenter: parent.verticalCenter
          width: Math.max(Style.space(16), badgeText.implicitWidth + Style.space(6))
          height: Style.space(14)
          radius: height / 2
          color: Color.accent

          Text {
            id: badgeText
            textFormat: Text.PlainText
            anchors.centerIn: parent
            text: root.unreadCount > 999 ? "999+" : String(root.unreadCount)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.space(9)
            font.bold: true
            color: Color.background
          }
        }
      }
    }

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton && root.service) root.service.sync()
      else if (buttonCode === Qt.MiddleButton && root.service) root.service.markAllRead(0, 0)
      else root.toggle()
    }
  }
}
