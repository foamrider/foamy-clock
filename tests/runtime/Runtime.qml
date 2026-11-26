import QtQuick
import QtTest
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "harness"
import "plugin" as Clock
import "plugin/kit" as Kit
import "plugin/kit/FoamyIpcResolver.js" as IpcResolver

// Runtime checks of the real clock widget on a host shell (offscreen). Three
// bar instances (three monitors) share one ClockService. The real helper
// runs on a cache runtime.py seeded with today's month; every Evolution
// worker fails (fake gi). In order:
//  1. nothing starts before the first popup open; timers and lazy bodies;
//  2. the bar label (format, ISO week, clock glyph split, vertical lines);
//  3. a click opens bar 1 on the saved events (order, count, ongoing event,
//     details shown as plain text, one dot, footer, no Evolution request);
//     a long event's tooltip wraps in its capped box;
//  4. a key on an empty day selects it without a helper run;
//  5. month browsing and arrows (the cursor stays in the shown month), and a
//     month Evolution cannot serve shows an error;
//  6. a manual refresh with Evolution unreachable keeps the events as partial;
//  7. a click closes bar 1; an inline save keeps the other settings;
//  8. one IPC handler for three bars and each of its functions; the bar
//     button's right and middle clicks;
//  9. the settings page: a refused calendar app typed into its field, a
//     refused custom date locale, the bar format previews, the refresh
//     dropdown saves and follows the setting, a refused pick in each
//     dropdown gives way to the saved value at once, the agenda switch, an
//     invalid value, Esc;
// 10. the calendar shortcut: a hostile stored name, a missing app, a present
//     app (fake omarchy-cmd-present and omarchy-launch-or-focus);
// 11. every helper run's arguments were accepted, and the first background
//     prefetch is this month.
ShellRoot {
  id: shell
  readonly property string host: Quickshell.env("FOAMY_HOST")
  readonly property string lang: Quickshell.env("FOAMY_LANG") || "en"
  property int checks: 0
  property int failures: 0
  function check(ok, label) {
    checks++
    if (!ok) {
      failures++
      console.log("FOAMY FAIL " + host + "/" + lang + " " + label)
    }
  }
  function eq(actual, expected, label) {
    check(actual === expected, label + ": got " + JSON.stringify(actual) + ", expected " + JSON.stringify(expected))
  }
  function same(actual, expected, label) {
    eq(JSON.stringify(actual), JSON.stringify(expected), label)
  }

  // The catalogs' words, written out so a wrong catalog entry fails.
  readonly property var texts: lang === "no" ? ({
      two: "2 avtaler",
      none: "0 avtaler",
      twoShown: "2 vist",
      empty: "Ingen avtaler denne dagen",
      updated: "Oppdatert ",
      partial: "Delvis oppdatert · åpne kalender",
      unavailable: "Kalender utilgjengelig",
      noData: "Kalenderdata er utilgjengelige",
      notAllowed: "Den verdien er ikke tillatt.",
      noEntry: "Innstillingene kan ikke lagres: modulen har ingen oppføring i linjen.",
      pasteFailed: "Kunne ikke lime inn fra utklippstavlen. Kopier ren tekst og prøv igjen.",
      launchFailed: "Kalenderappen kunne ikke startes."
    }) : ({
      two: "2 events",
      none: "0 events",
      twoShown: "2 shown",
      empty: "No events on this date",
      updated: "Updated ",
      partial: "Partial update · open calendar",
      unavailable: "Calendar unavailable",
      noData: "Calendar data is unavailable",
      notAllowed: "That value isn't allowed.",
      noEntry: "Settings can't be saved: this widget has no bar entry.",
      pasteFailed: "Could not paste clipboard text. Copy plain text and try again.",
      launchFailed: "Calendar app could not be started."
    })

  readonly property var barSettings: ({
      format: "HH:mm",
      agendaRefreshMinutes: 45
    })

  FloatingWindow {
    implicitWidth: 1920
    implicitHeight: 1080
    color: "black"
    Row {
      Repeater {
        id: bars
        model: 3
        Item {
          width: 300
          height: 34
          property alias widget: clock
          property alias mockBar: mock
          MockBar {
            id: mock
            property var ran: []
            function run(command) {
              ran = ran.concat([command])
            }
            // The host's BarWidget.broadcast reaches every bar through this.
            function moduleWidgets(id) {
              return [0, 1, 2].map(i => bars.itemAt(i).widget)
            }
          }
          Clock.BarWidget {
            id: clock
            bar: mock
            moduleName: "foamy.clock"
            settings: shell.barSettings
          }
        }
      }
    }
  }

  // The settings page alone, for the checks that need the keyboard focus.
  FloatingWindow {
    id: focusWindow
    visible: false
    implicitWidth: 420
    implicitHeight: 900
    color: "black"
    Clock.SettingsPane {
      id: focusPage
      property var saves: []
      anchors.fill: parent
      settings: ({
          calendarApp: "foamy-test-calendar",
          locale: "de_DE"
        })
      onSave: function (key, value) {
        saves = saves.concat([[key, value]])
      }
    }
    // Real key and mouse events, through the window they are sent to.
    Item {
      TestEvent {
        id: ev
      }
    }
  }

  // The agenda alone, for the checks that hover it: offscreen the bar popup
  // gets no window, so its tooltips never open. A screen wide, as the
  // panel's own window is.
  FloatingWindow {
    id: agendaWindow
    visible: false
    implicitWidth: 1600
    implicitHeight: 1000
    color: "black"
    Loader {
      id: agendaView
      active: false
      sourceComponent: Component {
        Clock.ClockView {
          settings: shell.barSettings
          opened: true
        }
      }
    }
  }

  // Every helper run, from its argv (the boundary with calendar-events.py),
  // and how it ended. One run of each process at a time, so exit i is start i.
  property int startsBeforeOpen: 0
  property var agendaStarts: []
  property var agendaExits: []
  property var cacheStarts: []
  property var cacheExits: []
  Connections {
    target: Clock.ClockService.agendaProcess
    function onStarted() {
      if (!Clock.ClockService.activated)
        shell.startsBeforeOpen++
      shell.agendaStarts = shell.agendaStarts.concat([Array.prototype.slice.call(Clock.ClockService.agendaProcess.command)])
    }
    function onExited(exitCode, exitStatus) {
      shell.agendaExits = shell.agendaExits.concat([
        {
          code: exitCode,
          status: exitStatus
        }
      ])
    }
  }
  Connections {
    target: Clock.ClockService.cacheProcess
    function onStarted() {
      if (!Clock.ClockService.activated)
        shell.startsBeforeOpen++
      shell.cacheStarts = shell.cacheStarts.concat([Array.prototype.slice.call(Clock.ClockService.cacheProcess.command)])
    }
    function onExited(exitCode, exitStatus) {
      shell.cacheExits = shell.cacheExits.concat([
        {
          code: exitCode,
          status: exitStatus
        }
      ])
    }
  }
  function prefetch(argv) {
    return argv.indexOf("--cache-only") >= 0
  }
  function forced(argv) {
    return argv[argv.indexOf("--max-age") + 1] === "0"
  }
  function foregroundStarts() {
    return agendaStarts.filter(argv => !prefetch(argv))
  }

  function widget(i) {
    return bars.itemAt(i).widget
  }
  function panel(i) {
    return widget(i).children.filter(c => c.popup !== undefined)[0]
  }
  function findAll(item, test, found) {
    found = found || []
    if (!item)
      return found
    var hit = false
    try {
      hit = test(item)
    } catch (error) {
      hit = false
    }
    if (hit)
      found.push(item)
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++)
      findAll(kids[i], test, found)
    return found
  }
  function find(item, test) {
    return findAll(item, test)[0] || null
  }
  // The texts of the day cells' tooltips. A ToolTip is a popup, not a child
  // item, so it is found in its cell's data.
  function dayToolTipTexts(view) {
    return findAll(view, it => it.dotCount !== undefined && it.modelData !== undefined).map(function (cell) {
      var tip = Array.prototype.filter.call(cell.data, d => d.delay !== undefined && typeof d.text === "string")[0]
      return tip ? tip.text : null
    })
  }
  // The host WidgetButton in a bar widget.
  function button(i) {
    return find(widget(i), it => it !== widget(i) && it.pressable !== undefined && it.heldButtons !== undefined)
  }
  // The kit FoamyPanelFooter and the agenda list of a popup body.
  function footer(view) {
    return find(view, it => it.showRefresh !== undefined && it.statusClickable !== undefined)
  }
  function agendaList(view) {
    return find(view, it => it.headerItem !== undefined && it.headerItem !== null && typeof it.headerItem.text === "string")
  }
  function openCalendarButton(view) {
    return find(view, it => it.iconName !== undefined && it.tooltipText === Kit.FoamyI18n.t("Open calendar"))
  }
  function ipc(method) {
    return IpcResolver.call(shell, "foamy.clock", method, [])
  }

  FileView {
    id: launchedFile
    path: Quickshell.env("FOAMY_OUT") + "/launched"
    blockLoading: true
    printErrors: false
  }
  function launched() {
    launchedFile.reload()
    return launchedFile.text()
  }
  FileView {
    id: presentFile
    path: Quickshell.env("FOAMY_OUT") + "/present"
    blockLoading: true
    printErrors: false
  }
  // The names omarchy-cmd-present was asked about, in order. Read once, at
  // the end: a FileView that has read a file returns that text again after
  // the file grows.
  function presentChecks() {
    presentFile.reload()
    return presentFile.text().split("\n").filter(line => line !== "")
  }

  // Each step waits for its own condition (10 s at most) instead of a fixed
  // delay, so a loaded machine slows the test down instead of failing it.
  FoamyWait {
    id: wait
  }
  function step(condition, label, then) {
    wait.waitFor(condition, 10000, function (ok) {
      check(ok, label)
      if (ok)
        then()
      else
        shell.finish()
    })
  }
  function finish() {
    console.log("FOAMY RESULT " + host + "/" + lang + " checks=" + checks + " failures=" + failures)
    console.log(failures === 0 ? "FOAMY DONE" : "FOAMY FAIL total")
    Qt.quit()
  }

  // 1. Start: the three bars and the leader's settings are in. The absence of
  // early processes is then watched over a fixed window, because the bug it
  // guards against started a worker during shell start, not on any event.
  Component.onCompleted: step(function () {
    return bars.count === 3 && bars.itemAt(2) !== null && Clock.ClockService.refreshMinutes === 45
  }, "the bars and the leader's settings load", function () {
    wait.after(1500, startCheck)
  })
  function startCheck() {
    var service = Clock.ClockService
    eq(service.activated, false, "service idle before any popup opens")
    eq(service.agendaProcess.running || service.cacheProcess.running, false, "no Evolution or cache process before open")
    eq(shell.startsBeforeOpen, 0, "none started since shell start either")
    // The background horizon starts with the range the popup asks for.
    var first = service.prefetchRanges(new Date())[0]
    eq(first.start + ":" + first.end, service.agendaRangeKey, "the first prefetch range is the shown month's range")
    eq(service.clock.enabled, false, "the popup clock does not tick while hidden")
    // Background updates (default on): only the minute-check prefetch timer
    // runs while hidden; its first check is a minute in. Off: nothing runs.
    eq(service.refreshTimer.running, false, "no foreground refresh timer while hidden")
    eq(service.backgroundRefresh && service.prefetchTimer.running, true, "background updates check due months while hidden")
    service.backgroundRefresh = false
    eq(service.prefetchTimer.running, false, "background updates off: no agenda timers while hidden")
    service.backgroundRefresh = true
    for (var i = 0; i < 3; i++)
      eq(panel(i).popup.bodyItem, null, "no popup body before open on bar " + i)
    barLabelCheck()
    button(1).pressed(Qt.LeftButton)
    step(function () {
      return widget(1).opened && panel(1).popup.bodyItem !== null && service.agendaEvents.length === 2 && !service.agendaLoading
    }, "a click opens bar 1 on the saved events", populatedCheck)
  }

  // 2. The bar label of a non-leader bar, in one function so no tick comes between.
  function barLabelCheck() {
    var label = widget(2)
    var mock = bars.itemAt(2).mockBar
    label.displayDate = new Date(2021, 0, 1, 9, 5)
    label.settings = ({
        format: "yyyy 'W'ww '\u{f017}' HH:mm"
      })
    eq(label.dateText, "2021 W53", "the bar shows the format's date part with the ISO week")
    eq(label.timeText, "09:05", "and the time after the clock glyph")
    label.settings = ({})
    eq(label.timeText, "09:05", "the default format splits at the clock glyph")
    check(label.dateText !== "" && label.dateText.indexOf("\u{f017}") < 0, "and shows a date before it: " + label.dateText)
    mock.position = "left"
    same(label.verticalLines, ["09", "—", "05"], "a vertical bar stacks the default vertical format")
    mock.position = "top"
    label.settings = Qt.binding(() => shell.barSettings)
  }

  // 3. The populated agenda, through the helper, the parser and the view.
  function populatedCheck() {
    var service = Clock.ClockService
    var view = panel(1).popup.bodyItem
    eq(service.activated, true, "first open activates the agenda")
    eq(service.demanded, true, "an open popup raises demand")
    eq(service.clock.enabled, true, "the popup clock ticks while open")
    eq(panel(0).popup.bodyItem, null, "bar 0 still has no body")
    eq(service.agendaState, "ok", "the saved month is ok")
    var events = service.agendaEvents
    same(events.map(e => e.title), ["Offsite", "Standup"], "all-day events come first")
    eq(view.agendaCountText(), texts.two, "the count")
    eq(view.eventState(events[1]), "ongoing", "a running event is ongoing")
    eq(view.eventDetails(events[1]), "Work  ·  <b>Room 4</b>", "calendar and location, the markup kept as text")
    eq(service.dotsForDate(service.todayKey).length, 1, "one dot for one calendar")
    check(footer(view).status.indexOf(texts.updated) === 0, "the footer says when it was updated: " + footer(view).status)
    eq(foregroundStarts().length, 0, "a fresh saved month asks Evolution for nothing")
    if (lang === "no")
      check(view.heroDateText.indexOf(".") > 0, "Norwegian hero date uses the catalog pattern: " + view.heroDateText)
    // Invitations are other people's text: no delegate may read it as markup.
    // Offscreen the popup is never drawn, so the list builds the rows past
    // the first only when asked to lay out.
    var list = agendaList(view)
    list.forceLayout()
    var marked = findAll(list.contentItem, it => typeof it.text === "string" && it.textFormat !== undefined && it.text.indexOf("<b>") >= 0)
    check(marked.length > 0, "the agenda rows show the location")
    for (var i = 0; i < marked.length; i++)
      eq(marked[i].textFormat, Text.PlainText, "agenda text is plain text: " + marked[i].text)
    // The open starts prefetches of the months ahead; once they end, a day
    // click has nothing to wait for and must start nothing.
    step(function () {
      return !service.agendaProcess.running && !service.cacheProcess.running
    }, "the prefetch of the months ahead ends", tooltipCheck)
  }

  // A long title and a meeting link as the location (runtime.py seeds them
  // two days from today, in this month): hovered in the agenda's own window,
  // the event's tooltip wraps them in its 320 px box instead of growing as
  // wide as its text.
  function toolTipOf(item) {
    return Array.prototype.filter.call(item.data, d => d.delay !== undefined && typeof d.text === "string")[0] || null
  }
  function tooltipCheck() {
    var service = Clock.ClockService
    agendaWindow.visible = true
    agendaView.active = true
    step(function () {
      return agendaView.item !== null && agendaView.item.Window.window !== null
    }, "the agenda has a window of its own", function () {
      var view = agendaView.item
      view.moveRequested(service.today.getDate() > 2 ? -2 : 2, 0)
      view.activateRequested()
      var row = function () {
        var list = agendaList(view)
        list.forceLayout()
        return service.agendaEvents.length === 1 ? find(list.contentItem, it => it.agendaStatus !== undefined && it.modelData.title === service.agendaEvents[0].title) : null
      }
      step(function () {
        if (row() === null)
          return false
        // Sent again while waiting: a move before the row is laid out is lost.
        ev.mouseMove(row(), 20, 20, -1, Qt.NoButton, Qt.NoModifier)
        var tip = toolTipOf(row())
        return tip !== null && tip.opened
      }, "hovering the long event opens its tooltip", function () {
        var tip = toolTipOf(row())
        var cap = Style.space(320)
        var title = service.agendaEvents[0].title
        var inside = function () {
          var text = tip.contentItem
          return tip.width <= cap + 0.5 && text.contentWidth + text.leftPadding + text.rightPadding <= tip.width + 0.5
        }
        wait.waitFor(inside, 2000, function (ok) {
          check(tip.implicitContentWidth > cap, "the long event's text is wider than the cap: " + tip.implicitContentWidth)
          check(ok, "the tooltip wraps the long title and link inside its " + cap + " px box: " + tip.width + " px wide, " + tip.contentItem.contentWidth + " px of text")
          eq(String(tip.text).split("\n")[0], title, "the tooltip shows the whole title")
          ev.mouseMove(view, 5, 5, -1, Qt.NoButton, Qt.NoModifier)
          view.textKey("t", 0)
          agendaView.active = false
          agendaWindow.visible = false
          step(function () {
            return service.selectedDateIsToday && service.agendaEvents.length === 2 && !service.agendaLoading
          }, "back to today shows the saved events again", emptyDayCheck)
        })
      })
    })
  }

  // 4. A key moves the cursor; Enter selects an empty day of the loaded month.
  function emptyDayCheck() {
    var service = Clock.ClockService
    var view = panel(1).popup.bodyItem
    var today = service.today
    var lastDay = new Date(today.getFullYear(), today.getMonth() + 1, 0).getDate() === today.getDate()
    var key = service.selectedDateKey
    view.moveRequested(lastDay ? -1 : 1, 0)
    check(view.cursorKey !== "" && view.cursorKey !== key, "an arrow moves the day cursor")
    eq(service.selectedDateKey, key, "selection unchanged until Enter")
    view.activateRequested()
    eq(service.selectedDateKey, view.cursorKey, "Enter selects the cursor day")
    eq(service.agendaEvents.length, 0, "the next day has no events")
    eq(service.agendaState, "ok", "and is loaded")
    eq(view.agendaCountText(), texts.none, "the empty day's count")
    eq(agendaList(view).headerItem.text, texts.empty, "the empty day's message")
    // running turns true in the same call that starts a helper; the started
    // signal only arrives later, so the start lists cannot show it here.
    eq(service.cacheProcess.running || service.agendaProcess.running, false, "a loaded day starts no helper")
    browseCheck()
  }

  // 5. Browsing months, then arrows: the cursor lands in the shown month.
  function browseCheck() {
    var service = Clock.ClockService
    var view = panel(1).popup.bodyItem
    view.textKey("t", 0)
    var month = service.viewMonth
    view.textKey("]", 0)
    view.textKey("]", 0)
    view.moveRequested(1, 0)
    eq(service.viewMonth, (month + 2) % 12, "an arrow after month browsing keeps the shown month")
    eq(view.cursorKey, service.weeks[0].days.filter(d => d.inMonth)[0].key, "the cursor starts on the shown month's first day")
    view.moveRequested(1, 0)
    eq(Number(view.cursorKey.slice(8)), 2, "then moves within the shown month")
    view.moveRequested(0, 1)
    eq(Number(view.cursorKey.slice(8)), 9, "down moves a week")
    view.activateRequested()
    step(function () {
      return service.agendaState === "error" && !service.agendaLoading
    }, "a month Evolution cannot serve shows an error", errorCheck)
  }
  function errorCheck() {
    var service = Clock.ClockService
    var view = panel(1).popup.bodyItem
    eq(footer(view).status, texts.unavailable, "the footer says the calendar is unavailable")
    eq(view.agendaMessageText(), texts.noData, "the agenda says so too")
    eq(view.agendaCountText(), "", "no count for an error")
    check(!!service.monthIsCurrent(), "the helper's error month was committed")
    view.textKey("t", 0)
    step(function () {
      return service.agendaEvents.length === 2 && service.agendaState === "ok" && !service.agendaLoading
    }, "back to today reads the saved month again", refreshCheck)
  }

  // 6. A manual refresh with Evolution unreachable.
  function refreshCheck() {
    var service = Clock.ClockService
    var view = panel(1).popup.bodyItem
    var before = agendaStarts.length
    view.textKey("r", 0)
    step(function () {
      return !service.agendaLoading && service.agendaState === "partial"
    }, "a failed manual refresh ends partial", function () {
      eq(service.agendaEvents.length, 2, "a failed refresh loses no event")
      eq(footer(view).status, texts.partial, "the footer says partial")
      eq(footer(view).statusClickable, true, "and offers the calendar app")
      eq(view.agendaCountText(), texts.twoShown, "the partial count")
      eq(service.dateIsIncomplete(service.selectedDateKey), true, "the day is marked incomplete")
      var runs = agendaStarts.slice(before).filter(argv => !prefetch(argv))
      eq(runs.length, 1, "one foreground run for the refresh")
      check(runs.length === 1 && forced(runs[0]), "and it is forced: " + JSON.stringify(runs))
      button(1).pressed(Qt.LeftButton)
      step(function () {
        return !service.demanded
      }, "a second click closes bar 1 and drops demand", closeCheck)
    })
  }

  // 7. Closed again; an inline save hands the bar the whole entry.
  function closeCheck() {
    var service = Clock.ClockService
    var mock = bars.itemAt(0).mockBar
    eq(widget(1).opened, false, "bar 1 closed")
    eq(service.clock.enabled, false, "the clock stops again when hidden")
    var n = mock.saved.length
    widget(0).save("showSeconds", false)
    eq(mock.saved.length, n + 1, "inline save recorded")
    var entry = mock.saved[n] || ({
        settings: {}
      })
    eq(entry.id, "foamy.clock", "saved under the widget's entry")
    eq(entry.settings.showSeconds, false, "the saved value")
    eq(entry.settings.format, "HH:mm", "the other settings stay: format")
    eq(entry.settings.agendaRefreshMinutes, 45, "the other settings stay: refresh")
    eq(widget(0).preference("showSeconds"), false, "a saved value reads back at once (FoamyPrefsQueue)")
    ipcCheck()
  }

  // 8. IPC through the shell's own registry, the one the omarchy-shell socket uses.
  function ipcCheck() {
    var registry = IpcResolver.registry(shell)
    check(registry !== null, "the shell's IpcRegistry is reachable")
    eq(IpcResolver.handlersFor(shell, "foamy.clock").length, 1, "one live IPC handler for three bars")
    same(registry ? registry.declaredFunctions(registry.handlerFor("foamy.clock")).slice().sort() : [], ["close", "cycleFormat", "hide", "open", "refresh", "settings", "show", "toggle", "toggleWeekStart"], "the IPC functions")
    eq(ipc("nope").ran, false, "an undeclared IPC function does not run")
    var sequence = [["open", true], ["close", false], ["show", true], ["hide", false], ["toggle", true], ["toggle", false]]
    var next = function (index) {
      if (index === sequence.length) {
        ipcActions()
        return
      }
      var method = sequence[index][0]
      var opened = sequence[index][1]
      eq(ipc(method).ran, true, "IPC " + method + " runs")
      step(function () {
        return widget(0).opened === opened
      }, "IPC " + method + (opened ? " opens" : " closes") + " the leader's popup", function () {
        next(index + 1)
      })
    }
    next(0)
  }
  function ipcActions() {
    var service = Clock.ClockService
    var mock = bars.itemAt(0).mockBar
    var year = new Date().getFullYear()
    for (var k = 0; k < 3; k++)
      widget(k).displayDate = new Date(2000, 0, 1)
    service.now = new Date(2000, 0, 1)
    eq(ipc("refresh").ran, true, "IPC refresh runs")
    for (k = 0; k < 3; k++)
      eq(widget(k).displayDate.getFullYear(), year, "IPC refresh reaches bar " + k)
    eq(service.now.getFullYear(), year, "and the leader refreshes the shared service")
    var n = mock.saved.length
    eq(ipc("cycleFormat").ran, true, "IPC cycleFormat runs")
    eq(mock.saved.length > n ? mock.saved[n].settings.format : "", "h:mm AP", "it saves the next format of the ring")
    var start = service.weekStart
    var flipped = start === 1 ? 0 : 1
    n = mock.saved.length
    eq(ipc("toggleWeekStart").ran, true, "IPC toggleWeekStart runs")
    eq(mock.saved.length > n ? mock.saved[n].settings.weekStartDay : "", flipped === 0 ? "sunday" : "monday", "it saves the week start by name")
    eq(service.weekStart, flipped, "the shared service follows")
    eq(service.weeks[0].days[0].weekday, flipped, "and so does the grid")
    ipc("toggleWeekStart")
    eq(service.weekStart, start, "a second toggle goes back")
    buttonCheck()
  }

  // The bar button's other clicks, emitted the way the host WidgetButton does.
  function buttonCheck() {
    var mock = bars.itemAt(2).mockBar
    var n = mock.saved.length
    button(2).pressed(Qt.RightButton)
    eq(mock.saved.length > n ? mock.saved[n].settings.format : "", "h:mm AP", "a right click saves the next format")
    mock.position = "left"
    button(2).pressed(Qt.RightButton)
    eq(mock.saved.length > n + 1 ? mock.saved[n + 1].settings.verticalFormat : "", "h\n—\nmm\nAP", "on a vertical bar it walks the vertical formats")
    eq(widget(2).preference("format"), "h:mm AP", "and leaves the horizontal format alone")
    mock.position = "top"
    button(2).pressed(Qt.MiddleButton)
    same(mock.ran, ["omarchy-menu-timezone"], "a middle click opens the timezone menu")
    eq(widget(2).opened, false, "neither click opens the popup")
    settingsStep()
  }

  // 9. The settings page, opened over IPC.
  function refreshDropdown() {
    return find(panel(0).popup.bodyItem, it => typeof it.select === "function" && it.label === Kit.FoamyI18n.t("Refresh every"))
  }
  function settingsStep() {
    eq(ipc("settings").ran, true, "IPC settings runs")
    step(function () {
      return widget(0).opened && panel(0).editingSettings && panel(0).popup.bodyItem !== null && refreshDropdown() !== null
    }, "IPC settings opens the leader's settings page", calendarAppDraftCheck)
  }
  // A typed calendar app the schema refuses stays in the field on Enter and
  // gives way to the saved name when the focus moves on; only a valid one is
  // saved. Offscreen, the bar popup gets no window and so no keyboard focus:
  // the page is checked in a window of its own (focusWindow).
  function calendarAppDraftCheck() {
    var app = find(focusPage, it => it.saveFailed !== undefined && it.label === Kit.FoamyI18n.t("Calendar app"))
    focusWindow.visible = true
    step(function () {
      return focusPage.Window.window !== null
    }, "the settings page has a window of its own", function () {
      var window = focusPage.Window.window
      window.requestActivate()
      step(function () {
        return window.active
      }, "its window is active", function () {
        app.field.focusInput()
        step(function () {
          return app.field.inputActiveFocus
        }, "the calendar app field takes the focus", function () {
          refusedCalendarApp(app)
        })
      })
    })
  }
  function refusedCalendarApp(app) {
    app.field.text = "gnome calendar"
    app.field.textEdited()
    app.field.accepted()
    eq(app.field.text, "gnome calendar", "Enter keeps a refused calendar app as a draft")
    eq(app.error, texts.notAllowed, "and the field says it is not allowed")
    focusPage.backTarget.forceActiveFocus()
    step(function () {
      return !app.field.inputActiveFocus
    }, "the focus leaves the calendar app field", function () {
      eq(app.field.text, "foamy-test-calendar", "the field shows the saved calendar app again")
      eq(app.error, texts.notAllowed, "and still says the typed one is not allowed")
      same(focusPage.saves, [], "a refused calendar app is not saved")
      app.field.focusInput()
      step(function () {
        return app.field.inputActiveFocus
      }, "the calendar app field takes the focus again", function () {
        app.field.text = "evolution"
        app.field.textEdited()
        focusPage.backTarget.forceActiveFocus()
        step(function () {
          return !app.field.inputActiveFocus
        }, "the focus leaves the calendar app field again", function () {
          same(focusPage.saves, [["calendarApp", "evolution"]], "a valid calendar app is saved on focus-out")
          eq(app.error, "", "with no error")
          customLocaleCheck()
        })
      })
    })
  }
  // Whether a visible text under `item` reads `text`.
  function shows(item, text) {
    return findAll(item, it => it.visible && it.textFormat !== undefined && it.text === text).length > 0
  }
  // Focuses `editor`, selects its text and types `text` over it, with real keys.
  function typeOver(editor, text, label, then) {
    editor.focusInput()
    step(function () {
      return editor.inputActiveFocus
    }, label, function () {
      ev.keyClick(Qt.Key_A, Qt.ControlModifier, -1)
      for (var i = 0; i < text.length; i++)
        ev.keyClickChar(text.charAt(i), Qt.NoModifier, -1)
      then()
    })
  }
  // The custom date locale editor: a locale the schema refuses ("de-DE") is
  // never sent to be saved. Enter keeps it as a draft with the field's own
  // error; a focus move (Tab) shows the saved locale again, still with the
  // error; the page shown again has the saved locale and no error. A valid
  // locale is saved on a focus move. A paste that fails (runtime.py's
  // wl-paste) says so under the editor.
  function customLocaleCheck() {
    var locale = find(focusPage, it => it.customMode !== undefined && it.key === "locale")
    var editor = find(locale, it => it.pasteError !== undefined)
    var saved = focusPage.saves
    eq(editor.visible ? editor.text : "", "de_DE", "the saved custom locale shows in its editor")
    typeOver(editor, "de-DE", "the custom locale editor takes the focus", function () {
      ev.keyClick(Qt.Key_Return, Qt.NoModifier, -1)
      eq(editor.text, "de-DE", "Enter keeps a refused locale as a draft")
      check(shows(locale, texts.notAllowed), "and the locale field says it is not allowed")
      ev.keyClick(Qt.Key_Tab, Qt.NoModifier, -1)
      step(function () {
        return !editor.inputActiveFocus
      }, "Tab leaves the custom locale editor", function () {
        eq(editor.text, "de_DE", "a focus move shows the saved locale again")
        check(shows(locale, texts.notAllowed), "and still says the typed one is not allowed")
        typeOver(editor, "de-DE", "the custom locale editor takes the focus again", function () {
          ev.keyClick(Qt.Key_Return, Qt.NoModifier, -1)
          // Leaving the page and coming back drops the draft.
          focusPage.visible = false
          focusPage.visible = true
          eq(editor.text, "de_DE", "the page shown again has the saved locale")
          check(!shows(locale, texts.notAllowed), "and no error for the draft that is gone")
          same(focusPage.saves, saved, "a refused locale is never sent to be saved")
          typeOver(editor, "fr_FR", "the custom locale editor takes the focus once more", function () {
            ev.keyClick(Qt.Key_Tab, Qt.NoModifier, -1)
            step(function () {
              return !editor.inputActiveFocus
            }, "Tab leaves the custom locale editor again", function () {
              same(focusPage.saves, saved.concat([["locale", "fr_FR"]]), "a valid locale is saved on a focus move")
              check(!shows(locale, texts.notAllowed), "with no error")
              editor.focusInput()
              step(function () {
                return editor.inputActiveFocus
              }, "the custom locale editor takes the focus for a paste", function () {
                ev.keyClick(Qt.Key_V, Qt.ControlModifier, -1)
                step(function () {
                  return shows(locale, texts.pasteFailed)
                }, "a failed paste says so under the custom locale editor", barFormatsCheck)
              })
            })
          })
        })
      })
    })
  }
  // "Bar formats" opened: a preset's preview splits at the clock glyph and
  // keeps the bar's gap (Style.spaceReal(6)) on each side of it. Whatever
  // fails to load there (a ReferenceError in the log) also fails the run.
  function barFormatsCheck() {
    find(focusPage, it => it.iconName !== undefined && it.label === Kit.FoamyI18n.t("Bar formats")).clicked()
    // The Row inside the "Bar format" dropdown's trigger label: date, glyph, time.
    var parts = function () {
      var format = find(focusPage, it => it.customMode !== undefined && it.key === "format")
      var dropdown = format ? find(format, it => it.triggerItem !== undefined) : null
      var label = dropdown ? find(dropdown.triggerItem, it => it.splitClock === true) : null
      var row = label ? find(label, it => it !== label && it.spacing !== undefined) : null
      return row && row.children.length === 3 ? row.children : null
    }
    step(function () {
      var shown = parts()
      return shown !== null && shown[2].x > shown[1].x && shown[1].x > 0
    }, "opening Bar formats shows the bar format's preview with its clock glyph", function () {
      var shown = parts()
      var gaps = [shown[1].x - (shown[0].x + shown[0].width), shown[2].x - (shown[1].x + shown[1].width)]
      check(gaps.every(gap => Math.abs(gap - Style.spaceReal(6)) < 0.01), "the preview keeps the bar's " + Style.spaceReal(6) + " px gap on each side of the clock glyph: " + JSON.stringify(gaps))
      focusWindow.visible = false
      settingsCheck()
    })
  }
  // The host empties a widget's moduleName when its bar entry goes away, and
  // the save queue then refuses every save. A refused pick in any dropdown
  // of the page, the bar formats' too, gives way to the saved value at once,
  // instead of staying on show next to the error until its hold runs out.
  function refusedPicksCheck(view) {
    var page = find(view, it => it.formatsOpen !== undefined)
    page.formatsOpen = true
    var dropdowns = findAll(page, it => typeof it.select === "function" && it.shownValue !== undefined)
    eq(dropdowns.length, 9, "the settings page has nine dropdowns with the bar formats open")
    widget(0).moduleName = ""
    for (var i = 0; i < dropdowns.length; i++) {
      var dropdown = dropdowns[i]
      var saved = dropdown.value
      var pick = dropdown.options.map(o => dropdown.optionValue(o)).filter(v => v !== saved && v !== "__custom")[0]
      dropdown.select(pick)
      eq(widget(0).settingsError, texts.noEntry, dropdown.label + ": the pick of " + JSON.stringify(pick) + " is refused without a bar entry")
      eq(dropdown.shownValue, saved, dropdown.label + ": the refused pick gives way to the saved value at once")
    }
    widget(0).moduleName = "foamy.clock"
    page.formatsOpen = false
  }
  function settingsCheck() {
    var service = Clock.ClockService
    var view = panel(0).popup.bodyItem
    var mock = bars.itemAt(0).mockBar
    var dropdown = refreshDropdown()
    eq(view.blocked, true, "the calendar keys are off while Settings shows")
    eq(dropdown.value, "45", "the refresh dropdown shows the stored value")
    check(dropdown.options.some(o => o.value === "45"), "and offers the stored custom value")
    var n = mock.saved.length
    dropdown.select("60")
    var entry = mock.saved[n] || ({
        settings: {}
      })
    eq(entry.id, "foamy.clock", "a pick saves under the widget's entry")
    eq(entry.settings.agendaRefreshMinutes, 60, "the picked minutes")
    eq(typeof entry.settings.agendaRefreshMinutes, "number", "as a number")
    eq(entry.settings.format, widget(0).preference("format"), "with the other settings")
    eq(widget(0).settingsError, "", "a valid pick reports no error")
    eq(dropdown.value, "60", "the dropdown shows the pick")
    widget(0).save("agendaRefreshMinutes", 120)
    eq(dropdown.value, "120", "and follows a change made outside the page")
    eq(service.refreshMinutes, 120, "the leader feeds the new interval to the engine")
    refusedPicksCheck(view)
    // The agenda switch: off hides the agenda at once.
    var agenda = find(view, it => it.switchItem !== undefined && it.label === Kit.FoamyI18n.t("Show agenda"))
    agenda.clicked()
    eq(service.agendaEnabled, false, "the agenda switch turns the agenda off")
    eq(service.agendaEvents.length, 0, "its events go")
    var tips = dayToolTipTexts(view)
    eq(tips.length, 42, "every day of the grid has a tooltip")
    same(tips.filter(text => text !== Kit.FoamyI18n.t("Select this date to see events")), [], "and none says the overview may be incomplete")
    eq(footer(view).status, "", "the footer says nothing about calendars")
    eq(footer(view).showRefresh, false, "and offers no refresh")
    agenda.clicked()
    step(function () {
      return service.agendaEnabled && service.agendaEvents.length === 2 && !service.agendaLoading
    }, "switched on again, the saved events come back", function () {
      var saves = mock.saved.length
      widget(0).save("calendarApp", "a;b")
      eq(widget(0).settingsError, texts.notAllowed, "an invalid value is refused")
      eq(mock.saved.length, saves, "and nothing is written")
      eq(view.settingsError, texts.notAllowed, "the open page shows the error")
      view.closeRequested()
      step(function () {
        return !panel(0).editingSettings
      }, "Esc leaves Settings", function () {
        eq(widget(0).opened, true, "and keeps the popup open")
        view.closeRequested()
        step(function () {
          return !widget(0).opened
        }, "a second Esc closes the popup", function () {
          widget(0).open()
          step(function () {
            return widget(0).opened
          }, "the popup opens again", function () {
            eq(panel(0).editingSettings, false, "on the calendar, not Settings")
            hostileCalendar()
          })
        })
      })
    })
  }

  // 10. The calendar shortcut. A stored name that is not a bare command never
  // reaches the check: the default does.
  function hostileCalendar() {
    widget(2).settings = ({
        calendarApp: "x;touch pwned"
      })
    panel(2).openCalendar()
    step(function () {
      return panel(2).launchError !== ""
    }, "a hostile stored calendar app is not launched", function () {
      eq(launched(), "", "nothing launched")
      widget(2).settings = Qt.binding(() => shell.barSettings)
      missingCalendar()
    })
  }
  function missingCalendar() {
    var view = panel(0).popup.bodyItem
    widget(0).save("calendarApp", "foamy-missing-calendar")
    openCalendarButton(view).clicked()
    step(function () {
      return panel(0).launchError !== ""
    }, "a missing calendar app reports an error", function () {
      eq(footer(view).status, texts.launchFailed, "the footer shows the launch error")
      eq(footer(view).statusError, true, "as an error")
      eq(launched(), "", "nothing launched")
      eq(widget(0).opened, true, "the popup stays open")
      widget(0).close()
      step(function () {
        return !widget(0).opened
      }, "the popup closes", function () {
        eq(panel(0).launchError, "", "closing clears the error")
        widget(0).save("calendarApp", "foamy-test-calendar")
        widget(0).open()
        step(function () {
          return widget(0).opened
        }, "the popup opens again", presentCalendar)
      })
    })
  }
  function presentCalendar() {
    openCalendarButton(panel(0).popup.bodyItem).clicked()
    step(function () {
      return shell.launched() !== ""
    }, "a present calendar app is launched", function () {
      eq(shell.launched(), "foamy-test-calendar\n", "launched through omarchy-launch-or-focus")
      eq(widget(0).opened, false, "and the popup closes")
      eq(panel(0).launchError, "", "with no error")
      // The hostile name's check got the default; one check per click.
      same(presentChecks(), ["gnome-calendar", "foamy-missing-calendar", "foamy-test-calendar"], "the calendar app checks")
      finishCheck()
    })
  }

  // 11. Every popup is closed. Never-attempted months go nearest first, so
  // the first background prefetch is this month (QV4's Array.sort is not
  // stable, unlike node's). Run here, at the end, because the prefetch of a
  // month with Evolution unreachable turns the saved month partial.
  function finishCheck() {
    var service = Clock.ClockService
    step(function () {
      return !service.agendaProcess.running && !service.cacheProcess.running
    }, "the helper runs settle", function () {
      service.prefetchAttempts = ({})
      service.schedulePrefetch()
      eq(service.agendaPrefetch, true, "a background prefetch starts")
      eq(service.agendaProcessRangeStartKey, service.prefetchRanges(new Date())[0].start, "the first background prefetch is this month")
      var exits = agendaExits.length
      step(function () {
        return agendaExits.length > exits && !service.agendaProcess.running
      }, "the background prefetch ends", argvCheck)
    })
  }
  // A refused argv (argparse exits 2) or an uncaught error (1) would look
  // like an ordinary error month in the popup. Runs killed by a signal are
  // not normal exits and are left out.
  function argvCheck() {
    var refused = []
    var ended = {
      cached: 0,
      foreground: 0,
      prefetch: 0
    }
    for (var i = 0; i < cacheExits.length; i++) {
      if (cacheExits[i].status === 0 && (cacheExits[i].code === 1 || cacheExits[i].code === 2))
        refused.push(cacheStarts[i])
      if (cacheExits[i].status === 0 && cacheExits[i].code === 0)
        ended.cached++
    }
    for (i = 0; i < agendaExits.length; i++) {
      if (agendaExits[i].status === 0 && (agendaExits[i].code === 1 || agendaExits[i].code === 2))
        refused.push(agendaStarts[i])
      if (agendaExits[i].status === 0 && agendaExits[i].code === 0)
        ended[prefetch(agendaStarts[i]) ? "prefetch" : "foreground"]++
    }
    same(refused, [], "the helper accepted every run's arguments")
    check(ended.cached > 0 && ended.foreground > 0 && ended.prefetch > 0, "a cached read, a refresh and a prefetch each ended normally: " + JSON.stringify(ended))
    shell.finish()
  }
}
