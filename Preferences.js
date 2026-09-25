// Shared validation and translations for shell.json settings.
var fields = [
  {
    "key": "language",
    "type": "enum",
    "label": "Language",
    "defaultValue": "system",
    "options": [
      "system",
      "nb",
      "en"
    ]
  },
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
var norwegian = {
  "Language": "Språk",
  "Date locale": "Datoformat (språk/region)",
  "Bar format": "Format i linjen",
  "Alternate format": "Alternativt format",
  "Vertical format": "Vertikalt format",
  "Vertical alternate": "Vertikalt alternativ",
  "Week starts on": "Uken starter på",
  "Time format": "Tidsformat",
  "Show seconds": "Vis sekunder",
  "Show timezone": "Vis tidssone",
  "Show agenda": "Vis avtaler",
  "Refresh interval (min)": "Oppdateringsintervall (min)",
  "Calendar app": "Kalenderapp",
  "Show event locations": "Vis avtalesteder",
  "Settings": "Innstillinger",
  "Back": "Tilbake",
  "Display": "Visning",
  "Bar formats": "Formater i linjen",
  "Agenda": "Avtaler",
  "System": "System",
  "Custom": "Egendefinert",
  "System locale": "Systemets språk/region",
  "24-hour": "24-timers",
  "12-hour": "12-timers",
  "locale": "System",
  "monday": "Mandag",
  "tuesday": "Tirsdag",
  "wednesday": "Onsdag",
  "thursday": "Torsdag",
  "friday": "Fredag",
  "saturday": "Lørdag",
  "sunday": "Søndag",
  "Saving…": "Lagrer…",
  "Could not save settings.": "Kunne ikke lagre innstillingene.",
  "Invalid setting.": "Ugyldig innstilling.",
  "Calendar app could not be started.": "Kalenderappen kunne ikke startes.",
  "Right-click to change format": "Høyreklikk for å endre format",
  "Use \\n for a line break": "Bruk \\n for linjeskift",
  "Could not query calendars. Check Python and Evolution Data Server.": "Kunne ikke hente kalendere. Kontroller Python og Evolution Data Server."
}
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
function language(mode, systemLocale) {
  if (mode === "en" || mode === "nb") return mode
  return /^(nb|nn|no)(_|-|$)/i.test(String(systemLocale || "")) ? "nb" : "en"
}
function text(label, lang) { return lang === "nb" ? (norwegian[label] || label) : label }
function localeName(settings, systemLocale) { return value(settings, "locale") || systemLocale }
function displayValue(key, value) { return String(value).replace(/\n/g, "\\n") }
function parseValue(key, text) {
  var spec = field(key)
  if (spec && spec.type === "integer") return text.trim() === "" ? NaN : Number(text)
  return text.replace(/\\n/g, "\n").trim()
}
if (typeof module !== "undefined") module.exports = {fields:fields, field:field, valid:valid, value:value,
  language:language, text:text, localeName:localeName, displayValue:displayValue, parseValue:parseValue}
