import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import qs.Ui
import qs.Commons
import "Preferences.js" as Preferences
import "Model.js" as Model

Column {
  id: root
  required property var settings
  required property string language
  property bool saving: false
  property string error: ""
  property bool formatsOpen: false
  property alias backTarget: backButton
  signal save(string key, var value)
  signal back()
  signal clearError()
  function tr(text) { return Preferences.text(text, language) }
  function focusBack() { backButton.forceActiveFocus() }
  readonly property color secondaryForeground: Qt.tint(Color.popups.background, Qt.alpha(Color.popups.text, 0.7))
  spacing: Style.space(14)
  padding: Style.space(20)
  component Label: Text {
    color: Color.popups.text
    font.family: "sans-serif"
    font.pixelSize: Style.space(13)
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
  }
  RowLayout {
    width: parent.width - root.padding * 2
    ClockAction {
      id: backButton
      iconName: "arrow-left"
      tooltipText: root.tr("Back")
      foreground: root.secondaryForeground
      onClicked: root.back()
    }
    Label { text: root.tr("Settings"); Layout.fillWidth: true; color: root.secondaryForeground }
    Label { visible: root.saving; text: root.tr("Saving…"); font.pixelSize: Style.space(11); color: root.secondaryForeground }
  }
  Label {
    visible: root.error !== ""
    width: parent.width - root.padding * 2
    text: root.error
    color: Color.urgent
    Accessible.role: Accessible.AlertMessage
  }
  Repeater {
    model: [
      {title:"Display", keys:["language", "locale", "weekStartDay", "timeFormat", "showSeconds", "showTimeZone"]},
      {title:"Bar formats", keys:["format", "formatAlt", "verticalFormat", "verticalFormatAlt"]},
      {title:"Agenda", keys:["agendaEnabled", "agendaRefreshMinutes", "calendarApp", "showEventLocations"]}
    ]
    Column {
      id: group
      required property var modelData
      width: root.width - root.padding * 2
      spacing: Style.space(8)
      Label { visible: group.modelData.title !== "Bar formats"; text: root.tr(group.modelData.title); font.bold: true }
      ClockAction {
        visible: group.modelData.title === "Bar formats"
        label: root.tr("Bar formats")
        iconName: root.formatsOpen ? "chevron-down" : "chevron-right"
        foreground: root.secondaryForeground
        onClicked: root.formatsOpen = !root.formatsOpen
      }
      Repeater {
        model: group.modelData.keys
        Column {
          id: fieldRow
          required property string modelData
          readonly property var spec: Preferences.field(modelData)
          readonly property var current: Preferences.value(root.settings, modelData)
          readonly property bool hasPresets: modelData === "locale" || group.modelData.title === "Bar formats"
          // Custom is an editor mode, never a value written to shell.json.
          property bool customSelected: false
          readonly property var presetOptions: {
            if (modelData === "locale") return [
              {value:"", label:root.tr("System")},
              {value:"nb_NO", label:"Norsk bokmål"},
              {value:"nn_NO", label:"Norsk nynorsk"},
              {value:"en_GB", label:"English (UK)"},
              {value:"en_US", label:"English (US)"}
            ]
            if (!hasPresets) return []
            var vertical = modelData.indexOf("vertical") === 0
            var formats = Model.clockFormatRing(spec.defaultValue, "", Model.clockFormats(vertical))
            var locale = Qt.locale(Preferences.localeName(root.settings, Qt.locale().name))
            var example = new Date(2030, 8, 25, 14, 35, 42)
            return formats.map(function(format) {
              var preview = locale.toString(example, format.replace(/ww/g, Model.isoWeekLiteral(2030, 8, 25)))
              return {value:format, label:preview.replace(/\n/g, " · ")}
            })
          }
          readonly property bool customMode: customSelected || !presetOptions.some(function(o) { return o.value === fieldRow.current })
          width: group.width
          spacing: Style.space(5)
          visible: group.modelData.title === "Bar formats" ? root.formatsOpen
            : modelData === "agendaRefreshMinutes" || modelData === "showEventLocations" ? Preferences.value(root.settings, "agendaEnabled")
            : true
          enabled: !root.saving
          opacity: enabled ? 1 : 0.55
          Toggle {
            visible: fieldRow.spec.type === "boolean"
            width: parent.width
            implicitHeight: Style.space(36)
            color: "transparent"
            borderSpec: activeFocus ? Border.flat(Color.accent, 1) : Border.none()
            radius: Style.space(7)
            fontFamily: "sans-serif"
            titleSize: Style.space(13)
            label: root.tr(fieldRow.spec.label)
            checked: fieldRow.current === true
            onClicked: root.save(fieldRow.modelData, !checked)
          }
          ClockDropdown {
            visible: fieldRow.spec.type === "enum"
            width: parent.width
            fontFamily: "sans-serif"
            label: root.tr(fieldRow.spec.label)
            value: String(fieldRow.current)
            options: (fieldRow.spec.options || []).map(function(v) {
              return {value:v,label:(v === "system" || v === "locale") ? root.tr("System") : v === "nb" ? "Norsk bokmål" : v === "en" ? "English" : root.language === "en" ? v.charAt(0).toUpperCase() + v.slice(1) : root.tr(v)}
            })
            onChanged: function(value) { root.save(fieldRow.modelData, value) }
          }
          ClockDropdown {
            visible: fieldRow.hasPresets
            spaceClockIcon: fieldRow.modelData === "format" || fieldRow.modelData === "formatAlt"
            width: parent.width
            fontFamily: "sans-serif"
            label: root.tr(fieldRow.spec.label)
            value: fieldRow.customMode ? "__custom" : String(fieldRow.current)
            options: fieldRow.presetOptions.concat([{value:"__custom", label:root.tr("Custom")}])
            onChanged: function(value) {
              fieldRow.customSelected = value === "__custom"
              if (fieldRow.customSelected) {
                Qt.callLater(function() { textField.forceActiveFocus(); textField.selectAll() })
              } else if (value !== fieldRow.current) {
                root.save(fieldRow.modelData, value)
              }
            }
          }
          RowLayout {
            visible: fieldRow.spec.type === "integer"
            width: parent.width
            spacing: Style.space(12)
            Label { text: root.tr(fieldRow.spec.label); Layout.fillWidth: true }
            Controls.TextField {
              id: numberField
              Layout.preferredWidth: Style.space(78)
              implicitHeight: Style.space(34)
              text: String(fieldRow.current)
              placeholderTextColor: root.secondaryForeground
              selectByMouse: true
              color: Color.popups.text
              font.family: "sans-serif"
              font.pixelSize: Style.space(12)
              padding: Style.space(7)
              Accessible.name: root.tr(fieldRow.spec.label)
              background: Rectangle { radius: Style.space(7); color: Qt.alpha(Color.popups.text, 0.055); border.width: numberField.activeFocus ? 1 : 0; border.color: Color.accent }
              onTextEdited: root.clearError()
              onEditingFinished: {
                if (!visible) return
                var next = Preferences.parseValue(fieldRow.modelData, text)
                if (next !== fieldRow.current) root.save(fieldRow.modelData, next)
              }
              Keys.onEscapePressed: { text = String(fieldRow.current); root.back() }
              HoverHandler { id: numberHover }
              PanelToolTip {
                visible: numberHover.hovered || numberField.activeFocus
                text: fieldRow.spec.min + "–" + fieldRow.spec.max
                fontFamily: "sans-serif"
              }
            }
          }
          Label { visible: fieldRow.spec.type === "string" && !fieldRow.hasPresets; text: root.tr(fieldRow.spec.label); color: root.secondaryForeground; font.pixelSize: Style.space(12) }
          Controls.TextField {
            id: textField
            visible: fieldRow.spec.type === "string" && (!fieldRow.hasPresets || fieldRow.customMode)
            width: parent.width
            implicitHeight: Style.space(34)
            text: Preferences.displayValue(fieldRow.modelData, fieldRow.current)
            placeholderText: fieldRow.modelData === "locale" ? root.tr("System locale") : ""
            placeholderTextColor: root.secondaryForeground
            selectByMouse: true
            color: Color.popups.text
            font.family: "sans-serif"
            font.pixelSize: Style.space(12)
            padding: Style.space(8)
            Accessible.name: root.tr(fieldRow.spec.label)
            background: Rectangle { radius: Style.space(7); color: "transparent"; border.width: 1; border.color: textField.activeFocus ? Color.accent : Qt.alpha(Color.popups.text, 0.22) }
            onTextEdited: root.clearError()
            onEditingFinished: {
              if (!visible) return
              var next = Preferences.parseValue(fieldRow.modelData, text)
              if (next !== fieldRow.current) root.save(fieldRow.modelData, next)
            }
            Keys.onEscapePressed: { text = Preferences.displayValue(fieldRow.modelData, fieldRow.current); root.back() }
            HoverHandler { id: textHover }
            PanelToolTip {
              visible: fieldRow.modelData.indexOf("vertical") === 0 && (textHover.hovered || textField.activeFocus)
              text: root.tr("Use \\n for a line break")
              fontFamily: "sans-serif"
            }
          }
        }
      }
    }
  }
}
