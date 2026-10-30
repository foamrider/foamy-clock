const I18n = require('./i18n.cjs');
const assert = require('node:assert/strict')
const P = require('../Preferences.js')
const F = require('../kit/node-loader.cjs').load('FoamyPrefs')
const M = require('../Model.js')
const manifest = require('../manifest.json')
const strip = f => Object.fromEntries(Object.entries(f).filter(([k]) => k !== 'pattern' && k !== 'maxLength'))
for (const f of P.fields) {
  assert.ok(F.valid(P.fields, f.key, f.defaultValue), f.key)
  assert.deepEqual(strip(f), manifest.barWidget.schema.find(s => s.key === f.key))
  assert.equal(F.value(P.fields, {}, f.key), manifest.barWidget.defaults[f.key])
  assert.equal(F.valid(P.fields, f.key, null), false)
  assert.notEqual(I18n.text(f.label, 'nb'), f.label)
}
assert.equal(P.localeName('', 'en_GB'), 'en_GB')
assert.equal(P.localeName('nb_NO', 'en_GB'), 'nb_NO')
// calendarApp reaches an eval in omarchy-launch-or-focus: bare names only.
for (const v of ['--help','app;pwd','$(pwd)','app\nname','/usr/bin/app','', 'a b', "a'b"]) assert.equal(F.valid(P.fields, 'calendarApp',v),false, v)
for (const v of ['gnome-calendar','org.gnome.Calendar','evolution']) assert.equal(F.valid(P.fields, 'calendarApp',v),true)
for (const v of [0,1441,1.5,NaN,'30']) assert.equal(F.valid(P.fields, 'agendaRefreshMinutes',v),false)
assert.ok(Number.isNaN(P.parseValue('agendaRefreshMinutes','')))
const format="HH\nmm\n's'"
assert.equal(P.parseValue('verticalFormat',P.displayValue('verticalFormat',format)),format)
assert.ok(F.valid(P.fields, 'verticalFormat', format))
assert.equal(F.valid(P.fields, 'format','HH\x00mm'),false)
assert.equal(F.valid(P.fields, 'format','   '),false)
assert.equal(F.valid(P.fields, 'format','x'.repeat(201)),false)
assert.equal(F.valid(P.fields, 'unknown','x'),false)
for (const key of ['birthYear','lifeExpectancy']) {
  assert.equal(P.field(key),null)
  assert.equal(Object.hasOwn(manifest.barWidget.defaults,key),false)
}
for (const locale of ['', 'nb_NO', 'nn_NO', 'en_GB', 'en_US', 'de_DE']) assert.ok(F.valid(P.fields, 'locale',locale))
assert.equal(F.valid(P.fields, 'locale', 'en_US; rm'), false)
// Refresh presets keep a stored custom value selectable.
assert.deepEqual(P.refreshOptions(30), P.REFRESH_PRESETS)
assert.ok(P.refreshOptions(45).includes(45))
assert.equal(P.refreshOptions(5000).includes(5000), false)
// Settings save through FoamyPrefs: inline when allowed, else `omarchy bar set`.
const settings = {format: 'HH:mm', showSeconds: true}
let inline = null
const bar = {shell: {updateEntryInline: (id, next) => { inline = [id, next]; return true }}}
const saved = F.save(bar, 'foamy.clock', P.fields, settings, 'showSeconds', false)
assert.equal(saved.inline, true)
assert.equal(JSON.stringify(inline), JSON.stringify(['foamy.clock', {format: 'HH:mm', showSeconds: false}]))
const cli = F.save({shell: {updateEntryInline: () => false}}, 'foamy.clock', P.fields, settings, 'format', 'HH:mm:ss')
assert.equal(JSON.stringify(cli.command), JSON.stringify(['omarchy', 'bar', 'set', 'foamy.clock', 'format', '"HH:mm:ss"', '--json']))
assert.equal(F.save(bar, 'foamy.clock', P.fields, settings, 'calendarApp', 'x;y').ok, false)
// Date patterns derived from a locale drop the year (4.0 / chosen date locale).
assert.equal(M.dateWithoutYear('dddd d. MMMM yyyy'), 'dddd d. MMMM')
assert.equal(M.dateWithoutYear('dddd, MMMM d, yyyy'), 'dddd, MMMM d')
assert.equal(M.dateWithoutYear('yyyy年M月d日dddd'), 'M月d日dddd')
assert.equal(M.dateWithoutYear("dddd 'yy' d MMMM yyyy"), "dddd 'yy' d MMMM")
assert.equal(M.abbreviatedDate('dddd d. MMMM'), 'ddd d. MMM')
console.log('ok — schema defaults, translations, validation, saving and format round trips')
