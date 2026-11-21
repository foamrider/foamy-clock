const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const I = require('./i18n.cjs');
const F = require('../kit/node-loader.cjs').load('FoamyPrefs');
const manifest = require('../manifest.json');
const root = path.join(__dirname, '..');
const tokens = s => [...String(s).matchAll(/%[1-9][0-9]*|\{\w+\}/g)].map(m => m[0]).sort();
const forms = v => typeof v === 'object' ? Object.values(v) : [v];
for (const [key, value] of Object.entries(I.en)) {
  // English is keyed by its own text; plural entries carry the key as "other".
  assert.equal(typeof value === 'object' ? value.other : value, key, `English source key: ${key}`);
  assert.ok(Object.hasOwn(I.no, key), `Norwegian entry for ${key}`);
  for (const form of forms(I.no[key])) assert.deepEqual(tokens(form), tokens(key), key);
  assert.equal(typeof I.no[key], typeof value, `same shape: ${key}`);
}
// Date patterns come from the catalogs, not from code.
assert.equal(I.text('dddd, MMMM d', 'no'), 'dddd d. MMMM');
// Every string the plugin's QML asks for has a catalog entry: each QML file of the
// plugin, and the kit's FoamyI18n, whose updatedAgo keys the plugin catalogs carry.
const calls = /\b(t|tn|tr)\(\s*"((?:[^"\\]|\\.)*)"/g;
const keys = code => [...code.matchAll(calls)].map(m => ({fn: m[1], key: JSON.parse(`"${m[2]}"`)}));
const plugin = fs.readdirSync(root).filter(f => f.endsWith('.qml')).flatMap(f => keys(fs.readFileSync(path.join(root, f), 'utf8')));
const kitCode = fs.readFileSync(path.join(root, 'kit', 'FoamyI18n.qml'), 'utf8').split('\n').filter(l => !l.trim().startsWith('//')).join('\n');
const kit = keys(kitCode);
assert.ok(kit.some(k => k.fn === 'tn'), 'kit/FoamyI18n.qml: no tn() key found, the scan is stale');
for (const {key} of [...plugin, ...kit]) assert.ok(Object.hasOwn(I.en, key), `catalog entry for ${key}`);
// A key used with tn() is a plural entry in both catalogs.
for (const {fn, key} of [...plugin, ...kit]) {
  if (fn !== 'tn') continue;
  for (const [name, catalog] of [['en', I.en], ['no', I.no]]) {
    const entry = catalog[key];
    assert.ok(entry && typeof entry.one === 'string' && typeof entry.other === 'string', `${name} plural entry for ${key}`);
  }
}
// The widget shows FoamyPrefs errors through tr(prefs.error).
for (const message of [F.NOT_ALLOWED, F.NO_ENTRY]) assert.ok(Object.hasOwn(I.no, message), `Norwegian entry for ${message}`);
for (const f of manifest.barWidget.schema) assert.ok(Object.hasOwn(I.no, f.label), f.label);
console.log('ok — catalogs, plural entries, date patterns and every QML string');
