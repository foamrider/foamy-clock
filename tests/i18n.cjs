// Exercise the real kit substitution and plural lookup (FoamyI18nText.js, which
// FoamyI18n calls) with the plugin catalogs in pure node tests.
const I18n = require('../kit/node-loader.cjs').load('FoamyI18nText')
const en = require('../i18n/en.json')
const no = require('../i18n/no.json')
const number = (value, decimals) => (decimals === undefined ? String(value) : Number(value).toFixed(decimals))
const scope = language => I18n.translator(language === 'no' || language === 'nb' ? no : en, en, number)
function text(key, language, values) { return scope(language).t(key, values) }
function plural(key, language, count, values) { return scope(language).tn(key, count, values) }
module.exports = {text, plural, no, en, norwegian: no, nb: no}
