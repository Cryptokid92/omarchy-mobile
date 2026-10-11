// SPDX-License-Identifier: MIT
import QtQuick
import qs.Commons
import qs.Ui

// One quick-settings toggle: glyph, name and a one-line status, sized for a
// thumb. Active tiles take the theme's selected fill and accent border; tiles
// whose backend is missing stay on screen, dimmed, and ignore taps.
BorderSurface {
  id: root

  property string icon: ""
  property string label: ""
  property string status: ""
  property bool active: false
  property bool available: true
  property bool busy: false

  property color foreground: Color.popups.text
  property color accent: Color.accent

  signal clicked()

  implicitHeight: Math.max(64, Style.space(68))
  radius: Style.cornerRadius
  opacity: available ? 1 : 0.45

  readonly property bool _pressed: touch.pressed && available
  readonly property var _activeSpec: Border.flat(accent, Math.max(1, Style.selectedBorderWidth || Style.normalBorderWidth))

  color: _pressed ? Style.pressedFillFor(foreground, accent)
    : active ? Util.alpha(accent, Style.selectedFillAlpha)
    : Style.normalFillFor(foreground, accent)
  borderSpec: active ? _activeSpec : Border.controlSpec("normal", foreground, accent)

  Behavior on color { ColorAnimation { duration: 120 } }

  Text {
    id: glyph
    anchors.left: parent.left
    anchors.leftMargin: root.borderLeft + Style.spacing.xxl
    anchors.verticalCenter: parent.verticalCenter
    width: Style.font.display
    horizontalAlignment: Text.AlignHCenter
    textFormat: Text.PlainText
    text: root.icon
    color: root.active ? root.accent : root.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.display
  }

  Column {
    anchors.left: glyph.right
    anchors.leftMargin: Style.spacing.xl
    anchors.right: parent.right
    anchors.rightMargin: root.borderRight + Style.spacing.lg
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.spacing.xxs

    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: root.label
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.subtitle
      font.bold: true
      elide: Text.ElideRight
    }

    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: root.status
      color: Qt.darker(root.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
      opacity: root.busy ? 0.6 : 1
    }
  }

  MouseArea {
    id: touch
    anchors.fill: parent
    enabled: root.available
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }
}
