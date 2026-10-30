// Settings schema for shell.json (mirrors manifest.json barWidget.schema),
// validated and saved through kit/FoamyPrefs.js. `pattern`/`maxLength` are
// the extra string rules FoamyPrefs enforces.
//
// Security: the calendarApp pattern is load-bearing. The app name reaches
// `omarchy-launch-or-focus`, which runs `eval exec setsid uwsm-app -- $1`, so
// it must stay a bare command name (no spaces, quotes, $, ;, / or leading -).
var fields = [
  {
    "key": "locale",
    "type": "string",
    "label": "Date locale",
    "defaultValue": "",
    "maxLength": 16,
    "pattern": "^(?:[a-z]{2,3}(?:_[A-Za-z]{2,4})?(?:_[A-Za-z]{2})?)?$"
  },
  {
    "key": "format",
    "type": "string",
    "label": "Bar format",
    "defaultValue": "ddd d MMM '' HH:mm",
    "maxLength": 200,
    "pattern": "^(?=[\\s\\S]*\\S)[^\\x00-\\x09\\x0b-\\x1f\\x7f]+$"
  },
  {
    "key": "formatAlt",
    "type": "string",
    "label": "Alternate format",
    "defaultValue": "d MMMM 'W'ww yyyy",
    "maxLength": 200,
    "pattern": "^(?=[\\s\\S]*\\S)[^\\x00-\\x09\\x0b-\\x1f\\x7f]+$"
  },
  {
    "key": "verticalFormat",
    "type": "string",
    "label": "Vertical format",
    "defaultValue": "HH\n—\nmm",
    "maxLength": 200,
    "pattern": "^(?=[\\s\\S]*\\S)[^\\x00-\\x09\\x0b-\\x1f\\x7f]+$"
  },
  {
    "key": "verticalFormatAlt",
    "type": "string",
    "label": "Vertical alternate",
    "defaultValue": "dd\nMMM\n'W'ww\n''yy",
    "maxLength": 200,
    "pattern": "^(?=[\\s\\S]*\\S)[^\\x00-\\x09\\x0b-\\x1f\\x7f]+$"
  },
  {
    "key": "weekStartDay",
    "type": "enum",
    "label": "Week starts on",
    "defaultValue": "locale",
    "options": [
      "locale",
      "monday",
      "tuesday",
      "wednesday",
      "thursday",
      "friday",
      "saturday",
      "sunday"
    ]
  },
  {
    "key": "timeFormat",
    "type": "enum",
    "label": "Time format",
    "defaultValue": "24-hour",
    "options": [
      "24-hour",
      "12-hour"
    ]
  },
  {
    "key": "showSeconds",
    "type": "boolean",
    "label": "Show seconds in the popup",
    "defaultValue": true
  },
  {
    "key": "showTimeZone",
    "type": "boolean",
    "label": "Show timezone in the popup",
    "defaultValue": true
  },
  {
    "key": "agendaEnabled",
    "type": "boolean",
    "label": "Show agenda",
    "defaultValue": true
  },
  {
    "key": "agendaRefreshMinutes",
    "type": "integer",
    "label": "Refresh every",
    "defaultValue": 30,
    "min": 1,
    "max": 1440,
    "step": 1
  },
  {
    "key": "calendarApp",
    "type": "string",
    "label": "Calendar app",
    "defaultValue": "gnome-calendar",
    "maxLength": 200,
    "pattern": "^[A-Za-z0-9][A-Za-z0-9._+-]*$"
  },
  {
    "key": "showEventLocations",
    "type": "boolean",
    "label": "Show event locations",
    "defaultValue": true
  }
]

// Validation and defaults: kit/FoamyPrefs.js (Prefs.value(Schema.fields, settings, key)).
function field(key) {
  for (var i = 0; i < fields.length; i++) if (fields[i].key === key) return fields[i]
  return null
}

function localeName(configured, systemLocale) { return configured || systemLocale }
function displayValue(key, value) { return String(value).replace(/\n/g, "\\n") }
function parseValue(key, text) {
  var spec = field(key)
  if (spec && spec.type === "integer") return text.trim() === "" ? NaN : Number(text)
  return text.replace(/\\n/g, "\n").trim()
}

// "Refresh every" presets in minutes; a stored custom value is offered too.
var REFRESH_PRESETS = [5, 10, 15, 30, 60, 120, 240, 720, 1440]
function refreshOptions(current) {
  var values = REFRESH_PRESETS.slice()
  if (values.indexOf(current) < 0 && Number.isInteger(current) && current >= 1 && current <= 1440) values.push(current)
  return values.sort(function(a, b) { return a - b })
}

if (typeof module !== "undefined") module.exports = {fields:fields, field:field,
    localeName:localeName, displayValue:displayValue, parseValue:parseValue, refreshOptions:refreshOptions, REFRESH_PRESETS:REFRESH_PRESETS}
