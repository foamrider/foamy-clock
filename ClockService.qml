pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// The calendar state and the Evolution agenda engine, once per shell.
//
// 4.5 draws one bar per monitor, and each bar builds its own clock widget.
// This plugin-local singleton is shared by all of them, so the bridge and
// worker processes, timers and month cache run once, not once per monitor.
// The leader widget (FoamyMember) feeds it the settings; any widget's popup
// raises demand while it is open.
//
// Nothing here runs until the first popup opens (activate()): the bar shows
// only the time, so Evolution Data Server is never woken just for the bar.
// While no popup is open the clock and the periodic refresh are paused; on
// open, stale data is shown from the cache at once and refreshed behind it.
QtObject {
  id: root

  // ---- Inputs (the leader widget binds these).
  property bool agendaEnabled: true
  property int refreshMinutes: 30
  property int weekStart: 1
  property bool showSeconds: true
  // Some popup is open (FoamyMember demand).
  property bool demanded: false
  // Set by activate() on the first popup open; never cleared.
  property bool activated: false
  readonly property bool agendaActive: activated && agendaEnabled

  // The agenda list scrolls back to the top when its day is replaced.
  signal agendaReset()

  readonly property string helperPath: decodeURIComponent(Qt.resolvedUrl("calendar-events.py").toString().replace(/^file:\/\//, ""))

  // ---- Today and the shown month. SystemClock keeps this honest across
  //      midnight while a popup is open; open() resets it to the real today.
  property date today: new Date()
  readonly property string todayKey: Model.keyForDate(today)
  property date selectedDate: new Date(today.getFullYear(), today.getMonth(), today.getDate())
  readonly property string selectedDateKey: Model.keyForDate(selectedDate)
  readonly property bool selectedDateIsToday: selectedDateKey === todayKey
  property date now: new Date()
  property string timeZoneName: ""

  // Month stepping does not change the selected agenda date until a day is
  // clicked, keeping browsing and selection as separate deliberate actions.
  property int viewYear: today.getFullYear()
  property int viewMonth: today.getMonth()
  readonly property date viewDate: new Date(viewYear, viewMonth, 1)
  readonly property bool viewingCurrentMonth: viewYear === today.getFullYear() && viewMonth === today.getMonth()
  readonly property var weekdays: Model.weekdayOrder(weekStart)
  readonly property var weeks: Model.monthGrid(viewYear, viewMonth, weekStart, todayKey)

  // ---- Agenda. The selected Evolution Data Server calendars are the same
  //      source set GNOME Calendar presents. A private on-disk cache is
  //      loaded first so a slow account never blanks the panel.
  property var agendaEvents: []
  property var calendarDates: ({})
  property var monthView: null
  property var pendingMonth: null
  property int pendingMonthBytes: 0
  property int pendingMonthChunks: 0
  property string agendaState: "loading"
  property string agendaMessage: ""
  property string overviewState: "missing"
  property string agendaDateKey: ""
  property int selectedCalendars: 0
  property double lastAgendaRefreshMs: 0
  property bool agendaCached: false
  property string agendaProcessDateKey: ""
  property string agendaProcessRangeStartKey: ""
  property string agendaProcessRangeEndKey: ""
  property string cacheProcessDateKey: ""
  property string cacheProcessRangeStartKey: ""
  property string cacheProcessRangeEndKey: ""
  property bool agendaRequestCancelled: false
  property bool agendaPrefetch: false
  property bool agendaRefreshPending: false
  property var prefetchAttempts: ({})
  property bool agendaForceRefresh: false
  property bool agendaPayloadApplied: false
  property double lastAgendaRangeRefreshMs: 0
  property string lastAgendaRangeKey: ""
  readonly property int agendaRefreshIntervalMs: Math.max(1, refreshMinutes) * 60000
  readonly property bool agendaLoading: (agendaProcess.running && !agendaPrefetch) || cacheProcess.running
  readonly property date agendaRangeStartDate: new Date(weeks[0].days[0].year, weeks[0].days[0].month, weeks[0].days[0].day)
  readonly property date agendaRangeEndDate: new Date(agendaRangeStartDate.getFullYear(), agendaRangeStartDate.getMonth(), agendaRangeStartDate.getDate() + 42)
  readonly property string agendaRangeStartKey: Model.keyForDate(agendaRangeStartDate)
  readonly property string agendaRangeEndKey: Model.keyForDate(agendaRangeEndDate)
  readonly property string agendaRangeKey: agendaRangeStartKey + ":" + agendaRangeEndKey
  readonly property string prefetchHorizonKey: today.getFullYear() + ":" + today.getMonth() + ":" + weekStart

  onAgendaRangeKeyChanged: {
    root.calendarDates = ({})
    root.monthView = null
    root.pendingMonth = null
    root.overviewState = "missing"
    Qt.callLater(root.requestAgendaDate)
  }
  onPrefetchHorizonKeyChanged: {
    root.prefetchAttempts = ({})
    Qt.callLater(root.schedulePrefetch)
  }
  onAgendaEnabledChanged: {
    // Drop visible data immediately. In-flight results are ignored when disabled.
    root.calendarDates = ({})
    root.monthView = null
    root.pendingMonth = null
    root.overviewState = "missing"
    if (!agendaEnabled && agendaProcess.running) {
      root.agendaRequestCancelled = true
      agendaProcess.signal(15)
    }
    root.resetAgendaView()
    root.lastAgendaRangeRefreshMs = 0
    root.prefetchAttempts = ({})
    root.agendaRefreshPending = false
    if (agendaEnabled) Qt.callLater(root.requestAgendaDate)
  }

  // First popup open: from here on the agenda may query Evolution.
  function activate() {
    if (root.activated) return
    root.activated = true
  }

  // Called on every popup open: today, the zone label and the agenda.
  function refresh() {
    root.activate()
    root.today = new Date()
    root.now = root.today
    if (!timeZoneProcess.running) timeZoneProcess.running = true
    root.goToToday()
  }

  function monthIsCurrent() {
    return root.monthView && root.monthView.date === root.agendaRangeStartKey
      && root.monthView.rangeEnd === root.agendaRangeEndKey
  }

  function showSelectedDay() {
    if (!root.monthIsCurrent()) return false
    return root.showDay(root.monthView, root.selectedDateKey)
  }

  function showDay(month, key) {
    var day = month.dates[key]
    if (!day || day.state === "missing") return false
    root.agendaEvents = day.events.map(index => month.events[index])
    root.agendaState = day.state
    root.agendaDateKey = root.selectedDateKey
    root.selectedCalendars = month.selectedCalendars
    root.lastAgendaRefreshMs = day.updatedAt * 1000
    root.agendaCached = month.cached || day.cached
    return true
  }

  function requestAgendaDate() {
    if (!root.agendaActive) return
    root.showSelectedDay()
    if (cacheProcess.running || agendaProcess.running) {
      if (agendaProcess.running && root.agendaPrefetch) {
        // Loaded day clicks leave background work alone. A new visible month
        // takes priority, including its fast disk read, before more prefetching.
        if (!root.monthIsCurrent()) {
          root.agendaRequestCancelled = true
          agendaProcess.signal(15)
        }
        return
      }
      // Day selection uses the shared month view and never cancels its refresh.
      if (agendaProcess.running && (root.agendaProcessRangeStartKey !== root.agendaRangeStartKey
          || root.agendaProcessRangeEndKey !== root.agendaRangeEndKey)) {
        root.agendaRequestCancelled = true
        agendaProcess.signal(15)
      }
      return
    }
    if (root.monthIsCurrent()) {
      root.refreshAgenda(false)
      return
    }
    root.cacheProcessDateKey = root.selectedDateKey
    root.cacheProcessRangeStartKey = root.agendaRangeStartKey
    root.cacheProcessRangeEndKey = root.agendaRangeEndKey
    cacheProcess.running = true
  }

  function prefetchRanges() {
    var ranges = []
    for (var offset = 0; offset <= 3; offset++) {
      var month = Model.stepMonth(root.today.getFullYear(), root.today.getMonth(), offset)
      var first = Model.monthGrid(month.year, month.month, root.weekStart, "")[0].days[0]
      ranges.push({start: first.key,
        end: Model.keyForDate(new Date(first.year, first.month, first.day + 42))})
    }
    return ranges
  }

  function schedulePrefetch() {
    if (!root.agendaActive || !root.monthIsCurrent()
        || cacheProcess.running || agendaProcess.running) return
    var ranges = root.prefetchRanges()
    var attempts = ({})
    // Keep only four timestamps. Completed failures also get a cooldown;
    // an unavailable account must not create an immediate retry loop.
    for (var range of ranges) {
      var key = range.start + ":" + range.end
      attempts[key] = root.prefetchAttempts[key] || 0
    }
    root.prefetchAttempts = attempts
    // Serve never-attempted and oldest months first. Short refresh intervals
    // must not let the nearest month repeatedly starve the farther months.
    ranges.sort((a, b) => attempts[a.start + ":" + a.end] - attempts[b.start + ":" + b.end])
    for (var range of ranges) {
      var key = range.start + ":" + range.end
      if (key === root.agendaRangeKey) continue
      if (Date.now() - attempts[key] < root.agendaRefreshIntervalMs) continue
      root.agendaPrefetch = true
      root.agendaRequestCancelled = false
      root.agendaForceRefresh = false
      root.agendaProcessDateKey = range.start
      root.agendaProcessRangeStartKey = range.start
      root.agendaProcessRangeEndKey = range.end
      agendaProcess.running = true
      return
    }
  }

  function finishPrefetch() {
    var key = root.agendaProcessRangeStartKey + ":" + root.agendaProcessRangeEndKey
    if (!root.agendaRequestCancelled && root.prefetchRanges().some(range => range.start + ":" + range.end === key)) {
      var attempts = root.prefetchAttempts
      attempts[key] = Date.now()
      root.prefetchAttempts = attempts
    }
    root.agendaRequestCancelled = false
    root.agendaPrefetch = false
    // Serialize disk readers/writers and workers through the same request
    // path. A foreground request interrupted this job, so satisfy it first.
    Qt.callLater(root.requestAgendaDate)
  }

  function resetAgendaView() {
    root.agendaReset()
    root.agendaEvents = []
    root.agendaState = "loading"
    root.agendaMessage = ""
    root.agendaDateKey = ""
    root.lastAgendaRefreshMs = 0
    root.agendaCached = false
  }

  function refreshAgenda(force) {
    if (!root.agendaActive) return
    if (agendaProcess.running || cacheProcess.running) {
      if (force && root.agendaPrefetch && agendaProcess.running) {
        root.agendaRefreshPending = true
        root.agendaRequestCancelled = true
        agendaProcess.signal(15)
      }
      return
    }
    force = force || root.agendaRefreshPending
    if (!force) {
      // A fresh disk view avoids Exchange entirely. A recent failed attempt
      // also gets a cooldown, rather than retrying on every day click.
      var updated = root.monthIsCurrent() && root.monthView.state === "ok"
        ? root.monthView.updatedAt * 1000 : 0
      var attempted = root.lastAgendaRangeKey === root.agendaRangeKey
        ? root.lastAgendaRangeRefreshMs : 0
      if (Date.now() - Math.max(updated, attempted) < root.agendaRefreshIntervalMs) {
        root.schedulePrefetch()
        return
      }
    }
    root.agendaRefreshPending = false
    root.agendaPrefetch = false
    root.agendaRequestCancelled = false
    root.agendaForceRefresh = force
    root.agendaPayloadApplied = false
    root.pendingMonth = null
    root.agendaProcessDateKey = root.selectedDateKey
    root.agendaProcessRangeStartKey = root.agendaRangeStartKey
    root.agendaProcessRangeEndKey = root.agendaRangeEndKey
    if (root.agendaEvents.length === 0 && root.lastAgendaRefreshMs <= 0) root.agendaState = "loading"
    agendaProcess.running = true
  }

  function applyAgendaPayload(raw, fromCache, expectedDateKey, rangeStart, rangeEnd) {
    if (!root.agendaEnabled || rangeStart !== root.agendaRangeStartKey
        || rangeEnd !== root.agendaRangeEndKey) return false
    try {
      // The bridge bounds each line before Qt reads it. Bound the assembled
      // transaction too, and retain the previous view until the commit marker.
      if (String(raw).length > 262144) throw new Error("oversized calendar line")
      var payload = JSON.parse(String(raw || ""))
      if (!payload || payload.date !== rangeStart || payload.rangeEnd !== rangeEnd) return false
      if (payload.kind === "month-start") {
        if (!payload.dates || Object.keys(payload.dates).length !== 42
            || ["ok", "partial", "error", "missing"].indexOf(payload.state) < 0) return false
        root.pendingMonth = payload
        root.pendingMonth.events = []
        root.pendingMonth.cached = fromCache || payload.cached
        root.pendingMonthBytes = String(raw).length
        root.pendingMonthChunks = 0
        return false
      }
      if (!root.pendingMonth) return false
      root.pendingMonthBytes += String(raw).length
      if (root.pendingMonthBytes > 2162688) throw new Error("oversized calendar month")
      if (payload.kind === "month-events") {
        root.pendingMonthChunks++
        if (!Array.isArray(payload.events) || payload.events.length > 100
            || root.pendingMonthChunks > 10
            || root.pendingMonth.events.length + payload.events.length > 1000)
          throw new Error("too many calendar events")
        root.pendingMonth.events = root.pendingMonth.events.concat(payload.events)
        return false
      }
      if (payload.kind !== "month-end") throw new Error("invalid calendar message")
      var month = root.pendingMonth
      root.pendingMonth = null
      if (month.state === "missing") return false
      var dates = ({})
      for (var key of Object.keys(month.dates)) {
        var day = month.dates[key]
        if (!day || !Array.isArray(day.events) || day.events.length > 100
            || ["ok", "partial", "error", "missing"].indexOf(day.state) < 0)
          throw new Error("invalid calendar date")
        var seen = new Set()
        var dots = []
        for (var index of day.events) {
          if (!Number.isInteger(index) || index < 0 || index >= month.events.length)
            throw new Error("invalid calendar reference")
          var event = month.events[index]
          var id = String(event.id).split(":")[0]
          if (!seen.has(id) && dots.length < 5) {
            seen.add(id)
            dots.push({id: id, color: event.color})
          }
        }
        dates[key] = dots
      }
      root.monthView = month
      root.calendarDates = dates
      root.overviewState = month.state
      root.showSelectedDay()
      return true
    } catch (error) {
      root.pendingMonth = null
      return false
    }
  }

  function dotsForDate(key) {
    var dots = root.calendarDates[key]
    return Array.isArray(dots) ? dots : []
  }

  function dateIsIncomplete(key) {
    var day = root.monthIsCurrent() ? root.monthView.dates[key] : null
    return !day || day.state !== "ok"
  }

  function goToToday() {
    root.viewYear = today.getFullYear()
    root.viewMonth = today.getMonth()
    if (!root.selectedDateIsToday) {
      root.selectDate(today.getFullYear(), today.getMonth(), today.getDate())
      return
    }
    // Reads the disk cache first when this month is not loaded yet.
    root.requestAgendaDate()
  }

  function selectDate(year, month, day) {
    var nextDate = new Date(year, month, day)
    var nextKey = Model.keyForDate(nextDate)
    // The adjacent dates are cached too. Preserve their ready agenda when
    // selecting one also changes the visible month and starts a new preload.
    var cachedMonth = root.monthView
    root.viewYear = nextDate.getFullYear()
    root.viewMonth = nextDate.getMonth()
    if (nextKey === root.selectedDateKey) return

    root.selectedDate = nextDate
    // A previous date may still be loading. Clear it immediately so its rows
    // are never presented under the newly selected date heading.
    root.resetAgendaView()
    if (cachedMonth) root.showDay(cachedMonth, nextKey)
    root.requestAgendaDate()
  }

  function moveMonth(delta) {
    var next = Model.stepMonth(viewYear, viewMonth, delta)
    root.viewYear = next.year
    root.viewMonth = next.month
  }

  function moveYear(delta) {
    moveMonth(delta * 12)
  }

  // Resolve the system's IANA zone when opened, including timezone changes
  // made from the bar. A non-zoneinfo localtime file uses Qt's zone label.
  property Process timeZoneProcess: Process {
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

  // Ticks only while a popup is open: seconds when the popup shows them,
  // else minutes (for "Updated N minutes ago", ongoing events and midnight).
  property SystemClock clock: SystemClock {
    enabled: root.demanded
    precision: root.showSeconds ? SystemClock.Seconds : SystemClock.Minutes
    onDateChanged: {
      if (!root.demanded) return
      root.now = date
      if (Model.keyForDate(date) === String(root.todayKey)) return
      var followToday = root.viewingCurrentMonth
      var selectedToday = root.selectedDateIsToday
      root.today = date
      if (followToday) root.goToToday()
      if (selectedToday && !followToday)
        root.selectDate(date.getFullYear(), date.getMonth(), date.getDate())
    }
  }

  property Process cacheProcess: Process {
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
      root.cacheProcessDateKey,
      "--range-start", root.cacheProcessRangeStartKey,
      "--range-end", root.cacheProcessRangeEndKey
    ]
    stdout: SplitParser {
      onRead: data => {
        root.applyAgendaPayload(data, true, root.cacheProcessDateKey,
          root.cacheProcessRangeStartKey, root.cacheProcessRangeEndKey)
      }
    }
    onExited: Qt.callLater(function() {
      if (!root.agendaActive) return
      if (root.cacheProcessRangeStartKey !== root.agendaRangeStartKey
          || root.cacheProcessRangeEndKey !== root.agendaRangeEndKey) root.requestAgendaDate()
      else {
        root.refreshAgenda(false)
      }
    })
  }

  property Process agendaProcess: Process {
    command: [
      "timeout",
      // One month worker has a 45-second deadline; also bound the bridge.
      "55s",
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
      root.agendaProcessRangeEndKey,
      "--max-age", String(root.agendaForceRefresh ? 0 : root.agendaRefreshIntervalMs / 1000)
    ].concat(root.agendaPrefetch ? ["--cache-only"] : [])
    stdout: SplitParser {
      onRead: data => {
        if (root.agendaPrefetch) return
        if (root.applyAgendaPayload(data, false, root.agendaProcessDateKey,
            root.agendaProcessRangeStartKey, root.agendaProcessRangeEndKey)) root.agendaPayloadApplied = true
      }
    }
    onExited: function(exitCode) {
      if (root.agendaPrefetch) {
        if (root.agendaActive) root.finishPrefetch()
        else root.agendaPrefetch = false
        return
      }
      if (!root.agendaActive) return
      var completedRangeKey = root.agendaProcessRangeStartKey + ":" + root.agendaProcessRangeEndKey
      root.pendingMonth = null
      if (root.agendaRequestCancelled || completedRangeKey !== root.agendaRangeKey) {
        root.agendaRequestCancelled = false
        Qt.callLater(root.requestAgendaDate)
        return
      }
      root.lastAgendaRangeKey = completedRangeKey
      root.lastAgendaRangeRefreshMs = Date.now()
      if (!root.agendaPayloadApplied) {
        root.overviewState = "partial"
        root.agendaState = root.lastAgendaRefreshMs > 0 ? "partial" : "error"
      }
      Qt.callLater(root.schedulePrefetch)
    }
  }

  // Both timers run only while a popup is open; reopening refreshes anyway.
  property Timer prefetchTimer: Timer {
    // Check due times cheaply; event fetching still uses the configured
    // refresh interval and only one bounded month worker at a time.
    interval: 60000
    repeat: true
    running: root.agendaActive && root.demanded
    onTriggered: root.schedulePrefetch()
  }

  property Timer refreshTimer: Timer {
    interval: root.agendaRefreshIntervalMs
    repeat: true
    running: root.agendaActive && root.demanded
    // Only explicit user refreshes interrupt prefetch. A periodic tick waits
    // for the active worker, then finishPrefetch checks visible freshness.
    onTriggered: root.refreshAgenda(false)
  }
}
