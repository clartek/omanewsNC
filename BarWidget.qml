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
    onStatusChanged: {
      if (status === Loader.Error) {
        console.error("OmanewsNC: Failed to load Panel.qml:", sourceComponent ? sourceComponent.errorString() : "unknown error")
      }
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    hasVisualContent: true
    labelVisible: false
    fixedWidth: Style.bar.iconSlot
    tooltipText: root.service
      ? (!root.authenticated
          ? "OmanewsNC: Sign in required"
          : (root.unreadCount > 0
              ? "OmanewsNC: " + root.unreadCount + " unread article" + (root.unreadCount > 1 ? "s" : "")
              : "OmanewsNC: All caught up"))
      : "OmanewsNC: Loading…"

    Item {
      anchors.centerIn: parent
      width: Style.bar.iconFont
      height: Style.bar.iconFont

      NextcloudNewsIcon {
        anchors.fill: parent
        iconSize: Style.bar.iconFont
        color: root.iconColor
        syncing: root.syncing
        error: root.syncError
      }

      Rectangle {
        id: unreadDot
        visible: root.authenticated && root.unreadCount > 0
        width: Style.space(4.5)
        height: width
        radius: width / 2
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: -Style.space(1)
        anchors.rightMargin: -Style.space(1)
        color: root.syncError ? (root.bar ? root.bar.urgent : Color.urgent) : Color.accent
        border.width: 1
        border.color: root.bar ? root.bar.background : Color.background
      }
    }

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton && root.service) root.service.sync()
      else if (buttonCode === Qt.MiddleButton && root.service) root.service.markAllRead(0, 0)
      else root.toggle()
    }
  }
}
