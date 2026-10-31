import QtQuick
import qs.Ui
import ".." as Dev

// The dev (pre-kit) clock popup for `render.py --trio` Before shots. The dev
// Panel.qml builds its ClockPopup fork itself; the harness reparents that
// window onto the simulated screen, so it is found there. Its agenda runs on
// the harness's private bus (no EDS), then mock data is put in its place.
Item {
  id: preview
  required property QtObject bar
  required property Item anchorItem
  property var previewStates: ["agenda", "empty", "error", "settings"]
  property string previewState: "agenda"
  property int settleMs: 3500
  readonly property Item popup: findPopup()

  function findPopup() {
    var items = FakeDisplay.overlay ? FakeDisplay.overlay.children : []
    for (var i = 0; i < items.length; i++)
      if (items[i] && items[i].anchorItem === preview.anchorItem && items[i].contentWidth !== undefined) return items[i]
    return null
  }
  function at(hour, minute) { return Math.floor(new Date(2026, 9, 30, hour, minute).getTime() / 1000) }
  readonly property var sample: [
    { id: "work:1", title: "Team standup", calendar: "Work", location: "Room 4", color: "#7aa2f7", allDay: false, start: at(9, 0), end: at(9, 15), startDate: "", endDate: "" },
    { id: "work:2", title: "Design review: foamy kit", calendar: "Work", location: "Video call", color: "#7aa2f7", allDay: false, start: at(10, 0), end: at(11, 0), startDate: "", endDate: "" },
    { id: "home:1", title: "Pick up bike", calendar: "Personal", location: "", color: "#9ece6a", allDay: false, start: at(16, 30), end: at(17, 0), startDate: "", endDate: "" }
  ]

  function apply() {
    old.monthView = null
    old.today = new Date(2026, 9, 30, 10, 24, 37)
    old.now = old.today
    old.timeZoneName = "Europe/Oslo"
    old.viewYear = 2026; old.viewMonth = 9
    old.selectedDate = new Date(2026, 9, 30)
    old.calendarDates = { "2026-10-30": [{ id: "work", color: "#7aa2f7" }, { id: "home", color: "#9ece6a" }],
      "2026-10-27": [{ id: "work", color: "#7aa2f7" }], "2026-11-03": [{ id: "home", color: "#9ece6a" }] }
    old.selectedCalendars = 2
    old.lastAgendaRefreshMs = old.now.getTime() - 4 * 60000
    old.agendaEvents = previewState === "agenda" ? sample : []
    old.agendaState = previewState === "error" ? "error" : "ok"
    old.editingSettings = previewState === "settings"
  }
  onPreviewStateChanged: apply()

  Dev.Panel {
    id: old
    bar: preview.bar
    anchorItem: preview.anchorItem
    settings: ({})
    Component.onCompleted: Qt.callLater(function() { old.open(); settle.start() })
  }
  // Let the dev agenda's own (failing) first load finish, then show mock data.
  Timer { id: settle; interval: 2500; onTriggered: preview.apply() }
}
