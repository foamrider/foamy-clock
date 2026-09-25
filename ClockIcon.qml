import QtQuick
// Control paths match foamy-weather's settings and back buttons.

Image {
  id: root
  property string name: "settings"
  readonly property var paths: ({
    "app-window": '<rect x="2" y="4" width="20" height="16" rx="2"/><path d="M2 8h20M6 4v4"/>',
    "check": '<path d="m20 6-11 11-5-5"/>',
    "arrow-left": '<path d="m12 19-7-7 7-7M5 12h14"/>',
    "chevron-down": '<path d="m6 9 6 6 6-6"/>',
    "chevron-right": '<path d="m9 6 6 6-6 6"/>',
    "settings": '<path d="m10 3-.6 2.3-2 .9-2.1-.7-2 3.5 1.6 1.7v2.6L3.3 15l2 3.5 2.1-.7 2 .9L10 21h4l.6-2.3 2-.9 2.1.7 2-3.5-1.6-1.7v-2.6L20.7 9l-2-3.5-2.1.7-2-.9L14 3Z"/><circle cx="12" cy="12" r="3"/>'
  })
  property color color: "white"
  property real strokeWidth: 1.7
  sourceSize.width: Math.ceil(width * 2)
  sourceSize.height: Math.ceil(height * 2)
  fillMode: Image.PreserveAspectFit
  // Inline SVG keeps the original stroke geometry and follows the active theme.
  source: "data:image/svg+xml;charset=utf-8," + encodeURIComponent(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="'
    + color.toString() + '" stroke-width="' + strokeWidth
    + '" stroke-linecap="round" stroke-linejoin="round">'
    + (paths[name] || paths.settings) + '</svg>')
}
