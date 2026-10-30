import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "kit"
import "kit/FoamyPrefs.js" as Prefs
import "Preferences.js" as Schema

// The calendar popup host for one bar (one per monitor). Light by design:
// the popup content (ClockView) is built on first open, and the calendar and
// agenda state come from ClockService, shared by every monitor.
//
// BarWidget.qml owns the bar label and hands this panel the button to
// anchor against.
Panel {
  id: root
  moduleName: "foamy.clock"
  ipcTarget: "foamy.clock"
  manageIpc: false

  property var anchorItem: null
  property bool editingSettings: false
  property string launchError: ""
  readonly property alias popup: popup

  // The bar tracks the widget mounted in its slot (BarWidget.qml), not this
  // nested panel. Everything the bar identifies a panel by has to be that
  // widget: the popout coordinator (and with it the open-panel dot under the
  // pill) compares against `slot.activeItem`, and switchPanelFrom looks the
  // slot up the same way.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  function preference(key) { return Prefs.value(Schema.fields, root.settings, key) }

  function openSettings() {
    root.open()
    root.editingSettings = true
    Qt.callLater(function() { if (popup.bodyItem) popup.bodyItem.settingsOpened() })
  }
  function closeSettings() {
    root.editingSettings = false
    Qt.callLater(function() { if (popup.bodyItem) popup.bodyItem.forceActiveFocus() })
  }
  onOpenedChanged: if (!opened) { editingSettings = false; launchError = "" }

  function open() {
    ClockService.refresh()
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

  function openCalendar() {
    if (!calendarLaunch.running) calendarLaunch.running = true
  }

  Process {
    id: calendarLaunch
    // Check PATH first; detach the app so its lifetime is independent of this
    // popup. The name is a bare command (Preferences.js pattern): it reaches
    // an `eval` inside omarchy-launch-or-focus.
    command: ["sh", "-c", 'command -v "$1" >/dev/null 2>&1', "foamy-clock", root.preference("calendarApp")]
    onExited: function(exitCode) {
      root.launchError = exitCode === 0 ? "" : FoamyI18n.t("Calendar app could not be started.")
      if (exitCode === 0) {
        Quickshell.execDetached(["omarchy-launch-or-focus", root.preference("calendarApp")])
        root.close()
      }
    }
  }

  FoamyPopup {
    id: popup
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    // The calendar is the one foamy popup taller than popupMaxHeight: it
    // compacts itself by screen height instead (ClockView.compactHeight), so
    // it may use the whole card height the host allows.
    contentHeight: popup.fittedContentHeight(popup.bodyImplicitHeight)
    focusTarget: bodyItem ? (root.editingSettings ? bodyItem.settingsBackTarget : bodyItem) : null
    body: Component {
      ClockView {
        settings: root.settings
        availableHeight: popup.availableCardHeight
        verticalInset: popup.verticalContentInset
        opened: root.opened
        editingSettings: root.editingSettings
        saving: root.hostWidget ? root.hostWidget.saving : false
        settingsError: root.hostWidget ? root.hostWidget.settingsError : ""
        retryable: root.hostWidget ? root.hostWidget.lastSave !== null : false
        launchError: root.launchError
        onCloseRequestedByView: root.editingSettings ? root.closeSettings() : root.close()
        onSettingsRequested: root.openSettings()
        onSettingsClosed: root.closeSettings()
        onSwitchPanelRequested: function(direction) { root.switchPanel(direction) }
        onCalendarRequested: root.openCalendar()
        onSaveRequested: function(key, value) { if (root.hostWidget) root.hostWidget.save(key, value) }
        onRetryRequested: if (root.hostWidget) root.hostWidget.retrySave()
        onWeekStartToggleRequested: if (root.hostWidget) root.hostWidget.toggleWeekStart()
      }
    }
  }
}
