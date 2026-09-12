import QtQuick
import QtQuick.Shapes
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

  readonly property real scaleFactor: iconSize / 100
  readonly property real strokeW: 10 * scaleFactor

  Shape {
    id: shape
    anchors.fill: parent
    antialiasing: true
    preferredRendererType: Shape.CurveRenderer
    layer.enabled: true
    layer.samples: 4

    // Dot at bottom-left
    ShapePath {
      strokeColor: "transparent"
      fillColor: root.error ? Color.urgent : root.color
      startX: 20 * root.scaleFactor
      startY: 80 * root.scaleFactor
      PathArc {
        x: 36 * root.scaleFactor
        y: 80 * root.scaleFactor
        radiusX: 8 * root.scaleFactor
        radiusY: 8 * root.scaleFactor
        useLargeArc: true
      }
      PathArc {
        x: 20 * root.scaleFactor
        y: 80 * root.scaleFactor
        radiusX: 8 * root.scaleFactor
        radiusY: 8 * root.scaleFactor
        useLargeArc: true
      }
    }

    // Inner Arc
    ShapePath {
      strokeColor: root.error ? Color.urgent : root.color
      strokeWidth: root.strokeW
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap
      startX: 20 * root.scaleFactor
      startY: 48 * root.scaleFactor
      PathArc {
        x: 52 * root.scaleFactor
        y: 80 * root.scaleFactor
        radiusX: 32 * root.scaleFactor
        radiusY: 32 * root.scaleFactor
      }
    }

    // Outer Arc
    ShapePath {
      strokeColor: root.error ? Color.urgent : root.color
      strokeWidth: root.strokeW
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap
      startX: 20 * root.scaleFactor
      startY: 22 * root.scaleFactor
      PathArc {
        x: 78 * root.scaleFactor
        y: 80 * root.scaleFactor
        radiusX: 58 * root.scaleFactor
        radiusY: 58 * root.scaleFactor
      }
    }
  }

  SequentialAnimation on opacity {
    running: root.syncing
    loops: Animation.Infinite
    NumberAnimation { to: 0.3; duration: 600; easing.type: Easing.InOutQuad }
    NumberAnimation { to: 1.0; duration: 600; easing.type: Easing.InOutQuad }
  }
}
