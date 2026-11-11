import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "harness"
import "plugin" as Clock
import "plugin/kit" as Kit

// Runtime checks of the real clock widget on a host shell (offscreen):
// three bar instances (three monitors) share one ClockService; nothing
// starts before the first popup open; the popup body is built lazily;
// exactly one IPC target is live; i18n plurals and catalog date patterns;
// the calendar shortcut (fake omarchy-cmd-present and omarchy-launch-or-focus
// from runtime.py, so no real app starts).
ShellRoot {
  id: shell
  readonly property string host: Quickshell.env("FOAMY_HOST")
  readonly property string lang: Quickshell.env("FOAMY_LANG") || "en"
  property int checks: 0
  property int failures: 0
  function check(ok, label) { checks++; if (!ok) { failures++; console.log("FOAMY FAIL " + host + "/" + lang + " " + label) } }
  function eq(actual, expected, label) { check(actual === expected, label + ": got " + JSON.stringify(actual) + ", expected " + JSON.stringify(expected)) }

  FloatingWindow {
    implicitWidth: 1920; implicitHeight: 1080; color: "black"
    Row {
      Repeater {
        id: bars
        model: 3
        Item {
          width: 300; height: 34
          property alias widget: clock
          property alias mockBar: mock
          MockBar { id: mock }
          Clock.BarWidget { id: clock; bar: mock; moduleName: "foamy.clock"; settings: ({ format: "HH:mm", agendaRefreshMinutes: 45 }) }
        }
      }
    }
  }

  // Review round 1: a selection must not cut the dropdown's binding.
  property string boundSetting: "a"
  Kit.FoamyDropdown { id: bound; value: shell.boundSetting; options: ["a", "b", "c"] }

  // Background updates start with the first minute check, never at shell
  // start: count every agenda/cache process that starts before the first open.
  property int startsBeforeOpen: 0
  Connections {
    target: Clock.ClockService.agendaProcess
    function onStarted() { if (!Clock.ClockService.activated) shell.startsBeforeOpen++ }
  }
  Connections {
    target: Clock.ClockService.cacheProcess
    function onStarted() { if (!Clock.ClockService.activated) shell.startsBeforeOpen++ }
  }

  function widget(i) { return bars.itemAt(i).widget }
  function panel(i) { return widget(i).children.filter(c => c.popup !== undefined)[0] }

  Timer {
    interval: 1500; running: true
    onTriggered: {
      var service = Clock.ClockService
      eq(service.activated, false, "service idle before any popup opens")
      eq(service.agendaProcess.running || service.cacheProcess.running, false, "no Evolution or cache process before open")
      eq(shell.startsBeforeOpen, 0, "none started since shell start either")
      // Never-attempted months go nearest first: this month is the one the
      // popup opens on. (QV4's Array.sort is not stable, unlike node's.)
      service.prefetchAttempts = ({})
      service.schedulePrefetch()
      eq(service.agendaProcessRangeStartKey, service.prefetchRanges(new Date())[0].start,
        "the first background prefetch is this month")
      eq(service.clock.enabled, false, "the popup clock does not tick while hidden")
      // Background updates (default on): only the minute-check prefetch timer
      // runs while hidden; its first check is a minute in. Off: nothing runs.
      eq(service.refreshTimer.running, false, "no foreground refresh timer while hidden")
      eq(service.backgroundRefresh && service.prefetchTimer.running, true, "background updates check due months while hidden")
      service.backgroundRefresh = false
      eq(service.prefetchTimer.running, false, "background updates off: no agenda timers while hidden")
      service.backgroundRefresh = true
      eq(service.refreshMinutes, 45, "the leader feeds settings into the shared service")
      for (var i = 0; i < 3; i++) eq(panel(i).popup.bodyItem, null, "no popup body before open on bar " + i)
      eq(widget(0).displayDate instanceof Date, true, "bar label has a date")
      // Escaped icon-font glyphs (pua-literal) still resolve to the same code points.
      eq(widget(0).clockIcon.codePointAt(0), 0xf017, "clock glyph code point")
      eq(widget(0).calendarIcon.codePointAt(0), 0xf0e17, "calendar glyph code point")
      widget(1).open()
      openCheck.start()
    }
  }
  Timer {
    id: openCheck
    interval: 1500
    onTriggered: {
      var service = Clock.ClockService
      eq(widget(1).opened, true, "bar 1 opened")
      eq(service.activated, true, "first open activates the agenda")
      eq(service.demanded, true, "an open popup raises demand")
      eq(service.clock.enabled, true, "the popup clock ticks while open")
      check(panel(1).popup.bodyItem !== null, "bar 1 built its body")
      eq(panel(0).popup.bodyItem, null, "bar 0 still has no body")
      var view = panel(1).popup.bodyItem
      var key = service.selectedDateKey
      view.moveCursor(1)
      check(view.cursorKey !== "" && view.cursorKey !== key, "arrow moves the day cursor, not the selection")
      eq(service.selectedDateKey, key, "selection unchanged until Enter")
      view.activateCursor()
      eq(service.selectedDateKey, view.cursorKey, "Enter selects the cursor day")
      eq(view.agendaCountText !== undefined, true, "count text available")
      // Browsing months, then an arrow: the cursor lands in the shown month.
      view.cursorKey = ""
      service.goToToday()
      var month = service.viewMonth
      service.moveMonth(2)
      view.moveCursor(1)
      eq(service.viewMonth, (month + 2) % 12, "arrow after month browsing keeps the shown month")
      eq(view.cursorKey, service.weeks[0].days.filter(d => d.inMonth)[0].key, "cursor starts on the shown month's first day")
      view.moveCursor(1)
      eq(Number(view.cursorKey.slice(8)), 2, "then moves within the shown month")
      service.goToToday()
      // Dropdown keeps following the setting after a selection (kit sets value on select).
      bound.select("b")
      shell.boundSetting = "c"
      eq(bound.value, "c", "dropdown follows the stored setting after a selection")
      if (lang === "no" && host === "4.5") {
        eq(Clock.ClockService !== null, true, "service")
        check(view.heroDateText.indexOf(".") > 0, "Norwegian hero date uses the catalog pattern: " + view.heroDateText)
        eq(view.updatedAgoText !== undefined, true, "updated text")
      }
      widget(1).close()
      closeCheck.start()
    }
  }
  Timer {
    id: closeCheck
    interval: 600
    onTriggered: {
      var service = Clock.ClockService
      eq(service.demanded, false, "closing drops demand")
      eq(service.clock.enabled, false, "the clock stops again when hidden")
      // Settings save inline through the mock bar (FoamyPrefs).
      widget(0).save("showSeconds", false)
      eq(bars.itemAt(0).mockBar.saved.length, 1, "inline save recorded")
      eq(widget(0).preference("showSeconds"), false, "a saved value reads back at once (FoamyPrefsQueue)")
      widget(0).save("calendarApp", "a;b")
      check(widget(0).settingsError !== "", "invalid value reports an error")
      // A calendar app Omarchy cannot find: an error, nothing launched.
      widget(0).save("calendarApp", "foamy-missing-calendar")
      panel(0).openCalendar()
      launchCheck.start()
    }
  }
  FileView { id: launchedFile; path: Quickshell.env("FOAMY_OUT") + "/launched"; blockLoading: true; printErrors: false }
  function launched() { launchedFile.reload(); return launchedFile.text() }
  function finish() {
    console.log("FOAMY RESULT " + host + "/" + lang + " checks=" + checks + " failures=" + failures)
    console.log(failures === 0 ? "FOAMY DONE" : "FOAMY FAIL total")
    Qt.quit()
  }
  // Polls instead of fixed sleeps: each step waits (10 s at most) for the
  // launch check's own outcome.
  Timer {
    id: launchCheck
    interval: 100; repeat: true
    property int step: 0
    property int ticks: 0
    onTriggered: {
      if (++ticks > 100) { check(false, "calendar launch step " + step + " timed out"); stop(); shell.finish(); return }
      if (step === 0) {
        if (panel(0).launchError === "") return
        check(shell.launched() === "", "missing calendar app: nothing launched")
        widget(0).save("calendarApp", "foamy-test-calendar")
        widget(0).open()
        panel(0).openCalendar()
        step = 1; ticks = 0
        return
      }
      if (shell.launched() === "") return
      eq(shell.launched(), "foamy-test-calendar\n", "calendar app present: launched through omarchy-launch-or-focus")
      eq(widget(0).opened, false, "and the popup closes")
      eq(panel(0).launchError, "", "with no error")
      stop()
      shell.finish()
    }
  }
}
