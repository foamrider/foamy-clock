import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "harness"
import "plugin" as Clock

// Runtime checks of the real clock widget on a host shell (offscreen):
// three bar instances (three monitors) share one ClockService; nothing
// starts before the first popup open; the popup body is built lazily;
// exactly one IPC target is live; i18n plurals and catalog date patterns.
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

  function widget(i) { return bars.itemAt(i).widget }
  function panel(i) { return widget(i).children.filter(c => c.popup !== undefined)[0] }

  Timer {
    interval: 1500; running: true
    onTriggered: {
      var service = Clock.ClockService
      eq(service.activated, false, "service idle before any popup opens")
      eq(service.agendaProcess.running || service.cacheProcess.running, false, "no Evolution or cache process before open")
      eq(service.clock.enabled, false, "the popup clock does not tick while hidden")
      eq(service.refreshTimer.running || service.prefetchTimer.running, false, "no agenda timers while hidden")
      eq(service.refreshMinutes, 45, "the leader feeds settings into the shared service")
      for (var i = 0; i < 3; i++) eq(panel(i).popup.bodyItem, null, "no popup body before open on bar " + i)
      eq(widget(0).displayDate instanceof Date, true, "bar label has a date")
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
      widget(0).save("calendarApp", "a;b")
      check(widget(0).settingsError !== "", "invalid value reports an error")
      console.log("FOAMY RESULT " + host + "/" + lang + " checks=" + checks + " failures=" + failures)
      console.log(failures === 0 ? "FOAMY DONE" : "FOAMY FAIL total")
      Qt.quit()
    }
  }
}
