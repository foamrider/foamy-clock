const assert = require('node:assert/strict')
const fs = require('node:fs')
const vm = require('node:vm')
const path = require('node:path')
const Model = require('../Model.js')

// Run the actual QML request and selection functions against a loaded month.
// A warm day click must neither start a process nor cancel the month refresh.
const panel = fs.readFileSync(path.join(__dirname, '..', 'Panel.qml'), 'utf8')
const functions = panel.slice(panel.indexOf('  function monthIsCurrent()'), panel.indexOf('  function agendaMessageText()'))
const status = panel.slice(panel.indexOf('  function updatedAgoText()'), panel.indexOf('  function eventState('))
const root = {
  agendaEnabled: true, selectedDateKey: '2026-08-31',
  agendaRangeStartKey: '2026-08-31', agendaRangeEndKey: '2026-10-12',
  agendaRangeKey: '2026-08-31:2026-10-12',
  monthView: null, pendingMonth: null, calendarDates: {}, agendaEvents: [],
  agendaState: 'loading', overviewState: 'missing', lastAgendaRefreshMs: 0,
  lastAgendaRangeKey: '', lastAgendaRangeRefreshMs: 0,
  agendaRefreshIntervalMs: 1800000, now: new Date(),
  today: new Date(2026, 8, 27), weekStart: 1, prefetchAttempts: {},
  agendaPrefetch: false, agendaRefreshPending: false
}
let starts = 0
let cancels = 0
function process() {
  let running = false
  return {
    get running() { return running },
    set running(value) { if (value && !running) starts++; running = value },
    signal() { cancels++ }
  }
}
const cacheProcess = process()
const agendaProcess = process()
const deferred = []
const context = vm.createContext({root, cacheProcess, agendaProcess, Model,
  Qt: {callLater: fn => deferred.push(fn)},
  agendaScroll: {contentY: 0}, localText: (_nb, en) => en})
vm.runInContext(functions + status, context)
for (const key of ['monthIsCurrent', 'showDay', 'showSelectedDay', 'requestAgendaDate', 'refreshAgenda', 'resetAgendaView', 'prefetchRanges', 'schedulePrefetch', 'finishPrefetch']) root[key] = context[key]
for (const range of root.prefetchRanges()) root.prefetchAttempts[range.start + ':' + range.end] = Date.now()
const dates = {}
for (let i = 0; i < 42; i++) {
  const key = new Date(Date.UTC(2026, 7, 31 + i)).toISOString().slice(0, 10)
  dates[key] = {events: [], state: 'ok', complete: true, updatedAt: Math.floor(Date.now() / 1000), cached: false}
}
dates['2026-08-31'].events = [0]
dates['2026-09-01'].events = [1]
const header = {kind: 'month-start', date: root.agendaRangeStartKey, rangeEnd: root.agendaRangeEndKey, state: 'ok', complete: true, events: [], dates, cached: false, selectedCalendars: 1, updatedAt: Math.floor(Date.now() / 1000)}
const events = [{id: 'work:1', title: 'Planning', color: '#aabbcc'}, {id: 'work:2', title: 'Review', color: '#aabbcc'}]
const apply = (payload, cached=false) => context.applyAgendaPayload(JSON.stringify(payload), cached, '2026-08-31', root.agendaRangeStartKey, root.agendaRangeEndKey)
const chunk = {...header, kind: 'month-events', events}
const end = {...header, kind: 'month-end'}
apply(header)
apply(chunk)
assert.equal(root.monthView, null)
assert.equal(apply(end), true)
assert.equal(root.agendaEvents[0].title, 'Planning')
assert.equal(root.calendarDates['2026-09-01'].length, 1)

for (const key of Object.keys(dates)) {
  root.selectedDateKey = key
  root.requestAgendaDate()
  assert.equal(root.agendaState, 'ok')
  assert.equal(root.agendaDateKey, key)
}
assert.equal(starts, 0)
assert.equal(cancels, 0)
root.selectedDateKey = '2026-09-01'
root.requestAgendaDate()
assert.equal(root.agendaEvents[0].title, 'Review')
root.selectedDateKey = '2026-09-02'
root.requestAgendaDate()
assert.equal(root.agendaEvents.length, 0)
assert.equal(root.agendaState, 'ok') // Loaded empty dates are not cache misses.

agendaProcess.running = true
Object.assign(root, {agendaProcessRangeStartKey: root.agendaRangeStartKey, agendaProcessRangeEndKey: root.agendaRangeEndKey})
const alreadyStarted = starts
root.selectedDateKey = '2026-08-31'
root.requestAgendaDate()
assert.equal(root.agendaEvents[0].title, 'Planning')
assert.equal(starts, alreadyStarted)
assert.equal(cancels, 0)
agendaProcess.running = false

// Partial status belongs to its date, including when restored from disk.
const partial = JSON.parse(JSON.stringify(header))
partial.state = 'partial'
partial.dates['2026-08-31'].state = 'partial'
apply(partial, true); apply(chunk, true); apply(end, true)
assert.equal(root.agendaCached, true)
assert.equal(context.updatedAgoText(), 'Partial update · open calendar')
root.selectedDateKey = '2026-09-01'
root.showSelectedDay()
assert.equal(root.agendaState, 'ok')
assert.equal(context.updatedAgoText(), 'Updated just now')
assert.equal(context.dateIsIncomplete('2026-08-31'), true)
assert.equal(context.dateIsIncomplete('2026-09-01'), false)

