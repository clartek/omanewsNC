import QtQuick
import qs.Commons

Item {
  id: root
  property real iconSize: Style.font.icon
  property color color: Color.foreground
  property bool syncing: false
  property bool error: false

  width: iconSize
  height: iconSize
  implicitWidth: width
  implicitHeight: height

  readonly property real barHeight: Math.max(1.5, root.iconSize * 0.14)
  readonly property real barSpacing: Math.max(1.5, root.iconSize * 0.14)
  readonly property color fillColor: root.error ? Color.urgent : root.color

  Column {
    anchors.centerIn: parent
    spacing: root.barSpacing

    Rectangle {
      width: Math.max(2, Math.round(root.iconSize * 0.95))
      height: root.barHeight
      radius: height / 2
      color: root.fillColor
      antialiasing: true
    }

    Rectangle {
      width: Math.max(2, Math.round(root.iconSize * 0.67))
      height: root.barHeight
      radius: height / 2
      color: root.fillColor
      antialiasing: true
    }

    Rectangle {
      width: Math.max(2, Math.round(root.iconSize * 0.88))
      height: root.barHeight
      radius: height / 2
      color: root.fillColor
      antialiasing: true
    }

    Rectangle {
      width: Math.max(2, Math.round(root.iconSize * 0.46))
      height: root.barHeight
      radius: height / 2
      color: root.fillColor
      antialiasing: true
    }
  }

  SequentialAnimation on opacity {
    running: root.syncing
    loops: Animation.Infinite
    NumberAnimation { to: 0.3; duration: 600; easing.type: Easing.InOutQuad }
    NumberAnimation { to: 1.0; duration: 600; easing.type: Easing.InOutQuad }
  }
}
