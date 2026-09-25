import QtQuick
import QtQuick.Controls as Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "Preferences.js" as Preferences

// Time-first popup sharing the weather panel's typography and surfaces.
// The month grid selects the agenda below it; today keeps its own outline.
//
// BarWidget.qml owns the bar label and hands this panel the button to
// anchor against.
Panel {
  id: root
  moduleName: "foamy.clock"
  ipcTarget: "foamy.clock"
  manageIpc: false

  property var anchorItem: null
  function preference(key) { return Preferences.value(root.settings, key) }
  readonly property string language: Preferences.language(preference("language"), Qt.locale().name)
  function tr(text) { return Preferences.text(text, language) }
  property bool editingSettings: false
  property string launchError: ""
  readonly property bool agendaEnabled: preference("agendaEnabled")
  readonly property string timeFormat: preference("timeFormat") === "12-hour" ? "h:mm AP" : "HH:mm"
  readonly property string helperPath: decodeURIComponent(Qt.resolvedUrl("calendar-events.py").toString().replace(/^file:\/\//, ""))
  function openSettings() {
    root.open()
    root.editingSettings = true
    settingsScroll.contentY = 0
    Qt.callLater(function() { settingsPane.focusBack() })
  }
  function closeSettings() {
    root.editingSettings = false
    Qt.callLater(function() { settingsButton.forceActiveFocus() })
  }
  onOpenedChanged: if (!opened) editingSettings = false
  onAgendaEnabledChanged: {
    // Drop visible data immediately. In-flight results are ignored when disabled.
    root.calendarDates = ({})
    root.resetAgendaView()
    root.lastAgendaRangeRefreshMs = 0
    if (agendaEnabled) Qt.callLater(root.requestAgendaDate)
  }

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel. Everything the bar identifies a panel by has to be that
  // widget: the popout coordinator (and with it the open-panel dot under the
  // pill) compares against `slot.activeItem`, and switchPanelFrom looks the
  // slot up the same way.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- Today. SystemClock keeps this honest across midnight so the
  //      highlight rolls over without the panel being reopened.
  property date today: new Date()
  readonly property string todayKey: Model.keyForDate(today)
  property date selectedDate: new Date(today.getFullYear(), today.getMonth(), today.getDate())
  readonly property string selectedDateKey: Model.keyForDate(selectedDate)
  readonly property bool selectedDateIsToday: selectedDateKey === todayKey

  // Month stepping does not change the selected agenda date until a day is
  // clicked, keeping browsing and selection as separate deliberate actions.
  property int viewYear: today.getFullYear()
  property int viewMonth: today.getMonth()

  readonly property date viewDate: new Date(viewYear, viewMonth, 1)
  readonly property bool viewingCurrentMonth: viewYear === today.getFullYear() && viewMonth === today.getMonth()

  // The agenda comes from the selected Evolution Data Server calendars, which
  // is the same source set GNOME Calendar presents. A private on-disk cache is
  // loaded first so a slow account never blanks the panel.
  property var agendaEvents: []
  property var calendarDates: ({})
  readonly property int maxEventDots: 5
  property string agendaState: "loading"
  property string agendaMessage: ""
  property string agendaDateKey: ""
  property int selectedCalendars: 0
  property double lastAgendaRefreshMs: 0
  property date now: new Date()
  property bool agendaCached: false
  property string agendaProcessDateKey: ""
  property string agendaProcessRangeStartKey: ""
  property string agendaProcessRangeEndKey: ""
  property string cacheProcessDateKey: ""
  property bool agendaPayloadApplied: false
  property bool cachePayloadApplied: false
  property double lastAgendaRangeRefreshMs: 0
  property string lastAgendaRangeKey: ""
  readonly property int agendaRefreshIntervalMs: preference("agendaRefreshMinutes") * 60000
  readonly property bool agendaLoading: agendaProcess.running || cacheProcess.running
  readonly property date agendaRangeStartDate: new Date(viewYear, viewMonth - 1, 1)
  readonly property date agendaRangeEndDate: new Date(viewYear, viewMonth + 2, 1)
  readonly property string agendaRangeStartKey: Model.keyForDate(agendaRangeStartDate)
  readonly property string agendaRangeEndKey: Model.keyForDate(agendaRangeEndDate)
  readonly property string agendaRangeKey: agendaRangeStartKey + ":" + agendaRangeEndKey
  readonly property string agendaDateLabel: selectedDateIsToday
    ? localText("I dag", "Today")
    : displayLocale.toString(selectedDate, "ddd d MMM")
  readonly property string agendaUpdatedText: updatedAgoText()

  readonly property string localeName: Preferences.localeName(root.settings, Qt.locale().name)
  readonly property var displayLocale: Qt.locale(localeName)
  readonly property bool norwegian: root.language === "nb"
  property string timeZoneName: ""

  function heroTimeText() {
    if (root.preference("timeFormat") !== "12-hour") return root.displayLocale.toString(root.now, "HH:mm")
    // Qt chooses 12-hour h only when the same format contains an AM/PM token.
    var full = root.displayLocale.toString(root.now, "h:mm AP")
    var period = root.displayLocale.toString(root.now, "AP")
    return period ? full.slice(0, -period.length).trim() : full
  }

  function localText(norwegianText, englishText) {
    return norwegian ? norwegianText : englishText
  }

  // Unset falls through to the locale's own first day, so a fresh install
  // starts out matching the rest of the desktop rather than a hardcoded
  // convention. Clicking the grid's "W" heading writes the choice back to
  // shell.json.
  readonly property int weekStart: Model.normalizedWeekStart(preference("weekStartDay"), displayLocale.firstDayOfWeek)
  readonly property string nextWeekStartLabel: displayLocale.dayName(Model.toggledWeekStart(weekStart), Locale.LongFormat)
  readonly property var weekdays: Model.weekdayOrder(weekStart)
  readonly property var weeks: Model.monthGrid(viewYear, viewMonth, weekStart, todayKey)


  // Guarded so the widget renders before the bar is injected (the bar-widget
  // contract instantiates it bare).
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: "sans-serif"
  readonly property string iconFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color secondaryForeground: Qt.tint(Color.popups.background, Qt.rgba(contentForeground.r, contentForeground.g, contentForeground.b, 0.76))
  readonly property color weekForeground: Qt.tint(Color.popups.background, Qt.rgba(contentForeground.r, contentForeground.g, contentForeground.b, 0.60))
  readonly property color outlineColor: Qt.tint(Color.popups.background, Qt.rgba(contentForeground.r, contentForeground.g, contentForeground.b, 0.22))
  readonly property color cardColor: Qt.tint(Color.popups.background, Qt.rgba(contentForeground.r, contentForeground.g, contentForeground.b, 0.055))
  readonly property color weekColumnColor: Qt.tint(Color.popups.background, Qt.rgba(contentForeground.r, contentForeground.g, contentForeground.b, 0.035))
  readonly property color selectedCardColor: Qt.tint(Color.popups.background, Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.20))
  readonly property real cellWidth: Math.max(1, (body.width - weekColumnWidth - gutterWidth - cellSpacing * 6) / 7)
  // Leave room for the agenda on short displays without scrolling the calendar.
  readonly property bool compactHeight: panel.availableCardHeight > 0 && panel.availableCardHeight < Style.space(760)
  readonly property bool veryShortHeight: panel.availableCardHeight > 0 && panel.availableCardHeight < Style.space(600)
  readonly property int cellHeight: Style.space(veryShortHeight ? 24 : compactHeight ? 28 : 38)
  readonly property int cellSpacing: Style.space(2)
  readonly property int weekColumnWidth: Style.space(32)
  readonly property int gutterWidth: Style.space(5)

  function open() {
    refresh()
    root.controller.show()
    // Set after showing, not before: showing hands the popout coordinator
    // over, which closes whichever panel was open, and that close clears the
    // shared flag. Deferring means the panel taking over always wins, while
    // a handoff to a panel that does not manage the flag still leaves it
    // cleared rather than stuck on.
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    // Dismissing the panel mid-edit would otherwise leave the inputs up,
    // waiting behind a closed popup for the next time it opens.
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // Summoning by hotkey moves no pointer, so a hover the bar was still
  // holding must not keep the center indicators revealed behind the panel.
  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function refresh() {
    root.today = new Date()
    root.now = root.today
    if (!timeZoneProcess.running) timeZoneProcess.running = true
    root.goToToday()
  }

  function requestAgendaDate() {
    if (!root.agendaEnabled) return
    if (cacheProcess.running || agendaProcess.running) return

    root.resetAgendaView()
    root.cachePayloadApplied = false
    root.cacheProcessDateKey = root.selectedDateKey
    cacheProcess.running = true
  }

  function resetAgendaView() {
    agendaScroll.contentY = 0
    root.agendaEvents = []
    root.agendaState = "loading"
    root.agendaMessage = ""
    root.agendaDateKey = ""
    root.lastAgendaRefreshMs = 0
    root.agendaCached = false
  }

  function refreshAgenda(force) {
    if (!root.agendaEnabled) return
    if (cacheProcess.running || agendaProcess.running) return
    if (root.agendaDateKey !== root.selectedDateKey) {
      root.requestAgendaDate()
      return
    }
    if (!force && root.lastAgendaRangeKey === root.agendaRangeKey
        && root.lastAgendaRangeRefreshMs > 0
        && Date.now() - root.lastAgendaRangeRefreshMs < root.agendaRefreshIntervalMs) return

    root.agendaPayloadApplied = false
    root.agendaProcessDateKey = root.selectedDateKey
    root.agendaProcessRangeStartKey = root.agendaRangeStartKey
    root.agendaProcessRangeEndKey = root.agendaRangeEndKey
    if (root.agendaEvents.length === 0) root.agendaState = "loading"
    agendaProcess.running = true
  }

  function applyAgendaPayload(raw, fromCache, expectedDateKey) {
    if (!root.agendaEnabled) return false
    try {
      var payload = JSON.parse(String(raw || ""))
      if (!payload || !Array.isArray(payload.events)) throw new Error("invalid calendar payload")
      if (String(payload.date || "") !== String(expectedDateKey)
          || String(expectedDateKey) !== root.selectedDateKey) return false
      if (String(payload.state || "") === "missing") return false

      var incomingState = String(payload.state || "error")
      if (!fromCache && root.agendaCached && root.agendaEvents.length > 0
          && (incomingState === "error" || incomingState === "partial")) {
        root.agendaState = "cached"
        root.agendaMessage = incomingState === "partial"
          ? String(payload.message || "Some calendars could not refresh") + " · showing cached events"
          : "Showing cached calendar data"
        return true
      }

      root.agendaEvents = payload.events
      root.agendaState = incomingState
      root.agendaMessage = String(payload.message || "")
      root.agendaDateKey = String(payload.date)
      root.selectedCalendars = Math.max(0, Number(payload.selectedCalendars) || 0)
      root.lastAgendaRefreshMs = Math.max(0, Number(payload.updatedAt) || 0) * 1000
      root.agendaCached = fromCache || payload.cached === true || incomingState === "cached"
      return true
    } catch (error) {
      return false
    }
  }

  function eventsForDate(key) {
    if (key === root.agendaDateKey) return root.agendaEvents
    var day = root.calendarDates[key]
    return day && Array.isArray(day.events) ? day.events : []
  }

  function calendarDots(events) {
    var seen = new Set()
    var dots = []
    for (var event of events) {
      // The helper prefixes event IDs with the EDS source UID, so calendars
      // with identical names or colors still get separate dots.
      var calendarId = event.id.substring(0, event.id.indexOf(":"))
      if (seen.has(calendarId)) continue
      seen.add(calendarId)
      dots.push(event)
      if (dots.length === root.maxEventDots) break
    }
    return dots
  }

  // Read the shared range cache once, rather than starting a query per cell.
  FileView {
    id: calendarCache
    path: root.agendaEnabled ? (Quickshell.env("XDG_CACHE_HOME").trim() || (Quickshell.env("HOME") + "/.cache"))
      + "/foamy-clock/agenda-v1.json" : ""
    watchChanges: root.agendaEnabled
    onFileChanged: reload()
    onLoaded: {
      try {
        var cache = JSON.parse(text())
        if (cache.version !== 1 || !cache.dates || typeof cache.dates !== "object")
          throw new Error("Invalid calendar cache")
        root.calendarDates = cache.dates
      } catch (error) {
        root.calendarDates = ({})
        console.warn("Calendar dots: " + error)
      }
    }
    onLoadFailed: root.calendarDates = ({})
  }

  function agendaMessageText() {
    if (root.agendaState === "error") return root.localText("Kalenderdata er utilgjengelige", "Calendar data is unavailable")
    if (root.agendaState === "partial") return root.localText("Noen kalendere kunne ikke oppdateres", "Some calendars could not refresh")
    if (root.agendaState === "cached") return root.localText("Viser lagrede kalenderdata", "Showing cached calendar data")
    return root.agendaMessage
  }

  function updatedAgoText() {
    if (root.lastAgendaRefreshMs <= 0) return ""
    var elapsedMinutes = Math.max(0, Math.floor((root.now.getTime() - root.lastAgendaRefreshMs) / 60000))
    if (elapsedMinutes === 0) return localText("Oppdatert nå", "Updated just now")
    if (elapsedMinutes === 1) return localText("Oppdatert for 1 minutt siden", "Updated 1 minute ago")
    return localText("Oppdatert for " + elapsedMinutes + " minutter siden", "Updated " + elapsedMinutes + " minutes ago")
  }

  function eventState(event) {
    if (!event || event.allDay === true) return "all-day"
    var current = root.now.getTime() / 1000
    if (current < Number(event.start || 0)) return "upcoming"
    if (current < Number(event.end || event.start || 0)) return "ongoing"
    return "past"
  }

  function eventTimeText(event) {
    if (!event || event.allDay === true) return localText("Hele dagen", "All day")
    var start = root.displayLocale.toString(new Date(Number(event.start) * 1000), root.timeFormat)
    var end = root.displayLocale.toString(new Date(Number(event.end) * 1000), root.timeFormat)
    return start + "–" + end
  }

  function eventDetails(event) {
    var calendar = String(event && event.calendar ? event.calendar : "Calendar")
    var location = root.preference("showEventLocations") ? String(event && event.location ? event.location : "") : ""
    return location === "" ? calendar : calendar + "  ·  " + location
  }

  function openCalendar() {
    if (!calendarLaunch.running) calendarLaunch.running = true
  }

  function goToToday() {
    root.viewYear = today.getFullYear()
    root.viewMonth = today.getMonth()
    if (!root.selectedDateIsToday) {
      root.selectDate(today.getFullYear(), today.getMonth(), today.getDate())
      return
    }
    root.refreshAgenda(false)
  }

  function selectDate(year, month, day) {
    var nextDate = new Date(year, month, day)
    var nextKey = Model.keyForDate(nextDate)
    root.viewYear = nextDate.getFullYear()
    root.viewMonth = nextDate.getMonth()
    if (nextKey === root.selectedDateKey) return

    root.selectedDate = nextDate
    // A previous date may still be loading. Clear it immediately so its rows
    // are never presented under the newly selected date heading.
    root.resetAgendaView()
    root.requestAgendaDate()
  }

  function moveMonth(delta) {
    var next = Model.stepMonth(viewYear, viewMonth, delta)
    root.viewYear = next.year
    root.viewMonth = next.month
    // Warm the surrounding months as soon as they are browsed. If another
    // range is still loading, its completion queues this newest range.
    Qt.callLater(function() { root.refreshAgenda(false) })
  }

  function moveYear(delta) {
    moveMonth(delta * 12)
  }

  function persistSettings(values) {
    if (root.hostWidget) root.hostWidget.savePreferences(values)
  }

  Process {
    id: calendarLaunch
    // Check PATH first; detach the app so its lifetime is independent of this popup.
    command: ["sh", "-c", 'command -v "$1" >/dev/null 2>&1', "foamy-clock", root.preference("calendarApp")]
    onExited: function(exitCode) {
      root.launchError = exitCode === 0 ? "" : root.tr("Calendar app could not be started.")
      if (exitCode === 0) {
        Quickshell.execDetached(["omarchy-launch-or-focus", root.preference("calendarApp")])
        root.close()
      }
    }
  }

  function setWeekStart(day) {
    var next = Model.normalizedWeekStart(day, root.weekStart)
    if (next === root.weekStart) return
    persistSettings({ weekStartDay: Model.weekStartSettingName(next) })
  }

  function toggleWeekStart() {
    setWeekStart(Model.toggledWeekStart(root.weekStart))
  }

  // Narrow locale labels keep all seven columns readable on small screens.
  function weekdayLabel(weekday) {
    return displayLocale.dayName(weekday, Locale.NarrowFormat)
  }

  // Resolve the system's IANA zone when opened, including timezone changes
  // made from the bar. A non-zoneinfo localtime file uses Qt's zone label.
  Process {
    id: timeZoneProcess
    command: ["readlink", "-f", "/etc/localtime"]
    stdout: StdioCollector {
      onStreamFinished: {
        var match = String(text).trim().match(/\/zoneinfo\/(.+)$/)
        root.timeZoneName = match ? match[1] : ""
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.timeZoneName = ""
    }
  }

  SystemClock {
    id: clock
    precision: root.opened && root.preference("showSeconds") ? SystemClock.Seconds : SystemClock.Minutes
    onDateChanged: {
      root.now = clock.date
      if (Model.keyForDate(clock.date) === String(root.todayKey)) return
      var followToday = root.viewingCurrentMonth
      var selectedToday = root.selectedDateIsToday
      root.today = clock.date
      if (followToday) root.goToToday()
      if (selectedToday && !followToday)
        root.selectDate(clock.date.getFullYear(), clock.date.getMonth(), clock.date.getDate())
    }
  }

  Component.onCompleted: root.requestAgendaDate()

  Process {
    id: cacheProcess
    command: [
      "timeout",
      "2s",
      "nice",
      "-n",
      "10",
      "python3",
      root.helperPath,
      "--cached",
      "--date",
      root.cacheProcessDateKey
    ]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.cachePayloadApplied = root.applyAgendaPayload(
        text, true, root.cacheProcessDateKey)
    }
    onExited: Qt.callLater(function() {
      if (!root.agendaEnabled) return
      if (root.cacheProcessDateKey !== root.selectedDateKey) root.requestAgendaDate()
      else {
        // A cache miss still belongs to this date; mark it current so the
        // following live refresh does not loop back through the cache reader.
        root.agendaDateKey = root.selectedDateKey
        root.refreshAgenda(!root.cachePayloadApplied)
      }
    })
  }

  Process {
    id: agendaProcess
    command: [
      "timeout",
      // Slow remote calendars can need a minute or two to wake up. This runs
      // off the UI thread and cached rows remain visible while it waits.
      "150s",
      "nice",
      "-n",
      "10",
      "python3",
      root.helperPath,
      "--date",
      root.agendaProcessDateKey,
      "--range-start",
      root.agendaProcessRangeStartKey,
      "--range-end",
      root.agendaProcessRangeEndKey
    ]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.agendaPayloadApplied = root.applyAgendaPayload(
        text, false, root.agendaProcessDateKey)
    }
    onExited: function(exitCode) {
      if (!root.agendaEnabled) return
      // Also reload after the first refresh, when no cache existed to watch.
      calendarCache.reload()
      var completedRangeKey = root.agendaProcessRangeStartKey
        + ":" + root.agendaProcessRangeEndKey
      root.lastAgendaRangeKey = completedRangeKey
      root.lastAgendaRangeRefreshMs = Date.now()

      if (root.agendaProcessDateKey !== root.selectedDateKey) {
        Qt.callLater(function() { root.requestAgendaDate() })
        return
      }

      if (exitCode !== 0 && !root.agendaPayloadApplied) {
        if (root.agendaEvents.length > 0) {
          root.agendaState = "cached"
          root.agendaMessage = "Showing cached calendar data"
        } else {
          root.agendaState = "error"
          root.agendaMessage = "Calendar data is unavailable"
        }
      }

      if (completedRangeKey !== root.agendaRangeKey)
        Qt.callLater(function() { root.refreshAgenda(true) })
    }
  }

  Timer {
    interval: root.agendaRefreshIntervalMs
    repeat: true
    running: root.agendaEnabled
    onTriggered: root.refreshAgenda(true)
  }

  component ClockLabel: Text {
    textFormat: Text.PlainText
    color: root.contentForeground
    font.family: root.contentFontFamily
    font.pixelSize: Style.space(13)
  }

  ClockPopup {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: root.editingSettings ? settingsPane.backTarget : keyCatcher
    padding: 0
    borderSpec: Border.flat(root.outlineColor, 1)
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(root.editingSettings ? Math.min(settingsPane.implicitHeight, Style.space(620)) : calendarColumn.implicitHeight)

    Flickable {
      id: settingsScroll
      visible: root.editingSettings
      anchors.fill: parent
      clip: true
      contentWidth: width
      contentHeight: settingsPane.implicitHeight
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick
      Keys.onEscapePressed: root.closeSettings()
      onContentHeightChanged: contentY = Math.max(0, Math.min(contentY, contentHeight - height))
      onHeightChanged: contentY = Math.max(0, Math.min(contentY, contentHeight - height))
      Connections {
        target: settingsScroll.Window.window
        function onActiveFocusItemChanged() {
          var item = target.activeFocusItem
          if (!root.editingSettings || !item) return
          var point = item.mapToItem(settingsScroll.contentItem, 0, 0)
          if (point.y < settingsScroll.contentY) settingsScroll.contentY = Math.max(0, point.y - Style.space(8))
          else if (point.y + item.height > settingsScroll.contentY + settingsScroll.height)
            settingsScroll.contentY = Math.max(0, Math.min(settingsScroll.contentHeight - settingsScroll.height, point.y + item.height - settingsScroll.height + Style.space(8)))
        }
      }
      Controls.ScrollBar.vertical: Controls.ScrollBar {
        visible: settingsScroll.contentHeight > settingsScroll.height
        width: Style.space(4)
        padding: 0
        contentItem: Rectangle { implicitWidth: Style.space(4); radius: width / 2; color: root.secondaryForeground }
        background: Item {}
      }
      SettingsPane {
        id: settingsPane
        width: parent.width
        settings: root.settings
        language: root.language
        saving: root.hostWidget ? root.hostWidget.saving : false
        error: root.hostWidget ? root.hostWidget.settingsError : ""
        onClearError: if (root.hostWidget) root.hostWidget.settingsError = ""
        onSave: function(key, value) { var patch = ({}); patch[key] = value; root.persistSettings(patch) }
        onBack: root.closeSettings()
      }
    }

    PanelKeyCatcher {
      id: keyCatcher
      visible: !root.editingSettings
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.moveMonth(dx)
        if (dy !== 0) root.moveYear(dy)
      }
      onActivateRequested: root.goToToday()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "[") root.moveMonth(-1)
        else if (t === "]") root.moveMonth(1)
        else if (t === "{") root.moveYear(-1)
        else if (t === "}") root.moveYear(1)
        else if (t === "t" || t === "T") root.goToToday()
        else if (t === "w" || t === "W") root.toggleWeekStart()
      }
      Keys.onReleased: function(event) {
        if (!agendaScroll.interactive) return
        var direction = event.key === Qt.Key_PageDown ? 1 : event.key === Qt.Key_PageUp ? -1 : 0
        if (direction === 0) return
        agendaScroll.cancelFlick()
        agendaScroll.contentY = Math.max(0, Math.min(agendaScroll.contentHeight - agendaScroll.height,
          agendaScroll.contentY + direction * agendaScroll.height))
        event.accepted = true
      }

      Item {
        anchors.fill: parent
        clip: true

        Column {
          id: calendarColumn
          width: parent.width

          Item {
            id: hero
            width: parent.width
            height: heroContent.implicitHeight + Style.space(root.veryShortHeight ? 16 : root.compactHeight ? 24 : 49)

            // Match weather's static header wash; the seconds never repaint it.
            Canvas {
              id: headerBackground
              anchors.fill: parent
              onWidthChanged: requestPaint()
              onHeightChanged: requestPaint()
              onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                var radius = Style.space(13)
                ctx.beginPath()
                ctx.moveTo(radius, 0); ctx.lineTo(width - radius, 0)
                ctx.quadraticCurveTo(width, 0, width, radius)
                ctx.lineTo(width, height); ctx.lineTo(0, height); ctx.lineTo(0, radius)
                ctx.quadraticCurveTo(0, 0, radius, 0); ctx.closePath(); ctx.clip()
                var gradient = ctx.createLinearGradient(0, 0, width * 0.5, height)
                gradient.addColorStop(0, Qt.tint(Color.popups.background, Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.08)))
                gradient.addColorStop(1, Color.popups.background)
                ctx.fillStyle = gradient; ctx.fillRect(0, 0, width, height)
                var glow = ctx.createRadialGradient(width * 0.9, 0, 0, width * 0.9, 0, width * 0.85)
                glow.addColorStop(0, Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.17))
                glow.addColorStop(1, "transparent")
                ctx.fillStyle = glow; ctx.fillRect(0, 0, width, height)
              }
              Connections {
                target: Color
                function onAccentChanged() { headerBackground.requestPaint() }
                function onShellValuesChanged() { headerBackground.requestPaint() }
                function onBackgroundChanged() { headerBackground.requestPaint() }
              }
            }

            Column {
              id: heroContent
              anchors.centerIn: parent
              width: parent.width - Style.space(28)
              spacing: Style.space(root.compactHeight ? 5 : 9)

              ClockLabel {
                visible: !root.veryShortHeight && root.preference("showTimeZone")
                width: parent.width - Style.space(64)
                anchors.horizontalCenter: parent.horizontalCenter
                horizontalAlignment: Text.AlignHCenter
                text: root.timeZoneName || Qt.formatDateTime(root.now, "t")
                font.pixelSize: Style.space(12)
                elide: Text.ElideRight
              }

              Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.space(5)
                height: heroClock.implicitHeight

                ClockLabel {
                  id: heroClock
                  text: root.heroTimeText()
                  font.pixelSize: Style.space(root.veryShortHeight ? 32 : root.compactHeight ? 40 : 56)
                  font.features: ({ "tnum": 1 })
                }
                ClockLabel {
                  visible: root.preference("showSeconds")
                  anchors.baseline: heroClock.baseline
                  text: root.displayLocale.toString(root.now, ":ss")
                  font.pixelSize: Style.space(root.compactHeight ? 18 : 25)
                  font.features: ({ "tnum": 1 })
                  color: root.secondaryForeground
                }
                ClockLabel {
                  visible: root.preference("timeFormat") === "12-hour"
                  anchors.baseline: heroClock.baseline
                  text: root.displayLocale.toString(root.now, "AP")
                  font.pixelSize: Style.space(root.compactHeight ? 18 : 25)
                  color: root.secondaryForeground
                }
              }

              Column {
                width: parent.width
                spacing: Style.space(5)
                ClockLabel {
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  text: root.displayLocale.toString(root.today, "dddd d. MMMM")
                  font.pixelSize: Style.space(root.compactHeight ? 14 : 18)
                  wrapMode: Text.WordWrap
                }
                ClockLabel {
                  visible: !root.veryShortHeight
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  text: root.localText("Uke ", "Week ")
                    + Model.isoWeek(root.today.getFullYear(), root.today.getMonth(), root.today.getDate())
                    + " · " + root.today.getFullYear()
                  color: root.secondaryForeground
                  font.pixelSize: Style.space(12)
                }
              }
            }

            MouseArea {
              id: heroMouse
              anchors.fill: parent
              enabled: !root.viewingCurrentMonth || !root.selectedDateIsToday
              hoverEnabled: enabled
              cursorShape: Qt.PointingHandCursor
              onClicked: root.goToToday()
              PanelToolTip {
                visible: heroMouse.containsMouse
                text: root.localText("Tilbake til i dag", "Back to today")
                fontFamily: root.contentFontFamily
              }
            }
            ClockAction {
              id: settingsButton
              anchors.top: parent.top
              anchors.right: parent.right
              anchors.topMargin: Style.space(13)
              anchors.rightMargin: Style.space(16)
              implicitWidth: Style.space(32)
              implicitHeight: Style.space(32)
              radius: Style.space(7)
              iconSize: Style.space(16)
              iconName: "settings"
              foreground: root.secondaryForeground
              tooltipText: root.tr("Settings")
              onClicked: root.openSettings()
            }

          }

          Item {
            id: heroBoundary
            width: parent.width
            height: Style.space(10)
          }

          Column {
            id: body
            width: parent.width - Style.space(36)
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(root.veryShortHeight ? 8 : 12)

            // Measure only fixed sections: including the viewport here would
            // create a feedback loop between the popup cap and list height.
            readonly property real fixedHeight: hero.height + heroBoundary.height
              + calendarHeader.implicitHeight + (root.agendaEnabled ? agendaHeading.height + agendaBlock.spacing : 0)
              + footerBlock.implicitHeight + body.spacing * 2

            Column {
              id: calendarHeader
              width: parent.width
              spacing: body.spacing

              Item {
                width: parent.width
                height: Style.space(28)
                ClockLabel {
                  anchors.left: parent.left
                  anchors.right: monthActions.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.displayLocale.toString(root.viewDate, "MMMM yyyy")
                  elide: Text.ElideRight
                }
                Row {
                  id: monthActions
                  anchors.right: parent.right
                  spacing: Style.space(4)
                  PanelActionButton {
                    size: Style.space(27); fontSize: Style.space(22); iconText: "‹"
                    fontFamily: root.contentFontFamily; foreground: root.secondaryForeground
                    tooltipText: root.localText("Forrige måned", "Previous month")
                    onClicked: root.moveMonth(-1)
                  }
                  PanelActionButton {
                    size: Style.space(27); fontSize: Style.space(22); iconText: "›"
                    fontFamily: root.contentFontFamily; foreground: root.secondaryForeground
                    tooltipText: root.localText("Neste måned", "Next month")
                    onClicked: root.moveMonth(1)
                  }
                }
              }

              Item {
                id: calendarPane
                width: parent.width
                height: gridColumn.implicitHeight
                WheelHandler {
                  onWheel: function(event) {
                    if (event.angleDelta.y === 0) return
                    root.moveMonth(event.angleDelta.y > 0 ? -1 : 1)
                  }
                }

                // One continuous muted surface separates weeks without a rule.
                Rectangle {
                  width: root.weekColumnWidth
                  height: parent.height
                  radius: Style.space(6)
                  color: root.weekColumnColor
                }
                Column {
                  id: gridColumn
                  width: parent.width
                  spacing: root.cellSpacing
                  Row {
                    height: Style.space(28)
                    Rectangle {
                      width: root.weekColumnWidth; height: parent.height
                      radius: Style.space(6)
                      color: weekStartMouse.containsMouse ? root.cardColor : "transparent"
                      ClockLabel {
                        anchors.centerIn: parent
                        text: root.localText("Uke", "Week")
                        color: root.weekForeground
                        font.pixelSize: Style.space(11)
                      }
                      MouseArea {
                        id: weekStartMouse
                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: root.toggleWeekStart()
                        PanelToolTip {
                          visible: weekStartMouse.containsMouse
                          text: root.localText("Start uken på ", "Start weeks on ") + root.nextWeekStartLabel
                          fontFamily: root.contentFontFamily
                        }
                      }
                    }
                    Item { width: root.gutterWidth; height: 1 }
                    Row {
                      spacing: root.cellSpacing
                      Repeater {
                        model: root.weekdays
                        ClockLabel {
                          required property int modelData
                          width: root.cellWidth; height: Style.space(28)
                          horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                          text: root.weekdayLabel(modelData)
                          color: root.secondaryForeground
                          font.pixelSize: Style.space(11)
                        }
                      }
                    }
                  }
                  Repeater {
                    model: root.weeks
                    Row {
                      required property var modelData
                      ClockLabel {
                        width: root.weekColumnWidth; height: root.cellHeight
                        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                        text: modelData.week
                        color: root.weekForeground
                        font.pixelSize: Style.space(11)
                      }
                      Item { width: root.gutterWidth; height: 1 }
                      Row {
                        spacing: root.cellSpacing
                        Repeater {
                          model: modelData.days
                          Rectangle {
                            id: dayCell
                            required property var modelData
                            readonly property var events: root.eventsForDate(modelData.key)
                            readonly property var dots: root.calendarDots(events)
                            readonly property int dotCount: dots.length
                            readonly property bool selected: modelData.key === root.selectedDateKey
                            width: root.cellWidth; height: root.cellHeight
                            radius: Style.space(7)
                            color: selected ? root.selectedCardColor : dayMouse.containsMouse ? root.cardColor : "transparent"
                            border.width: modelData.today ? Style.spacing.hairline : 0
                            border.color: Color.accent

                            Item {
                              anchors.bottom: parent.bottom
                              width: parent.width; height: dayCell.radius
                              visible: dayCell.selected
                              clip: true
                              // Weather's inset highlight tapers around the bottom corners.
                              Rectangle {
                                anchors.bottom: parent.bottom
                                width: dayCell.width; height: dayCell.height
                                radius: dayCell.radius; color: Color.accent; antialiasing: true
                                Rectangle {
                                  anchors.fill: parent; anchors.bottomMargin: Style.space(2)
                                  radius: dayCell.radius; color: dayCell.color; antialiasing: true
                                }
                              }
                            }
                            ClockLabel {
                              anchors.centerIn: parent
                              anchors.verticalCenterOffset: -Style.space(2)
                              text: modelData.day
                              color: modelData.inMonth ? root.contentForeground : root.weekForeground
                              font.pixelSize: Style.space(12)
                            }
                            Row {
                              anchors.horizontalCenter: parent.horizontalCenter
                              anchors.bottom: parent.bottom
                              anchors.bottomMargin: Style.space(4)
                              height: Style.space(4)
                              // Preserve one dot per calendar and the compact five-dot limit.
                              spacing: dayCell.dotCount <= 2 ? Style.space(3)
                                : dayCell.dotCount === 3 ? Style.space(1)
                                : dayCell.dotCount === 4 ? -Style.space(1) : -Style.space(2)
                              Repeater {
                                model: dayCell.dots
                                Rectangle {
                                  required property var modelData
                                  width: Style.space(4); height: width; radius: width / 2
                                  color: modelData.color || Color.accent
                                }
                              }
                            }
                            MouseArea {
                              id: dayMouse
                              anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                              onClicked: root.selectDate(modelData.year, modelData.month, modelData.day)
                            }
                            PanelToolTip {
                              visible: dayMouse.containsMouse && dayCell.events.length > 0
                              text: dayCell.events.length + root.localText(dayCell.events.length === 1 ? " avtale" : " avtaler", dayCell.events.length === 1 ? " event" : " events")
                              fontFamily: root.contentFontFamily
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }

            }

            Column {
              id: agendaBlock
              visible: root.agendaEnabled
              width: parent.width
              spacing: Style.space(7)
              Item {
                id: agendaHeading
                width: parent.width; height: Style.space(root.veryShortHeight ? 28 : 36)
                ClockLabel {
                  anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                  text: root.agendaDateLabel
                }
                ClockLabel {
                  anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                  text: root.agendaEvents.length + root.localText(root.agendaEvents.length === 1 ? " avtale" : " avtaler", root.agendaEvents.length === 1 ? " event" : " events")
                  color: root.secondaryForeground; font.pixelSize: Style.space(11)
                }
              }
              Flickable {
                id: agendaScroll
                width: parent.width
                height: Math.min(contentHeight, Math.max(0,
                  (panel.availableCardHeight > 0 ? panel.availableCardHeight : body.fixedHeight + contentHeight)
                  - panel.verticalContentInset - body.fixedHeight))
                contentWidth: width
                contentHeight: agendaContent.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.VerticalFlick
                interactive: contentHeight > height

                // Refreshes and resizes can shorten the list while it is scrolled.
                onContentHeightChanged: contentY = Math.max(0, Math.min(contentY, contentHeight - height))
                onHeightChanged: contentY = Math.max(0, Math.min(contentY, contentHeight - height))

                Controls.ScrollBar.vertical: Controls.ScrollBar {
                  visible: agendaScroll.interactive
                  width: Style.space(4)
                  padding: 0
                  minimumSize: 0.08
                  policy: Controls.ScrollBar.AsNeeded
                  active: agendaScroll.interactive
                  contentItem: Rectangle {
                    implicitWidth: Style.space(4)
                    radius: width / 2
                    color: root.weekForeground
                  }
                  background: Item {}
                }

                Column {
                  id: agendaContent
                  width: parent.width - (agendaScroll.interactive ? Style.space(10) : 0)
                  spacing: agendaBlock.spacing

                  ClockLabel {
                    visible: root.agendaEvents.length === 0
                    width: parent.width
                    topPadding: Style.space(12); bottomPadding: Style.space(12)
                    wrapMode: Text.WordWrap
                    text: root.agendaState === "loading" ? root.localText("Henter avtaler…", "Loading events…")
                      : root.agendaState === "error" ? root.agendaMessageText()
                      : root.selectedCalendars > 0 ? root.localText("Ingen avtaler denne dagen", "No events on this date")
                      : root.localText("Ingen kalendere valgt", "No calendars selected")
                    color: root.agendaState === "error" ? Color.urgent : root.secondaryForeground
                    font.pixelSize: Style.space(12)
                  }
                  Repeater {
                    model: root.agendaEvents
                    Rectangle {
                      id: eventRow
                      required property var modelData
                      readonly property string agendaStatus: root.eventState(modelData)
                      width: parent.width; height: Style.space(60)
                      radius: Style.space(8)
                      color: eventMouse.containsMouse || agendaStatus === "ongoing" ? root.selectedCardColor : root.cardColor
                      Rectangle {
                        anchors.left: parent.left; anchors.leftMargin: Style.space(11)
                        anchors.verticalCenter: parent.verticalCenter
                        width: Style.space(3); height: parent.height - Style.space(22); radius: width / 2
                        color: eventRow.modelData.color || Color.accent
                      }
                      ClockLabel {
                        id: eventTime
                        anchors.left: parent.left; anchors.leftMargin: Style.space(24)
                        anchors.top: parent.top; anchors.topMargin: Style.space(12)
                        width: Style.space(root.preference("timeFormat") === "12-hour" ? 72 : 58)
                        text: eventRow.modelData.allDay ? root.localText("Hele dagen", "All day")
                          : root.displayLocale.toString(new Date(Number(eventRow.modelData.start) * 1000), root.timeFormat)
                        color: root.secondaryForeground; font.pixelSize: Style.space(11)
                        elide: Text.ElideRight
                      }
                      Column {
                        anchors.left: eventTime.right; anchors.leftMargin: Style.space(8)
                        anchors.right: parent.right; anchors.rightMargin: Style.space(11)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(3)
                        ClockLabel {
                          width: parent.width; elide: Text.ElideRight
                          text: eventRow.modelData.title || root.localText("Avtale uten tittel", "Untitled event")
                          color: eventRow.agendaStatus === "past" ? root.secondaryForeground : root.contentForeground
                        }
                        ClockLabel {
                          width: parent.width; elide: Text.ElideRight
                          text: (eventRow.agendaStatus === "ongoing" ? root.localText("Nå · ", "Now · ") : "")
                            + root.eventTimeText(eventRow.modelData) + " · " + root.eventDetails(eventRow.modelData)
                          color: root.secondaryForeground; font.pixelSize: Style.space(11)
                        }
                      }
                      MouseArea {
                        id: eventMouse
                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: root.openCalendar()
                      }
                      PanelToolTip {
                        visible: eventMouse.containsMouse
                        text: (eventRow.modelData.title || root.localText("Avtale uten tittel", "Untitled event"))
                          + "\n" + root.eventTimeText(eventRow.modelData) + " · " + root.eventDetails(eventRow.modelData)
                        fontFamily: root.contentFontFamily
                      }
                    }
                  }
                  ClockLabel {
                    visible: root.agendaState === "partial"
                    width: parent.width; wrapMode: Text.WordWrap
                    text: root.agendaMessageText()
                    color: Color.accent; font.pixelSize: Style.space(12)
                  }
                }
              }
            }

            Column {
              id: footerBlock
              width: parent.width
              spacing: body.spacing
              Rectangle { width: parent.width; height: 1; color: root.outlineColor }
              Item {
                width: parent.width; height: Style.space(28)
                PanelActionButton {
                  id: openCalendarButton
                  anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                  size: Style.space(26); fontSize: Style.space(14)
                  width: calendarButtonContent.implicitWidth + Style.space(12)
                  fontFamily: root.contentFontFamily; foreground: root.secondaryForeground
                  tooltipText: root.localText("Åpne kalender", "Open calendar")
                  onClicked: root.openCalendar()
                  Row {
                    id: calendarButtonContent
                    anchors.centerIn: parent
                    spacing: Style.space(6)
                    ClockLabel {
                      anchors.verticalCenter: parent.verticalCenter
                      text: "󰸗"
                      font.family: root.iconFontFamily; font.pixelSize: Style.space(14)
                      color: root.secondaryForeground
                    }
                    ClockLabel {
                      anchors.verticalCenter: parent.verticalCenter
                      text: root.localText("Kalender", "Calendar")
                      font.pixelSize: Style.space(11)
                      color: root.secondaryForeground
                    }
                  }
                }
                ClockLabel {
                  anchors.left: openCalendarButton.right; anchors.leftMargin: Style.space(12)
                  anchors.right: refreshButton.left; anchors.rightMargin: Style.space(7)
                  anchors.verticalCenter: parent.verticalCenter
                  horizontalAlignment: Text.AlignRight; elide: Text.ElideRight
                  text: root.launchError || (root.agendaEnabled ? root.agendaUpdatedText : "")
                  color: root.secondaryForeground; font.pixelSize: Style.space(11)
                }
                ClockAction {
                  id: refreshButton
                  visible: root.agendaEnabled
                  anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(26); height: Style.space(26)
                  iconSize: Style.space(15)
                  iconName: "refresh-cw"
                  foreground: root.secondaryForeground
                  tooltipText: root.agendaLoading ? root.localText("Oppdaterer kalendere", "Refreshing calendars") : root.localText("Oppdater kalendere", "Refresh calendars")
                  enabled: !root.agendaLoading
                  spinning: root.opened && !root.editingSettings && root.agendaLoading
                  onClicked: root.refreshAgenda(true)
                }
              }
              Item { width: 1; height: Style.space(4) }
            }
          }
        }
      }
    }
  }
}
