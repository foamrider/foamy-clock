import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "kit"
import "kit/FoamyPrefs.js" as Prefs
import "Model.js" as Model
import "Preferences.js" as Schema

// The clock's settings, on the shared foamy settings page. Every change
// saves at once through save(key, value) (BarWidget queues the writes).
FoamySettingsPage {
  id: root

  property var settings: ({})
  property bool formatsOpen: false
  signal save(string key, var value)

  function current(key) { return Prefs.value(Schema.fields, root.settings, key) }
  function label(key) { return FoamyI18n.t(Schema.field(key).label) }
  // "" follows the Omarchy language's date locale on 4.5, the system on 4.0.
  readonly property string followLabel: FoamyI18n.translationsAvailable ? FoamyI18n.t("Omarchy language") : FoamyI18n.t("System")
  readonly property var dateLocale: Qt.locale(Schema.localeName(root.current("locale"), FoamyI18n.formatLocale))

  function formatOptions(key) {
    var vertical = key.indexOf("vertical") === 0
    var formats = Model.clockFormatRing(Schema.field(key).defaultValue, "", Model.clockFormats(vertical))
    var example = new Date(2030, 8, 25, 14, 35, 42)
    return formats.map(function(format) {
      var preview = root.dateLocale.toString(example, format.replace(/ww/g, Model.isoWeekLiteral(2030, 8, 25)))
      return {value: format, label: preview.replace(/\n/g, " · ")}
    })
  }

  // A preset dropdown with a "Custom" editor mode (never a stored value).
  component PresetField: Column {
    id: field
    required property string key
    property var presets: []
    property bool glyphLabels: false
    property string placeholder: ""
    property string hint: ""
    property bool customSelected: false
    readonly property var value: root.current(key)
    readonly property bool customMode: customSelected || !presets.some(function(o) { return o.value === field.value })
    width: parent ? parent.width : 0
    spacing: FoamyStyle.gapSmall

    FoamyDropdown {
      width: parent.width
      label: root.label(field.key)
      labelDelegate: field.glyphLabels ? glyphLabel : null
      value: field.customMode ? "__custom" : String(field.value)
      options: field.presets.concat([{value: "__custom", label: FoamyI18n.t("Custom")}])
      onChanged: function(next) {
        field.customSelected = next === "__custom"
        if (field.customSelected) Qt.callLater(function() { editor.focusInput(); editor.selectAll() })
        else if (next !== field.value) root.save(field.key, next)
      }
    }
    SafeTextField {
      id: editor
      visible: field.customMode
      width: parent.width
      text: Schema.displayValue(field.key, field.value)
      placeholderText: field.placeholder
      translate: FoamyI18n.t
      onEditingFinished: {
        if (!visible) return
        var next = Schema.parseValue(field.key, text)
        if (next !== field.value) root.save(field.key, next)
      }
    }
    Text {
      visible: field.customMode && field.hint !== ""
      width: parent.width
      text: field.hint
      textFormat: Text.PlainText
      horizontalAlignment: Text.AlignLeft
      wrapMode: Text.WordWrap
      color: FoamyPalette.mutedText
      font.family: FoamyStyle.fontFamily
      font.pixelSize: FoamyStyle.font.caption
    }
  }

  Component { id: glyphLabel; ClockFormatLabel {} }

  FoamySettingsSection {
    width: parent.width
    title: FoamyI18n.t("Display")
    enabled: !root.saving

    PresetField {
      key: "locale"
      presets: [
        {value: "", label: root.followLabel},
        {value: "nb_NO", label: "Norsk bokmål"},
        {value: "nn_NO", label: "Norsk nynorsk"},
        {value: "en_GB", label: "English (UK)"},
        {value: "en_US", label: "English (US)"}
      ]
      placeholder: FoamyI18n.t("Locale code, e.g. de_DE")
    }
    FoamyDropdown {
      width: parent.width
      label: root.label("weekStartDay")
      value: String(root.current("weekStartDay"))
      // Options are locale, monday … sunday; index % 7 is Locale.Monday … Locale.Sunday (0).
      options: Schema.field("weekStartDay").options.map(function(day, index) {
        if (day === "locale") return {value: day, label: FoamyI18n.t("Date locale default")}
        return {value: day, label: root.dateLocale.standaloneDayName(index % 7, Locale.LongFormat)}
      })
      onChanged: function(next) { root.save("weekStartDay", next) }
    }
    FoamyDropdown {
      width: parent.width
      label: root.label("timeFormat")
      value: String(root.current("timeFormat"))
      options: [{value: "24-hour", label: FoamyI18n.t("24-hour")}, {value: "12-hour", label: FoamyI18n.t("12-hour")}]
      onChanged: function(next) { root.save("timeFormat", next) }
    }
    FoamyToggle {
      width: parent.width
      label: root.label("showSeconds")
      description: FoamyI18n.t("The bar shows seconds when its format has them")
      checked: root.current("showSeconds") === true
      onClicked: root.save("showSeconds", !checked)
    }
    FoamyToggle {
      width: parent.width
      label: root.label("showTimeZone")
      checked: root.current("showTimeZone") === true
      onClicked: root.save("showTimeZone", !checked)
    }
  }

  FoamySettingsSection {
    width: parent.width
    enabled: !root.saving

    FoamyAction {
      iconName: root.formatsOpen ? "chevron-down" : "chevron-right"
      label: FoamyI18n.t("Bar formats")
      foreground: FoamyPalette.secondaryText
      focusable: true
      onClicked: root.formatsOpen = !root.formatsOpen
    }
    Repeater {
      model: root.formatsOpen ? ["format", "formatAlt", "verticalFormat", "verticalFormatAlt"] : []
      PresetField {
        required property string modelData
        key: modelData
        presets: root.formatOptions(modelData)
        glyphLabels: modelData === "format" || modelData === "formatAlt"
        hint: modelData.indexOf("vertical") === 0 ? FoamyI18n.t("Use \\n for a line break") : ""
      }
    }
  }

  FoamySettingsSection {
    width: parent.width
    title: FoamyI18n.t("Agenda")
    enabled: !root.saving

    FoamyToggle {
      width: parent.width
      label: root.label("agendaEnabled")
      checked: root.current("agendaEnabled") === true
      onClicked: root.save("agendaEnabled", !checked)
    }
    FoamyDropdown {
      visible: root.current("agendaEnabled") === true
      width: parent.width
      label: root.label("agendaRefreshMinutes")
      value: String(root.current("agendaRefreshMinutes"))
      options: Schema.refreshOptions(root.current("agendaRefreshMinutes")).map(function(minutes) {
        return {value: String(minutes), label: minutes % 60 === 0
          ? FoamyI18n.tn("%1 hours", minutes / 60) : FoamyI18n.tn("%1 minutes", minutes)}
      })
      onChanged: function(next) { root.save("agendaRefreshMinutes", Number(next)) }
    }
    Column {
      width: parent.width
      spacing: FoamyStyle.gapSmall
      Text {
        width: parent.width
        text: root.label("calendarApp")
        textFormat: Text.PlainText
        horizontalAlignment: Text.AlignLeft
        color: FoamyPalette.secondaryText
        font.family: FoamyStyle.fontFamily
        font.pixelSize: FoamyStyle.font.bodySmall
        font.bold: true
      }
      SafeTextField {
        width: parent.width
        text: String(root.current("calendarApp"))
        placeholderText: "gnome-calendar"
        translate: FoamyI18n.t
        onEditingFinished: {
          var next = text.trim()
          if (next !== root.current("calendarApp")) root.save("calendarApp", next)
        }
      }
    }
    FoamyToggle {
      visible: root.current("agendaEnabled") === true
      width: parent.width
      label: root.label("showEventLocations")
      checked: root.current("showEventLocations") === true
      onClicked: root.save("showEventLocations", !checked)
    }
  }
}
