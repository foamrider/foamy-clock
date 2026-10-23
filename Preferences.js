// Shared validation and translations for shell.json settings.
var fields = [
  {
    "key": "locale",
    "type": "string",
    "label": "Date locale",
    "defaultValue": ""
  },
  {
    "key": "format",
    "type": "string",
    "label": "Bar format",
    "defaultValue": "ddd d MMM '' HH:mm"
  },
  {
    "key": "formatAlt",
    "type": "string",
    "label": "Alternate format",
    "defaultValue": "d MMMM 'W'ww yyyy"
  },
  {
    "key": "verticalFormat",
    "type": "string",
    "label": "Vertical format",
    "defaultValue": "HH\n—\nmm"
  },
  {
    "key": "verticalFormatAlt",
    "type": "string",
    "label": "Vertical alternate",
    "defaultValue": "dd\nMMM\n'W'ww\n''yy"
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
    "label": "Show seconds",
    "defaultValue": true
  },
  {
    "key": "showTimeZone",
    "type": "boolean",
    "label": "Show timezone",
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
    "label": "Refresh interval (min)",
    "defaultValue": 30,
    "min": 1,
    "max": 1440,
    "step": 1
  },
  {
    "key": "calendarApp",
    "type": "string",
    "label": "Calendar app",
    "defaultValue": "gnome-calendar"
  },
  {
    "key": "showEventLocations",
    "type": "boolean",
    "label": "Show event locations",
    "defaultValue": true
  }
]

function field(key) {
  for (var i = 0; i < fields.length; i++) if (fields[i].key === key) return fields[i]
  return null
}
function valid(key, value) {
  var spec = field(key)
  if (!spec) return false
  if (spec.type === "boolean") return typeof value === "boolean"
  if (spec.type === "integer") {
    if (typeof value !== "number" || !isFinite(value) || Math.floor(value) !== value || value < spec.min || value > spec.max) return false
    return true
  }
  if (spec.type === "enum") return spec.options.indexOf(value) !== -1
  if (typeof value !== "string" || value.length > 200) return false
  if (key === "locale") return value === "" || /^[a-z]{2,3}(?:_[A-Za-z]{2,4})?(?:_[A-Za-z]{2})?$/.test(value)
  if (key === "calendarApp") return /^[A-Za-z0-9][A-Za-z0-9._+-]*$/.test(value)
  return value.trim().length > 0 && !/[\x00-\x09\x0b-\x1f\x7f]/.test(value)
}
function value(settings, key) {
  var spec = field(key)
  return spec ? (settings && valid(key, settings[key]) ? settings[key] : spec.defaultValue) : undefined
}

function localeName(settings, systemLocale) { return value(settings, "locale") || systemLocale }
function displayValue(key, value) { return String(value).replace(/\n/g, "\\n") }
function parseValue(key, text) {
  var spec = field(key)
  if (spec && spec.type === "integer") return text.trim() === "" ? NaN : Number(text)
  return text.replace(/\\n/g, "\n").trim()
}
if (typeof module !== "undefined") module.exports = {fields:fields, field:field, valid:valid, value:value,
    localeName:localeName, displayValue:displayValue, parseValue:parseValue}
