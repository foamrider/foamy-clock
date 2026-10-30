import QtQuick
import qs.Ui
import "kit"

// FoamyDropdown labelDelegate for bar-format presets: a preview such as
// "Fri 30 Oct  14:35" is drawn the way the bar draws it, with the clock
// glyph at its optical bounds and six-pixel gaps (independent of font
// advance widths). Other labels render as plain text.
Item {
  id: root
  property string text: ""
  property color color: FoamyPalette.text

  readonly property string glyph: ""
  readonly property var parts: text.split(glyph)
  readonly property string timeText: parts.length > 1 ? parts.slice(1).join(glyph).trim() : ""
  readonly property bool splitClock: timeText !== ""
  implicitHeight: plainText.implicitHeight
  clip: true

  Text {
    id: plainText
    visible: !root.splitClock
    anchors.fill: parent
    text: root.text
    textFormat: Text.PlainText
    horizontalAlignment: Text.AlignLeft
    verticalAlignment: Text.AlignVCenter
    color: root.color
    font.family: FoamyStyle.fontFamily
    font.pixelSize: FoamyStyle.font.body
    elide: Text.ElideRight
  }

  Row {
    visible: root.splitClock
    height: parent.height
    spacing: Style.spaceReal(6)
    Text {
      width: Math.min(implicitWidth, Math.max(0, root.width - clockGlyph.width - timeLabel.width - parent.spacing * 2))
      height: parent.height
      text: root.parts[0].trim()
      textFormat: Text.PlainText
      color: root.color
      font.family: FoamyStyle.fontFamily
      font.pixelSize: FoamyStyle.font.body
      renderType: Text.NativeRendering
      verticalAlignment: Text.AlignVCenter
      elide: Text.ElideRight
    }
    OpticalGlyph {
      id: clockGlyph
      width: Math.ceil(tightWidth)
      height: parent.height
      text: root.glyph
      fontFamily: FoamyStyle.monoFamily
      fontSize: FoamyStyle.font.body
      color: root.color
    }
    Text {
      id: timeLabel
      width: Math.min(implicitWidth, Math.max(0, root.width - clockGlyph.width - parent.spacing * 2))
      height: parent.height
      text: root.timeText
      textFormat: Text.PlainText
      color: root.color
      font.family: FoamyStyle.fontFamily
      font.pixelSize: FoamyStyle.font.body
      renderType: Text.NativeRendering
      verticalAlignment: Text.AlignVCenter
      elide: Text.ElideRight
    }
  }
}
