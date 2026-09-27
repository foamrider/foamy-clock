const assert = require('node:assert/strict')
const fs = require('node:fs')
const vm = require('node:vm')
const path = require('node:path')

// Exercise the functions used by the actual QML bindings, including results
// that arrive after navigation, without starting a graphical shell.
const panel = fs.readFileSync(path.join(__dirname, '..', 'Panel.qml'), 'utf8')
const apply = panel.slice(panel.indexOf('  function applyAgendaPayload('), panel.indexOf('  function dotsForDate('))
const status = panel.slice(panel.indexOf('  function updatedAgoText()'), panel.indexOf('  function eventState('))
const root = {
  agendaEnabled: true, selectedDateKey: '2026-09-27',
  agendaRangeStartKey: '2026-08-31', agendaRangeEndKey: '2026-10-12',
  agendaEvents: [], calendarDates: {}, agendaState: 'ok', overviewState: 'ok',
  lastAgendaRefreshMs: Date.now(), now: new Date()
}
const context = vm.createContext({ root, localText: (_nb, en) => en })
vm.runInContext(apply + status, context)
const day = { kind: 'day', date: root.selectedDateKey, state: 'partial', events: [{title: 'Retained event'}], selectedCalendars: 1, updatedAt: 123456, cached: true }
const applyDay = payload => context.applyAgendaPayload(JSON.stringify(payload), false, root.selectedDateKey, root.agendaRangeStartKey, root.agendaRangeEndKey)
assert.equal(applyDay(day), true)
assert.equal(root.agendaState, 'partial')
assert.equal(root.agendaCached, true)
assert.equal(context.updatedAgoText(), 'Partial update · open calendar')
assert.equal(applyDay({...day, date: '2026-09-26'}), false)
assert.equal(root.agendaEvents[0].title, 'Retained event')
assert.equal(applyDay({...day, events: Array(101).fill({})}), false)
assert.equal(context.applyAgendaPayload('x'.repeat(262145)), false)
root.agendaEnabled = false
assert.equal(applyDay(day), false)
root.agendaEnabled = true
const grid = { kind: 'grid', date: root.agendaRangeStartKey, rangeEnd: root.agendaRangeEndKey, state: 'partial', dates: {'2026-09-27': [{id: 'work', color: ''}]} }
applyDay(grid)
assert.equal(root.overviewState, 'partial')
assert.equal(root.calendarDates['2026-09-27'].length, 1)
applyDay({...grid, date: '2026-07-27', dates: {}})
assert.equal(root.calendarDates['2026-09-27'].length, 1)
root.agendaState = 'ok'
assert.equal(context.updatedAgoText(), 'Partial update · open calendar')
root.overviewState = 'ok'
root.agendaState = 'error'
assert.equal(context.updatedAgoText(), 'Calendar unavailable')
root.agendaState = 'loading'
assert.equal(context.updatedAgoText(), 'Updating…')
root.agendaState = 'ok'
root.lastAgendaRefreshMs = root.now.getTime()
assert.equal(context.updatedAgoText(), 'Updated just now')
console.log('ok — partial status, cached fallback, stale results, and payload limits')

const processStart = panel.indexOf('    id: agendaProcess')
const finishStart = panel.indexOf('    onExited: function(exitCode)', processStart)
const finishEnd = panel.indexOf('\n  }\n\n  Timer {', finishStart)
const finish = panel.slice(finishStart, finishEnd).replace('onExited: function(exitCode)', 'function finished(exitCode)')
let queued = 0
context.Qt = { callLater: () => { queued++ } }
Object.assign(root, {
  agendaProcessDateKey: root.selectedDateKey, agendaDateKey: root.selectedDateKey,
  agendaProcessRangeStartKey: root.agendaRangeStartKey,
  agendaProcessRangeEndKey: root.agendaRangeEndKey,
  agendaRangeKey: root.agendaRangeStartKey + ':' + root.agendaRangeEndKey,
  agendaPayloadApplied: false, agendaOverviewApplied: false,
  lastAgendaRangeRefreshMs: 0, agendaEvents: []
})
vm.runInContext(finish, context)
context.finished(0)
assert.equal(root.lastAgendaRangeRefreshMs, 0)
assert.equal(root.agendaState, 'error')
root.agendaDateKey = '' // A quick disable/re-enable cleared the selected view.
context.finished(0)
assert.equal(queued, 1)
assert.equal(root.lastAgendaRangeRefreshMs, 0)

const refresh = panel.slice(panel.indexOf('  function refreshAgenda(force)'), panel.indexOf('  function applyAgendaPayload('))
context.cacheProcess = { running: false }
context.agendaProcess = { running: false }
Object.assign(root, {
  agendaDateKey: root.selectedDateKey, lastAgendaDateKey: root.selectedDateKey,
  lastAgendaRangeKey: root.agendaRangeKey, lastAgendaRangeRefreshMs: Date.now(),
  lastAgendaRefreshMs: 0, agendaRefreshIntervalMs: 1800000
})
vm.runInContext(refresh, context)
context.refreshAgenda(false)
assert.equal(context.agendaProcess.running, true) // A cache miss must always recover.
console.log('ok — interrupted refreshes do not suppress replacement requests')
