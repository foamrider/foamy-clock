const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const I = require('./i18n.cjs');
const manifest = require('../manifest.json');
const tokens = s => [...String(s).matchAll(/%[1-9][0-9]*|\{\w+\}/g)].map(m => m[0]).sort();
const forms = v => typeof v === 'object' ? Object.values(v) : [v];
for (const [key, value] of Object.entries(I.en)) {
  // English is keyed by its own text; plural entries carry the key as "other".
  assert.equal(typeof value === 'object' ? value.other : value, key, `English source key: ${key}`);
  assert.ok(Object.hasOwn(I.no, key), `Norwegian entry for ${key}`);
  for (const form of forms(I.no[key])) assert.deepEqual(tokens(form), tokens(key), key);
  assert.equal(typeof I.no[key], typeof value, `same shape: ${key}`);
}
assert.equal(manifest.barWidget?.defaults?.language, undefined);
assert.equal((manifest.barWidget?.schema || []).some(f => f.key === 'language'), false);
assert.equal(I.text('Unknown %1 {name}', 'no', ['$& %2']), 'Unknown $& %2 {name}');
assert.equal(I.text('constructor', 'no'), 'constructor');
assert.equal(I.plural('%1 events', 'en', 1), '1 event');
assert.equal(I.plural('%1 events', 'en', 3), '3 events');
assert.equal(I.plural('%1 events', 'no', 1), '1 avtale');
assert.equal(I.plural('Updated %1 minutes ago', 'no', 5), 'Oppdatert for 5 minutter siden');
// Date patterns come from the catalogs, not from code.
assert.equal(I.text('dddd, MMMM d', 'no'), 'dddd d. MMMM');
// Every string the plugin's QML asks for has a catalog entry.
const code = ['BarWidget.qml', 'ClockPanel.qml', 'ClockView.qml', 'SettingsPane.qml'].map(f => fs.readFileSync(path.join(__dirname, '..', f), 'utf8')).join('\n');
for (const m of code.matchAll(/\b(?:t|tn|tr)\(\s*"((?:[^"\\]|\\.)*)"/g)) assert.ok(Object.hasOwn(I.en, JSON.parse(`"${m[1]}"`)), `catalog entry for ${m[1]}`);
for (const f of manifest.barWidget.schema) assert.ok(Object.hasOwn(I.no, f.label), f.label);
// No hard-coded date patterns or trailing-space keys in the view.
assert.equal(/toString\([^)]*"dddd d\. MMMM"/.test(code), false);
assert.equal(/t\("[^"]* "\)|t\(" [^"]*"\)/.test(code), false);
console.log('ok — catalogs, plurals, date patterns and literal parameters');
