// Load kit/FoamyPrefs.js (a QML `.pragma library` script) under node.
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const source = fs.readFileSync(path.join(__dirname, '../kit/FoamyPrefs.js'), 'utf8').replace(/^\.pragma library$/m, '')
const module_ = {exports: {}}
vm.runInNewContext(source, {module: module_, console})
module.exports = module_.exports
