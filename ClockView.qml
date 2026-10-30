import QtQuick
import QtQuick.Controls as Controls
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "kit"
import "kit/FoamyPrefs.js" as Prefs
import "Model.js" as Model
import "Preferences.js" as Schema

// The calendar popup body (built on first open): clock hero, month grid,
// the selected day's agenda, footer, and the settings page.
//
// Keyboard: one cursor over the days. Arrows/hjkl move it (a day, or a week
// up/down), Enter/Space select the day under it (or go back to today when
// there is no cursor), [ ] and { } step months/years, t is today, w flips
// the week start, s opens Settings, r refreshes, PgUp/PgDn scroll the
// agenda, Tab/Shift-Tab switch to the neighbouring bar panel, Esc closes.
// Hovering a day moves the same cursor; hovering an action clears it.
PanelKeyCatcher {
  id: root

  property var settings: ({})
  property real availableHeight: 0
  property real verticalInset: 0
  property bool opened: false
  property bool editingSettings: false
  property bool saving: false
  property string settingsError: ""
  property bool retryable: false
  property string launchError: ""
  readonly property alias settingsBackTarget: settingsPage.backTarget

  signal closeRequestedByView()
  signal settingsRequested()
  signal settingsClosed()
  signal switchPanelRequested(int direction)
  signal calendarRequested()
  signal saveRequested(string key, var value)
  signal retryRequested()
  signal weekStartToggleRequested()

  function preference(key) { return Prefs.value(Schema.fields, root.settings, key) }
  function settingsOpened() { settingsPage.resetScroll(); settingsPage.focusBack() }

  readonly property var service: ClockService
  readonly property string localeName: Schema.localeName(preference("locale"), FoamyI18n.formatLocale)
  readonly property var displayLocale: Qt.locale(localeName)
  readonly property bool twelveHour: preference("timeFormat") === "12-hour"
  readonly property string timeFormat: twelveHour ? "h:mm AP" : "HH:mm"
  // The catalog pattern speaks for the Omarchy language's own date locale;
  // for any other date locale (4.0, or a chosen one) use that locale's long
  // format without the year.
  readonly property bool catalogDates: FoamyI18n.translationsAvailable && preference("locale") === ""
  function datePattern(catalogKey) {
    return catalogDates ? FoamyI18n.t(catalogKey) : Model.dateWithoutYear(displayLocale.dateFormat(Locale.LongFormat))
  }
  readonly property string heroDateText: displayLocale.toString(service.today, datePattern("dddd, MMMM d"))
  readonly property string agendaDateLabel: service.selectedDateIsToday
    ? FoamyI18n.t("Today")
    : displayLocale.toString(service.selectedDate, catalogDates ? FoamyI18n.t("ddd, MMM d")
        : Model.abbreviatedDate(Model.dateWithoutYear(displayLocale.dateFormat(Locale.LongFormat))))
  readonly property string monthTitle: FoamyI18n.t("{month} {year}", {
    month: displayLocale.standaloneMonthName(service.viewMonth, Locale.LongFormat),
    year: FoamyI18n.number(service.viewYear)
  })
  readonly property string nextWeekStartLabel: displayLocale.dayName(Model.toggledWeekStart(service.weekStart), Locale.LongFormat)

  readonly property color weekColumnColor: Qt.tint(Commons.Color.popups.background, Qt.alpha(FoamyPalette.text, 0.035))
  readonly property real cellWidth: Math.max(1, (body.width - weekColumnWidth - gutterWidth - cellSpacing * 6) / 7)
  // Leave room for the agenda on short displays without scrolling the calendar.
  readonly property bool compactHeight: availableHeight > 0 && availableHeight < Style.space(760)
  readonly property bool veryShortHeight: availableHeight > 0 && availableHeight < Style.space(600)
  readonly property int cellHeight: Style.space(veryShortHeight ? 24 : compactHeight ? 28 : 38)
  readonly property int cellSpacing: FoamyStyle.gapTiny
  readonly property int weekColumnWidth: Style.space(32)
  readonly property int gutterWidth: Style.space(5)

  // ---- The day cursor (keyboard and pointer), separate from the selection.
  property string cursorKey: ""
  function visibleInGrid(key) {
    return service.weeks.some(w => w.days.some(d => d.key === key))
  }
  function moveCursor(days) {
    // Start from the cursor, else the selected day, as long as it is on the
    // shown grid. After browsing months (keys, chevrons, wheel) neither may
    // be: the first press then lands on the shown month (today if it is in
    // it, else its first day) instead of jumping back to the old month.
    var base = cursorKey !== "" && visibleInGrid(cursorKey) ? cursorKey
      : visibleInGrid(service.selectedDateKey) ? service.selectedDateKey : ""
    if (base === "") {
      cursorKey = service.viewingCurrentMonth ? service.todayKey : Model.dateKey(service.viewYear, service.viewMonth, 1)
      return
    }
    var parts = base.split("-").map(Number)
    var next = new Date(parts[0], parts[1] - 1, parts[2] + days)
    cursorKey = Model.keyForDate(next)
    if (next.getFullYear() !== service.viewYear || next.getMonth() !== service.viewMonth) {
      // Keep the cursor's day on screen: the grid shows its own month.
      var visible = service.weeks.some(w => w.days.some(d => d.key === cursorKey && d.inMonth))
      if (!visible) {
        service.viewYear = next.getFullYear()
        service.viewMonth = next.getMonth()
      }
    }
  }
  function activateCursor() {
    if (cursorKey === "") { service.goToToday(); return }
    var parts = cursorKey.split("-").map(Number)
    service.selectDate(parts[0], parts[1] - 1, parts[2])
  }
  onOpenedChanged: if (!opened) cursorKey = ""

  function updatedAgoText() {
    if (service.agendaState === "error") return FoamyI18n.t("Calendar unavailable")
    if (service.agendaState === "partial") return FoamyI18n.t("Partial update · open calendar")
    if (service.agendaState === "loading") return FoamyI18n.t("Updating…")
    if (service.lastAgendaRefreshMs <= 0) return ""
    var elapsedMinutes = Math.max(0, Math.floor((service.now.getTime() - service.lastAgendaRefreshMs) / 60000))
    if (elapsedMinutes === 0) return FoamyI18n.t("Updated just now")
    return FoamyI18n.tn("Updated %1 minutes ago", elapsedMinutes)
  }

  function agendaMessageText() {
    if (service.agendaState === "error") return FoamyI18n.t("Calendar data is unavailable")
    if (service.agendaState === "partial") return FoamyI18n.t("Some events may be missing. Open calendar for the full view.")
    return service.agendaMessage
  }

  function agendaCountText() {
    if (service.agendaState === "loading" || service.agendaState === "error") return ""
    if (service.agendaState === "partial") return FoamyI18n.t("%1 shown", service.agendaEvents.length)
    return FoamyI18n.tn("%1 events", service.agendaEvents.length)
  }

  function heroTimeText() {
    if (!root.twelveHour) return root.displayLocale.toString(service.now, "HH:mm")
    // Qt chooses 12-hour h only when the same format contains an AM/PM token.
    var full = root.displayLocale.toString(service.now, "h:mm AP")
    var period = root.displayLocale.toString(service.now, "AP")
    return period ? full.slice(0, -period.length).trim() : full
  }

  function eventState(event) {
    if (!event || event.allDay === true) return "all-day"
    var current = service.now.getTime() / 1000
    if (current < Number(event.start || 0)) return "upcoming"
    if (current < Number(event.end || event.start || 0)) return "ongoing"
    return "past"
  }

  function eventTimeText(event) {
    if (!event || event.allDay === true) return FoamyI18n.t("All day")
    var start = root.displayLocale.toString(new Date(Number(event.start) * 1000), root.timeFormat)
    var end = root.displayLocale.toString(new Date(Number(event.end) * 1000), root.timeFormat)
    return start + "–" + end
  }

  function eventDetails(event) {
    var calendar = String(event && event.calendar ? event.calendar : FoamyI18n.t("Calendar"))
    var location = root.preference("showEventLocations") ? String(event && event.location ? event.location : "") : ""
    return location === "" ? calendar : calendar + "  ·  " + location
  }

  implicitWidth: FoamyStyle.popupWidth
  implicitHeight: editingSettings ? Math.min(settingsPage.implicitHeight, FoamyStyle.popupMaxHeight) : calendarColumn.implicitHeight
  blocked: editingSettings

  onMoveRequested: function(dx, dy) { root.moveCursor(dx !== 0 ? dx : dy * 7) }
  onActivateRequested: root.activateCursor()
  onCloseRequested: root.closeRequestedByView()
  onTabRequested: function(direction) { root.switchPanelRequested(direction) }
  onTextKey: function(t) {
    if (t === "[") service.moveMonth(-1)
    else if (t === "]") service.moveMonth(1)
    else if (t === "{") service.moveYear(-1)
    else if (t === "}") service.moveYear(1)
    else if (t === "t" || t === "T") { root.cursorKey = ""; service.goToToday() }
    else if (t === "w" || t === "W") root.weekStartToggleRequested()
    else if (t === "s" || t === "S") root.settingsRequested()
    else if ((t === "r" || t === "R") && service.agendaEnabled) service.refreshAgenda(true)
  }
  Keys.onReleased: function(event) {
    if (root.editingSettings || !agendaScroll.interactive) return
    var direction = event.key === Qt.Key_PageDown ? 1 : event.key === Qt.Key_PageUp ? -1 : 0
    if (direction === 0) return
    agendaScroll.cancelFlick()
    agendaScroll.contentY = Math.max(0, Math.min(agendaScroll.contentHeight - agendaScroll.height,
      agendaScroll.contentY + direction * agendaScroll.height))
    event.accepted = true
  }

  Connections {
    target: ClockService
    function onAgendaReset() { agendaScroll.contentY = 0 }
  }

  component ClockLabel: Text {
    textFormat: Text.PlainText
    color: FoamyPalette.text
    font.family: FoamyStyle.fontFamily
    font.pixelSize: FoamyStyle.font.subtitle
  }

  Item {
    anchors.fill: parent
    visible: !root.editingSettings
    clip: true

    Column {
      id: calendarColumn
      width: parent.width

      Item {
        id: hero
        width: parent.width
        height: heroContent.implicitHeight + Style.space(root.veryShortHeight ? 16 : root.compactHeight ? 24 : 49)

        // The foamy header wash (static; the seconds never repaint it).
        Canvas {
          id: headerBackground
          readonly property real cornerRadius: Math.max(0, Math.min(width / 2, height, FoamyStyle.radius - 1))
          onCornerRadiusChanged: requestPaint()
          anchors.fill: parent
          onWidthChanged: requestPaint()
          onHeightChanged: requestPaint()
          onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            var radius = cornerRadius
            ctx.beginPath()
            ctx.moveTo(radius, 0); ctx.lineTo(width - radius, 0)
            ctx.arcTo(width, 0, width, radius, radius)
            ctx.lineTo(width, height); ctx.lineTo(0, height); ctx.lineTo(0, radius)
            ctx.arcTo(0, 0, radius, 0, radius); ctx.closePath(); ctx.clip()
            var accent = Commons.Color.accent
            var gradient = ctx.createLinearGradient(0, 0, width * 0.5, height)
            gradient.addColorStop(0, Qt.tint(Commons.Color.popups.background, Qt.rgba(accent.r, accent.g, accent.b, 0.08)))
            gradient.addColorStop(1, Commons.Color.popups.background)
            ctx.fillStyle = gradient; ctx.fillRect(0, 0, width, height)
            var glowX = LayoutMirroring.enabled ? width * 0.1 : width * 0.9
            var glow = ctx.createRadialGradient(glowX, 0, 0, glowX, 0, width * 0.85)
            glow.addColorStop(0, Qt.rgba(accent.r, accent.g, accent.b, 0.17))
            glow.addColorStop(1, "transparent")
            ctx.fillStyle = glow; ctx.fillRect(0, 0, width, height)
          }
          Connections {
            target: Commons.Color
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
            text: service.timeZoneName || Qt.formatDateTime(service.now, "t")
            font.pixelSize: FoamyStyle.font.body
            elide: Text.ElideRight
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(5)
            height: heroClock.implicitHeight
            // Times read left to right in every language.
            LayoutMirroring.enabled: false

            // The clock face is display art, larger than the type scale.
            ClockLabel {
              id: heroClock
              text: root.heroTimeText()
              font.pixelSize: Style.space(root.veryShortHeight ? 32 : root.compactHeight ? 40 : 56)
              font.features: ({ "tnum": 1 })
            }
            ClockLabel {
              visible: root.preference("showSeconds")
              anchors.baseline: heroClock.baseline
              text: root.displayLocale.toString(service.now, ":ss")
              font.pixelSize: root.compactHeight ? FoamyStyle.font.iconLarge : Style.space(25)
              font.features: ({ "tnum": 1 })
              color: FoamyPalette.secondaryText
            }
            ClockLabel {
              visible: root.twelveHour
              anchors.baseline: heroClock.baseline
              text: root.displayLocale.toString(service.now, "AP")
              font.pixelSize: root.compactHeight ? FoamyStyle.font.iconLarge : Style.space(25)
              color: FoamyPalette.secondaryText
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(5)
            ClockLabel {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: root.heroDateText
              font.pixelSize: root.compactHeight ? FoamyStyle.font.title : FoamyStyle.font.iconLarge
              wrapMode: Text.WordWrap
            }
            ClockLabel {
              visible: !root.veryShortHeight
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: FoamyI18n.t("Week %1 · %2", [
                Model.isoWeek(service.today.getFullYear(), service.today.getMonth(), service.today.getDate()),
                service.today.getFullYear()])
              color: FoamyPalette.secondaryText
              font.pixelSize: FoamyStyle.font.body
            }
          }
        }

        MouseArea {
          id: heroMouse
          anchors.fill: parent
          enabled: !service.viewingCurrentMonth || !service.selectedDateIsToday
          hoverEnabled: enabled
          cursorShape: Qt.PointingHandCursor
          onClicked: { root.cursorKey = ""; service.goToToday() }
          PanelToolTip {
            visible: heroMouse.containsMouse
            text: FoamyI18n.t("Back to today")
            fontFamily: FoamyStyle.fontFamily
          }
        }
        FoamyAction {
          id: settingsButton
          anchors.top: parent.top
          anchors.right: parent.right
          anchors.topMargin: FoamyStyle.gapLarge
          anchors.rightMargin: FoamyStyle.sectionGap
          settings: true
          iconName: "settings"
          foreground: FoamyPalette.secondaryText
          tooltipText: FoamyI18n.t("Settings")
          onClicked: root.settingsRequested()
          onHoveredChanged: if (hovered) root.cursorKey = ""
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
        spacing: root.veryShortHeight ? FoamyStyle.gap : FoamyStyle.gapLarge

        // Measure only fixed sections: including the viewport here would
        // create a feedback loop between the popup cap and list height.
        readonly property real fixedHeight: hero.height + heroBoundary.height
          + calendarHeader.implicitHeight + (service.agendaEnabled ? agendaHeading.height + agendaBlock.spacing : 0)
          + footerBlock.implicitHeight + body.spacing * 2

        Column {
          id: calendarHeader
          width: parent.width
          spacing: body.spacing

          Item {
            width: parent.width
            height: FoamyStyle.actionSize
            ClockLabel {
              anchors.left: parent.left
              anchors.right: monthActions.left
              anchors.verticalCenter: parent.verticalCenter
              horizontalAlignment: Text.AlignLeft
              text: root.monthTitle
              elide: Text.ElideRight
            }
            Row {
              id: monthActions
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: FoamyStyle.gapSmall
              // No chevron-left in the kit set yet: the right chevron turned
              // around (FoamyIcon mirrors both in right-to-left languages).
              FoamyAction {
                iconName: ""
                tooltipText: FoamyI18n.t("Previous month")
                onClicked: service.moveMonth(-1)
                onHoveredChanged: if (hovered) root.cursorKey = ""
                FoamyIcon {
                  anchors.centerIn: parent
                  width: FoamyStyle.iconSize; height: width
                  name: "chevron-right"
                  rotation: 180
                  color: FoamyPalette.secondaryText
                }
              }
              FoamyAction {
                iconName: "chevron-right"
                foreground: FoamyPalette.secondaryText
                tooltipText: FoamyI18n.t("Next month")
                onClicked: service.moveMonth(1)
                onHoveredChanged: if (hovered) root.cursorKey = ""
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
                service.moveMonth(event.angleDelta.y > 0 ? -1 : 1)
              }
            }

            // One continuous muted surface separates weeks without a rule.
            Rectangle {
              width: root.weekColumnWidth
              height: parent.height
              radius: FoamyStyle.radius
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
                  radius: FoamyStyle.radius
                  color: weekStartMouse.containsMouse ? FoamyPalette.hoverFill : "transparent"
                  ClockLabel {
                    anchors.centerIn: parent
                    text: FoamyI18n.t("Week")
                    color: FoamyPalette.mutedText
                    font.pixelSize: FoamyStyle.font.bodySmall
                  }
                  MouseArea {
                    id: weekStartMouse
                    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onContainsMouseChanged: if (containsMouse) root.cursorKey = ""
                    onClicked: root.weekStartToggleRequested()
                    PanelToolTip {
                      visible: weekStartMouse.containsMouse
                      text: FoamyI18n.t("Start weeks on %1", root.nextWeekStartLabel)
                      fontFamily: FoamyStyle.fontFamily
                    }
                  }
                }
                Item { width: root.gutterWidth; height: 1 }
                Row {
                  spacing: root.cellSpacing
                  Repeater {
                    model: service.weekdays
                    ClockLabel {
                      required property int modelData
                      width: root.cellWidth; height: Style.space(28)
                      horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                      // Narrow locale labels keep all seven columns readable on small screens.
                      text: root.displayLocale.dayName(modelData, Locale.NarrowFormat)
                      color: FoamyPalette.secondaryText
                      font.pixelSize: FoamyStyle.font.bodySmall
                    }
                  }
                }
              }
              Repeater {
                model: service.weeks
                Row {
                  required property var modelData
                  ClockLabel {
                    width: root.weekColumnWidth; height: root.cellHeight
                    horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                    text: FoamyI18n.number(modelData.week)
                    color: FoamyPalette.mutedText
                    font.pixelSize: FoamyStyle.font.bodySmall
                  }
                  Item { width: root.gutterWidth; height: 1 }
                  Row {
                    spacing: root.cellSpacing
                    Repeater {
                      model: modelData.days
                      Rectangle {
                        id: dayCell
                        required property var modelData
                        readonly property var dots: service.dotsForDate(modelData.key)
                        readonly property int dotCount: dots.length
                        readonly property bool selected: modelData.key === service.selectedDateKey
                        readonly property bool hasCursor: modelData.key === root.cursorKey
                        width: root.cellWidth; height: root.cellHeight
                        radius: FoamyStyle.radius
                        color: selected ? FoamyPalette.selectedFill : hasCursor ? FoamyPalette.hoverFill : "transparent"
                        border.width: modelData.today ? Style.spacing.hairline : 0
                        border.color: Commons.Color.accent
                        Accessible.role: Accessible.Button
                        Accessible.name: root.displayLocale.toString(new Date(modelData.year, modelData.month, modelData.day), Locale.LongFormat)

                        Item {
                          anchors.bottom: parent.bottom
                          width: parent.width; height: Math.max(Style.space(2), Math.min(dayCell.radius, dayCell.width / 2, dayCell.height / 2))
                          visible: dayCell.selected
                          clip: true
                          // The inset highlight tapers around the bottom corners.
                          Rectangle {
                            anchors.bottom: parent.bottom
                            width: dayCell.width; height: dayCell.height
                            radius: dayCell.radius; color: Commons.Color.accent; antialiasing: true
                            Rectangle {
                              anchors.fill: parent; anchors.bottomMargin: Style.space(2)
                              radius: dayCell.radius; color: dayCell.color; antialiasing: true
                            }
                          }
                        }
                        ClockLabel {
                          anchors.centerIn: parent
                          anchors.verticalCenterOffset: -Style.space(2)
                          text: FoamyI18n.number(modelData.day)
                          color: modelData.inMonth ? FoamyPalette.text : FoamyPalette.mutedText
                          font.pixelSize: FoamyStyle.font.body
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
                              color: modelData.color || Commons.Color.accent
                            }
                          }
                        }
                        MouseArea {
                          id: dayMouse
                          anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                          onContainsMouseChanged: if (containsMouse) root.cursorKey = dayCell.modelData.key
                          onClicked: service.selectDate(dayCell.modelData.year, dayCell.modelData.month, dayCell.modelData.day)
                        }
                        PanelToolTip {
                          visible: dayMouse.containsMouse && (dayCell.dotCount > 0 || service.dateIsIncomplete(dayCell.modelData.key))
                          text: !service.dateIsIncomplete(dayCell.modelData.key)
                            ? FoamyI18n.t("Select this date to see events")
                            : FoamyI18n.t("Calendar overview may be incomplete")
                          fontFamily: FoamyStyle.fontFamily
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
          visible: service.agendaEnabled
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
              text: root.agendaCountText()
              color: FoamyPalette.secondaryText; font.pixelSize: FoamyStyle.font.bodySmall
            }
          }
          ListView {
            id: agendaScroll
            width: parent.width
            height: Math.min(contentHeight, Math.max(0,
              (root.availableHeight > 0 ? root.availableHeight : body.fixedHeight + contentHeight)
              - root.verticalInset - body.fixedHeight))
            contentWidth: width
            model: service.agendaEvents
            spacing: agendaBlock.spacing
            reuseItems: true
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
                color: FoamyPalette.mutedText
              }
              background: Item {}
            }

            header: ClockLabel {
              visible: service.agendaEvents.length === 0
              height: visible ? implicitHeight : 0
              width: agendaScroll.width
              topPadding: FoamyStyle.gapLarge; bottomPadding: FoamyStyle.gapLarge
              wrapMode: Text.WordWrap
              horizontalAlignment: Text.AlignLeft
              text: service.agendaState === "loading" ? FoamyI18n.t("Loading events…")
                : service.agendaState === "error" || service.agendaState === "partial" ? root.agendaMessageText()
                : service.selectedCalendars > 0 ? FoamyI18n.t("No events on this date")
                : FoamyI18n.t("No calendars selected")
              color: service.agendaState === "error" ? Commons.Color.urgent : FoamyPalette.mutedText
              font.pixelSize: FoamyStyle.font.bodySmall
              Accessible.role: service.agendaState === "error" ? Accessible.AlertMessage : Accessible.StaticText
            }
            delegate: Rectangle {
              id: eventRow
              required property var modelData
              readonly property string agendaStatus: root.eventState(modelData)
              width: agendaScroll.width - (agendaScroll.interactive ? Style.space(10) : 0)
              height: Style.space(60)
              radius: FoamyStyle.radius
              color: eventMouse.containsMouse || agendaStatus === "ongoing" ? FoamyPalette.selectedFill : FoamyPalette.fieldFill
              Rectangle {
                anchors.left: parent.left; anchors.leftMargin: Style.space(11)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(3); height: parent.height - Style.space(22); radius: width / 2
                color: eventRow.modelData.color || Commons.Color.accent
              }
              ClockLabel {
                id: eventTime
                anchors.left: parent.left; anchors.leftMargin: Style.space(24)
                anchors.top: parent.top; anchors.topMargin: FoamyStyle.gapLarge
                width: Style.space(root.twelveHour ? 72 : 58)
                horizontalAlignment: Text.AlignLeft
                text: eventRow.modelData.allDay ? FoamyI18n.t("All day")
                  : root.displayLocale.toString(new Date(Number(eventRow.modelData.start) * 1000), root.timeFormat)
                color: FoamyPalette.secondaryText; font.pixelSize: FoamyStyle.font.bodySmall
                elide: Text.ElideRight
              }
              Column {
                anchors.left: eventTime.right; anchors.leftMargin: FoamyStyle.gap
                anchors.right: parent.right; anchors.rightMargin: Style.space(11)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(3)
                ClockLabel {
                  width: parent.width; elide: Text.ElideRight
                  horizontalAlignment: Text.AlignLeft
                  text: eventRow.modelData.title || FoamyI18n.t("Untitled event")
                  color: eventRow.agendaStatus === "past" ? FoamyPalette.secondaryText : FoamyPalette.text
                }
                ClockLabel {
                  width: parent.width; elide: Text.ElideRight
                  horizontalAlignment: Text.AlignLeft
                  text: eventRow.agendaStatus === "ongoing"
                    ? FoamyI18n.t("Now · %1", root.eventTimeText(eventRow.modelData) + " · " + root.eventDetails(eventRow.modelData))
                    : root.eventTimeText(eventRow.modelData) + " · " + root.eventDetails(eventRow.modelData)
                  color: FoamyPalette.secondaryText; font.pixelSize: FoamyStyle.font.bodySmall
                }
              }
              MouseArea {
                id: eventMouse
                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                onContainsMouseChanged: if (containsMouse) root.cursorKey = ""
                onClicked: root.calendarRequested()
              }
              PanelToolTip {
                visible: eventMouse.containsMouse
                text: (eventRow.modelData.title || FoamyI18n.t("Untitled event"))
                  + "\n" + root.eventTimeText(eventRow.modelData) + " · " + root.eventDetails(eventRow.modelData)
                fontFamily: FoamyStyle.fontFamily
              }
            }
          }
        }

        Column {
          id: footerBlock
          width: parent.width
          spacing: body.spacing
          Rectangle { width: parent.width; height: 1; color: FoamyPalette.divider }
          Item {
            width: parent.width; height: FoamyStyle.actionSize
            FoamyAction {
              id: openCalendarButton
              anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
              iconName: ""
              label: FoamyI18n.t("Calendar")
              foreground: FoamyPalette.secondaryText
              tooltipText: FoamyI18n.t("Open calendar")
              onClicked: root.calendarRequested()
              onHoveredChanged: if (hovered) root.cursorKey = ""
            }
            ClockLabel {
              id: updateStatus
              anchors.left: openCalendarButton.right; anchors.leftMargin: FoamyStyle.gapLarge
              anchors.right: refreshButton.left; anchors.rightMargin: Style.space(7)
              anchors.verticalCenter: parent.verticalCenter
              horizontalAlignment: Text.AlignRight; elide: Text.ElideRight
              text: root.launchError || (service.agendaEnabled ? root.updatedAgoText() : "")
              color: root.launchError ? Commons.Color.urgent : FoamyPalette.secondaryText
              font.pixelSize: FoamyStyle.font.bodySmall
              MouseArea {
                id: updateStatusMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: service.agendaState === "partial" ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: if (cursorShape === Qt.PointingHandCursor) root.calendarRequested()
              }
              PanelToolTip {
                visible: updateStatusMouse.containsMouse && updateStatus.text !== ""
                text: service.agendaState === "partial"
                  ? FoamyI18n.t("Some events may be missing. Open calendar for the full view.")
                  : updateStatus.text
                fontFamily: FoamyStyle.fontFamily
              }
            }
            FoamyAction {
              id: refreshButton
              visible: service.agendaEnabled
              anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
              iconName: "refresh-cw"
              foreground: FoamyPalette.secondaryText
              tooltipText: service.agendaLoading ? FoamyI18n.t("Refreshing calendars") : FoamyI18n.t("Refresh calendars")
              actionEnabled: !service.agendaLoading
              spinning: root.opened && !root.editingSettings && service.agendaLoading
              onClicked: service.refreshAgenda(true)
              onHoveredChanged: if (hovered) root.cursorKey = ""
            }
          }
          Item { width: 1; height: FoamyStyle.gapSmall }
        }
      }
    }
  }

  SettingsPane {
    id: settingsPage
    visible: root.editingSettings
    width: parent.width
    height: parent.height
    settings: root.settings
    saving: root.saving
    error: root.settingsError
    retryable: root.retryable && root.settingsError !== ""
    onBack: root.settingsClosed()
    onRetry: root.retryRequested()
    onSave: function(key, value) { root.saveRequested(key, value) }
  }
}
