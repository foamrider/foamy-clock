const assert = require('node:assert/strict')
const P = require('../Preferences.js')
const manifest = require('../manifest.json')
for (const f of P.fields) {
  assert.ok(P.valid(f.key, f.defaultValue), f.key)
  assert.deepEqual(f, manifest.barWidget.schema.find(s => s.key === f.key))
  assert.equal(P.value({}, f.key), manifest.barWidget.defaults[f.key])
  assert.equal(P.valid(f.key, null), false)
  assert.notEqual(P.text(f.label, 'nb'), f.label)
}
assert.equal(P.localeName({}, 'en_GB'), 'en_GB')
assert.equal(P.localeName({locale:'nb_NO'}, 'en_GB'), 'nb_NO')
assert.equal(P.language('system','nb_NO'),'nb')
assert.equal(P.language('en','nb_NO'),'en')
assert.equal(P.language('system','fr_FR'),'en')
for (const v of ['--help','app;pwd','$(pwd)','app\nname','/usr/bin/app','']) assert.equal(P.valid('calendarApp',v),false)
for (const v of ['gnome-calendar','org.gnome.Calendar','evolution']) assert.equal(P.valid('calendarApp',v),true)
for (const v of [0,1441,1.5,NaN,'30']) assert.equal(P.valid('agendaRefreshMinutes',v),false)
assert.ok(Number.isNaN(P.parseValue('agendaRefreshMinutes','')))
const format="HH\nmm\n's'"
assert.equal(P.parseValue('verticalFormat',P.displayValue('verticalFormat',format)),format)
assert.equal(P.valid('format','HH\x00mm'),false)
assert.equal(P.valid('unknown','x'),false)
for (const key of ['birthYear','lifeExpectancy']) {
  assert.equal(P.field(key),null)
  assert.equal(Object.hasOwn(manifest.barWidget.defaults,key),false)
}
for (const locale of ['', 'nb_NO', 'nn_NO', 'en_GB', 'en_US', 'de_DE']) assert.ok(P.valid('locale',locale))
console.log('ok — schema defaults, translations, validation and format round trips')
