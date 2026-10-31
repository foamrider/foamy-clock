import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "kit"
import "Model.js" as Model
import "Preferences.js" as Schema

// Date/time label for the bar, and the host for the calendar popup.
//
// Left click reveals the calendar — asking "what is the date?" is what a
// click on a clock means — right click walks the common label formats, and
// middle click opens the timezone picker.
//
// The calendar and agenda state live in ClockService (once per shell); this
// widget is built once per monitor and only renders the label, hosts its
// popup (ClockPanel, content built on first open) and saves settings.
BarWidget {
  id: root
  moduleName: "foamy.clock"

  property date displayDate: clock.date

  // Saved values read at once, even before the host reflects them back.
  function preference(key) { return prefs.value(key) }
  readonly property var effectiveSettings: prefs.effectiveSettings
  function tr(text) { return FoamyI18n.t(text) }
  readonly property string localeName: Schema.localeName(preference("locale"), FoamyI18n.formatLocale)
  readonly property var displayLocale: Qt.locale(localeName)
  readonly property string configuredFormat: preference(vertical ? "verticalFormat" : "format")
  readonly property string configuredAltFormat: preference(vertical ? "verticalFormatAlt" : "formatAlt")
  readonly property string settingsError: prefs.error !== "" ? tr(prefs.error) : ""
  readonly property bool saving: prefs.busy
  readonly property bool canRetry: prefs.canRetry

  // Inline when the host allows it (instant, no process), else one
  // `omarchy bar set` at a time; the newest value per key wins.
  FoamyPrefsQueue {
    id: prefs
    bar: root.bar
    moduleName: root.moduleName
    fields: Schema.fields
    settings: root.settings
  }
  function save(key, value) { prefs.save(key, value) }
  function retrySave() { prefs.retry() }

  readonly property var formatRing: Model.clockFormatRing(configuredFormat, configuredAltFormat, Model.clockFormats(vertical))

  // What the bar shows is what shell.json stores, so a cycled format is the
  // format from then on rather than something that reverts on restart.
  readonly property string activeFormat: configuredFormat
  // Tick every second only when the chosen format displays seconds.
  readonly property bool showsSeconds: Model.clockNeedsSeconds(activeFormat)
  readonly property string calendarIcon: "\u{f0e17}"
  readonly property string clockIcon: "\u{f017}"
  readonly property string formattedText: formatted(displayDate)
  readonly property var horizontalParts: formattedText.split(clockIcon)
  readonly property string dateText: horizontalParts.length > 1 ? String(horizontalParts[0]).trim() : formattedText
  readonly property string timeText: horizontalParts.length > 1 ? String(horizontalParts.slice(1).join(clockIcon)).trim() : ""
  readonly property var verticalLines: formattedText.split("\n")

  function refresh() {
    displayDate = new Date()
    // The shared state refreshes once, from the leader (an explicit request).
    if (member.isLeader) ClockService.refresh()
  }

  function cycleFormat() {
    var current = String(configuredFormat)
    var next = Model.nextClockFormat(formatRing, current)
    if (next === "" || next === current) return

    root.save(vertical ? "verticalFormat" : "format", next)
  }

  function formatted(date) {
    return displayLocale.toString(date, activeFormat.replace(/ww/g, Model.isoWeekLiteral(date.getFullYear(), date.getMonth(), date.getDate())))
  }

  // ---- Calendar popup. Shape contract for shell.summon/hide/toggle
  //      routing: Bar.findPanelWidget requires open/close/opened on the
  //      bar-widget root.
  readonly property bool opened: panel.opened
  function open() { panel.open() }
  function close() { panel.close() }
  function togglePanel() { panel.toggle() }
  function openSettings() { panel.openSettings() }

  function toggleWeekStart() {
    var next = Model.toggledWeekStart(ClockService.weekStart)
    save("weekStartDay", Model.weekStartSettingName(next))
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
  readonly property bool popoutSwitchClosing: panel.popoutSwitchClosing === true

  function closeForPopoutSwitch() { panel.closeForPopoutSwitch() }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Once per shell: the leader feeds the shared calendar state and owns IPC;
  // an open popup on any monitor raises demand (the clock ticks only then).
  FoamyMember { id: member; scope: "clock"; demanding: root.opened }
  Binding { target: ClockService; property: "agendaEnabled"; value: root.preference("agendaEnabled"); when: member.isLeader; restoreMode: Binding.RestoreNone }
  Binding { target: ClockService; property: "refreshMinutes"; value: root.preference("agendaRefreshMinutes"); when: member.isLeader; restoreMode: Binding.RestoreNone }
  Binding { target: ClockService; property: "showSeconds"; value: root.preference("showSeconds"); when: member.isLeader; restoreMode: Binding.RestoreNone }
  Binding { target: ClockService; property: "weekStart"; value: Model.normalizedWeekStart(root.preference("weekStartDay"), root.displayLocale.firstDayOfWeek); when: member.isLeader; restoreMode: Binding.RestoreNone }
  Binding { target: ClockService; property: "demanded"; value: member.demanded; when: member.isLeader; restoreMode: Binding.RestoreNone }

  SystemClock {
    id: clock
    precision: root.showsSeconds ? SystemClock.Seconds : SystemClock.Minutes
    onDateChanged: root.displayDate = date
  }

  ClockPanel {
    id: panel
    visible: false
    bar: root.bar
    settings: root.effectiveSettings
    anchorItem: button
    hostWidget: root
  }

  FoamyIpc {
    target: "foamy.clock"
    enabled: member.isLeader

    function settings(): void { root.openSettings() }
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