// Invalid or interrupted transactions cannot discard an existing month.
const previous = root.monthView
apply(header)
assert.equal(root.monthView, previous)
assert.equal(apply(end), false) // References point to events never delivered.
assert.equal(root.monthView, previous)
assert.equal(context.applyAgendaPayload('x'.repeat(262145), false, '', root.agendaRangeStartKey, root.agendaRangeEndKey), false)
apply(header)
for (let i=0; i<11; i++) apply({...chunk, events: []})
assert.equal(root.pendingMonth, null)
assert.equal(root.monthView, previous)
assert.equal(apply({...header, date: '2026-07-20'}), false)

// Only a changed month cancels the old range request.
agendaProcess.running = true
root.agendaRangeStartKey = '2026-09-28'
root.agendaRangeEndKey = '2026-11-09'
root.requestAgendaDate()
assert.equal(cancels, 1)
agendaProcess.running = false
root.agendaEnabled = false
assert.equal(apply(header), false)

// Current month plus three ahead, using the same 42-day grids across years.
root.today = new Date(2026, 10, 27)
for (const weekStart of [0, 1, 6]) {
  root.weekStart = weekStart
  const ranges = root.prefetchRanges()
  assert.equal(ranges.length, 4)
  for (let offset = 0; offset < 4; offset++) {
    const month = Model.stepMonth(2026, 10, offset)
    const grid = Model.monthGrid(month.year, month.month, weekStart, '')
    assert.equal(ranges[offset].start, grid[0].days[0].key)
    const last = grid[5].days[6]
    assert.equal(ranges[offset].end, Model.keyForDate(new Date(last.year, last.month, last.day + 1)))
  }
}
Object.assign(root, {today: new Date(2026, 8, 27), weekStart: 1, agendaEnabled: true,
  agendaRangeStartKey: header.date, agendaRangeEndKey: header.rangeEnd,
  agendaRangeKey: header.date + ':' + header.rangeEnd,
  monthView: {...header, events}, prefetchAttempts: {}, agendaRequestCancelled: false})

// One worker at a time; three completed background jobs exhaust the queue.
const backgroundStarts = starts
for (let offset = 1; offset <= 3; offset++) {
  root.schedulePrefetch()
  assert.equal(root.agendaPrefetch, true)
  assert.equal(root.agendaProcessRangeStartKey, root.prefetchRanges()[offset].start)
  const busyStarts = starts
  root.schedulePrefetch()
  const previousCancels = cancels
  root.requestAgendaDate() // Warm day clicks leave prefetch running too.
  assert.equal(starts, busyStarts)
  assert.equal(cancels, previousCancels)
  agendaProcess.running = false
  root.finishPrefetch() // Failures take this same path and receive a cooldown.
  assert.equal(root.agendaPrefetch, false)
  deferred.length = 0
}
root.schedulePrefetch()
assert.equal(starts, backgroundStarts + 3)
assert.equal(Object.keys(root.prefetchAttempts).length, 4)

// A visible month request preempts background work before reading disk.
root.prefetchAttempts = {}
root.schedulePrefetch()
root.monthView = null
const beforePreempt = cancels
root.requestAgendaDate()
assert.equal(cancels, beforePreempt + 1)
assert.equal(cacheProcess.running, false)
agendaProcess.running = false
root.finishPrefetch()
deferred.shift()()
assert.equal(cacheProcess.running, true)
cacheProcess.running = false

// Manual refresh cancels prefetch and must not be lost to freshness checks.
root.monthView = {...header, events}
root.schedulePrefetch()
root.refreshAgenda(true)
assert.equal(root.agendaRefreshPending, true)
agendaProcess.running = false
root.finishPrefetch()
deferred.shift()()
assert.equal(agendaProcess.running, true)
assert.equal(root.agendaPrefetch, false)
assert.equal(root.agendaForceRefresh, true)
assert.equal(root.agendaRefreshPending, false)
agendaProcess.running = false

// Disabled agenda schedules nothing; stale due times resume on re-enable.
root.agendaEnabled = false
root.prefetchAttempts = {}
const disabledStarts = starts
root.schedulePrefetch()
assert.equal(starts, disabledStarts)
root.agendaEnabled = true
root.schedulePrefetch()
assert.equal(starts, disabledStarts + 1)
const periodicCancels = cancels
root.refreshAgenda(false)
assert.equal(cancels, periodicCancels)
agendaProcess.running = false

// Slow work at short intervals cannot starve the more distant months.
const ranges = root.prefetchRanges()
root.prefetchAttempts = {[ranges[1].start + ':' + ranges[1].end]: Date.now() - 3600000}
root.schedulePrefetch()
assert.equal(root.agendaProcessRangeStartKey, ranges[2].start)
console.log('ok — all 42 dates select locally, refresh survives day clicks, partial dates and atomic bounded messages')
console.log('ok — three-month prefetch stays serial, yields to visible requests, respects cooldown and year/week boundaries')
