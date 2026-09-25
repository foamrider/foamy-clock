import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "Preferences.js" as Preferences

// Date/time label for the bar, and the host for the calendar popup.
//
// Left click reveals the calendar — asking "what is the date?" is what a
// click on a clock means — right click walks the common label formats, and
// middle click opens the timezone picker.
BarWidget {
  id: root
  moduleName: "foamy.clock"

  property date displayDate: clock.date

  function preference(key) { return Preferences.value(root.settings, key) }
  readonly property string language: Preferences.language(preference("language"), Qt.locale().name)
  function tr(text) { return Preferences.text(text, language) }
  readonly property string localeName: Preferences.localeName(root.settings, Qt.locale().name)
  readonly property var displayLocale: Qt.locale(localeName)
  readonly property string configuredFormat: preference(vertical ? "verticalFormat" : "format")
  readonly property string configuredAltFormat: preference(vertical ? "verticalFormatAlt" : "formatAlt")
  property string settingsError: ""
  property var pendingPreferences: ({})
  readonly property bool saving: preferencesSave.running

  function savePreferences(values) {
    var keys = Object.keys(values)
    // Validate a batch before queuing any writes.
    for (var i = 0; i < keys.length; i++) {
      if (!Preferences.valid(keys[i], values[keys[i]])) {
        settingsError = tr("Invalid setting.") + " " + tr(Preferences.field(keys[i]) ? Preferences.field(keys[i]).label : keys[i])
        return
      }
    }
    settingsError = ""
    for (var j = 0; j < keys.length; j++) pendingPreferences[keys[j]] = values[keys[j]]
    flushPreferences()
  }
  function flushPreferences() {
    if (preferencesSave.running) return
    var keys = Object.keys(pendingPreferences)
    if (!keys.length) return
    var key = keys[0], value = pendingPreferences[key]
    delete pendingPreferences[key]
    preferencesSave.command = ["omarchy-shell", "shell", "setBarWidget", root.moduleName, key, " " + JSON.stringify(value), "{}"]
    preferencesSave.running = true
  }
  Process {
    id: preferencesSave
    stdout: StdioCollector { id: saveOutput; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0 || saveOutput.text.trim() !== "ok") settingsError = tr("Could not save settings.")
      Qt.callLater(root.flushPreferences)
    }
  }

  readonly property var formatRing: Model.clockFormatRing(configuredFormat, configuredAltFormat, Model.clockFormats(vertical))

  // What the bar shows is what shell.json stores, so a cycled format is the
  // format from then on rather than something that reverts on restart.
  readonly property string activeFormat: configuredFormat
  // Tick every second only when the chosen format displays seconds.
  readonly property bool showsSeconds: Model.clockNeedsSeconds(activeFormat)
  readonly property string calendarIcon: "󰸗"
  readonly property string clockIcon: ""
  readonly property string formattedText: formatted(displayDate)
  readonly property var horizontalParts: formattedText.split(clockIcon)
  readonly property string dateText: horizontalParts.length > 1 ? String(horizontalParts[0]).trim() : formattedText
  readonly property string timeText: horizontalParts.length > 1 ? String(horizontalParts.slice(1).join(clockIcon)).trim() : ""
  readonly property var verticalLines: formattedText.split("\n")

  function refresh() {
    displayDate = new Date()
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  function cycleFormat() {
    var current = String(configuredFormat)
    var next = Model.nextClockFormat(formatRing, current)
    if (next === "" || next === current) return

    var values = ({})
    values[vertical ? "verticalFormat" : "format"] = next
    root.savePreferences(values)
  }

  function formatted(date) {
    return displayLocale.toString(date, activeFormat.replace(/ww/g, Model.isoWeekLiteral(date.getFullYear(), date.getMonth(), date.getDate())))
  }

  // ---- Calendar popup. Shape contract for shell.summon/hide/toggle
  //      routing: Bar.findPanelWidget requires open/close/opened on the
  //      bar-widget root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function toggleWeekStart() {
    if (panelLoader.item) panelLoader.item.toggleWeekStart()
  }

  // The clock fills more slot than it paints a mark for, at both
  // orientations: horizontally it is a text label in a padded slot, so the
  // dot takes the label width; vertically it is a stack of icon-sized lines,
  // so the dot takes one line — the same mark every icon widget gets, rather
  // than a rule running the height of the whole stack.
  readonly property real openPanelIndicatorWidth: root.vertical ? Style.bar.iconSlot : horizontalContent.implicitWidth
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity: Bar.requestPopout prefers closeForPopoutSwitch over close, and
  // KeyboardPanel reads popoutSwitchClosing back off its owner.
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  SystemClock {
    id: clock
    precision: root.showsSeconds ? SystemClock.Seconds : SystemClock.Minutes
    onDateChanged: root.displayDate = date
  }

  Loader {
    id: panelLoader
    active: true
    // Inject preferences before Component.onCompleted so an opted-out agenda never starts a query.
    Component.onCompleted: setSource(Qt.resolvedUrl("Panel.qml"), {
      bar: root.bar, settings: root.settings, anchorItem: button, hostWidget: root
    })
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "foamy.clock"

    function settings(): void { if (panelLoader.item) panelLoader.item.openSettings() }
    function refresh(): void { root.broadcast("refresh") }
    function cycleFormat(): void { root.cycleFormat() }
    function toggleWeekStart(): void { root.toggleWeekStart() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    labelVisible: false
    hasVisualContent: root.vertical ? root.verticalLines.length > 0 : horizontalContent.implicitWidth > 0
    fixedWidth: root.vertical ? -1 : horizontalContent.implicitWidth + scaledHorizontalMargin * 2
    fixedHeight: root.vertical ? root.verticalLines.length * Style.bar.iconSlot : -1
    horizontalMargin: 8.75
    verticalPadding: 8.75
    tooltipText: root.tr("Right-click to change format")

    onPressed: function(b) {
      if (b === Qt.RightButton) root.cycleFormat()
      else if (b === Qt.MiddleButton) { if (root.bar) root.bar.run("omarchy-menu-timezone") }
      else root.togglePanel()
    }

    Row {
      id: horizontalContent
      visible: !root.vertical
      anchors.centerIn: parent
      height: button.height
      spacing: Style.spaceReal(6)

      OpticalGlyph {
        width: Math.ceil(tightWidth)
        height: parent.height
        text: root.calendarIcon
        fontFamily: button.fontFamily
        fontSize: button.fontSize
        color: button.foreground
      }

      Text {
        textFormat: Text.PlainText
        height: parent.height
        text: root.dateText
        color: button.foreground
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
        renderType: Text.NativeRendering
        verticalAlignment: Text.AlignVCenter
      }

      OpticalGlyph {
        visible: root.timeText !== ""
        width: visible ? Math.ceil(tightWidth) : 0
        height: parent.height
        text: root.clockIcon
        fontFamily: button.fontFamily
        fontSize: button.fontSize
        color: button.foreground
      }

      Text {
        textFormat: Text.PlainText
        visible: root.timeText !== ""
        height: parent.height
        text: root.timeText
        color: button.foreground
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
        renderType: Text.NativeRendering
        verticalAlignment: Text.AlignVCenter
      }
    }

    Column {
      visible: root.vertical
      anchors.fill: parent

      Repeater {
        model: root.verticalLines

        OpticalGlyph {
          required property string modelData
          width: button.width
          height: Style.bar.iconSlot
          text: modelData
          fontFamily: button.fontFamily
          fontSize: modelData.length > 3
            ? button.fontSize * 0.9
            : button.fontSize
          color: button.foreground
        }
      }
    }
  }
}
