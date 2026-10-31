import QtQuick
import "../kit"
import ".." as Clock

// Preview states for the foamy-kit preview harness (mock data only: the
// shared ClockService is never activated, so no process runs).
Item {
  id: preview
  required property QtObject bar
  required property Item anchorItem
  property var previewStates: ["agenda", "empty", "error", "settings", "settings-error"]
  property string previewState: "agenda"
  property int settleMs: 700
  readonly property Item popup: popup

  readonly property var service: Clock.ClockService
  function at(hour, minute) { return Math.floor(new Date(2026, 9, 30, hour, minute).getTime() / 1000) }
  readonly property var sample: [
    { id: "work:1", title: "Team standup", calendar: "Work", location: "Room 4", color: "#7aa2f7", allDay: false, start: at(9, 0), end: at(9, 15), startDate: "", endDate: "" },
    { id: "work:2", title: "Design review: foamy kit", calendar: "Work", location: "Video call", color: "#7aa2f7", allDay: false, start: at(10, 0), end: at(11, 0), startDate: "", endDate: "" },
    { id: "home:1", title: "Pick up bike", calendar: "Personal", location: "", color: "#9ece6a", allDay: false, start: at(16, 30), end: at(17, 0), startDate: "", endDate: "" }
  ]

  function apply() {
    var s = service
    s.today = new Date(2026, 9, 30, 10, 24, 37)
    s.now = s.today
    s.timeZoneName = "Europe/Oslo"
    s.weekStart = 1
    s.viewYear = 2026; s.viewMonth = 9
    s.selectedDate = new Date(2026, 9, 30)
    s.calendarDates = { "2026-10-30": [{ id: "work", color: "#7aa2f7" }, { id: "home", color: "#9ece6a" }],
      "2026-10-27": [{ id: "work", color: "#7aa2f7" }], "2026-11-03": [{ id: "home", color: "#9ece6a" }] }
    s.selectedCalendars = 2
    s.lastAgendaRefreshMs = s.now.getTime() - 4 * 60000
    s.agendaEvents = previewState === "agenda" ? sample : []
    s.agendaState = previewState === "error" ? "error" : "ok"
  }
  onPreviewStateChanged: apply()
  Component.onCompleted: apply()

  FoamyPopup {
    id: popup
    anchorItem: preview.anchorItem
    bar: preview.bar
    open: true
    centerOnBar: true
    maxHeight: 0
    body: Component {
      Clock.ClockView {
        settings: ({})
        availableHeight: popup.availableCardHeight
        verticalInset: popup.verticalContentInset
        opened: true
        editingSettings: preview.previewState.indexOf("settings") === 0
        settingsError: preview.previewState === "settings-error" ? "Couldn't save the setting." : ""
        retryable: true
      }
    }
  }
}
