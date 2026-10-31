// Exercise the real kit FoamyI18n substitution and plural lookup with the
// plugin catalogs in pure node tests (a 4.5-like backend over i18n/*.json).
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const source = fs.readFileSync(path.join(__dirname, '../kit/FoamyI18n.qml'), 'utf8')
const start = source.indexOf('  function englishText(')
const end = source.lastIndexOf('}')
const scope = vm.createContext({backend: null, english: {}, root: null})
vm.runInContext(source.slice(start, end), scope)
scope.root = scope
const en = require('../i18n/en.json')
const no = require('../i18n/no.json')
const pick = (value, count) => value && typeof value === 'object' ? (Math.abs(count) === 1 ? value.one : value.other) : value
function use(language) {
  const catalog = language === 'no' || language === 'nb' ? no : en
  scope.backend = {
    t(label, fallback) { const v = Object.hasOwn(catalog, label) ? catalog[label] : undefined; return typeof v === 'object' ? v.other : v || fallback },
    tn(label, count, fallback) { return pick(Object.hasOwn(catalog, label) ? catalog[label] : undefined, count) || pick(en[label], count) || fallback },
    number: (value) => String(value)
  }
}
function text(key, language, values) { use(language); return scope.t(key, values) }
function plural(key, language, count, values) { use(language); return scope.tn(key, count, values) }
module.exports = {text, plural, no, en, norwegian: no, nb: no}
