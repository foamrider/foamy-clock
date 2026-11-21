// The agenda engine of ClockService.qml (requests, prefetch, the month wire
// protocol) and the footer text of ClockView.qml, run under node. The real
// function bodies are cut out of the QML files and run in a vm context with a
// fake `root`, fake processes and a fixed clock; each case builds its own.
const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const vm = require('node:vm')
const path = require('node:path')
const Model = require('../Model.js')
const I18n = require('./i18n.cjs')

function slice(file, from, to) {
  const code = fs.readFileSync(path.join(__dirname, '..', file), 'utf8')
  const start = code.indexOf(from)
  const end = code.indexOf(to, start)
  assert.ok(start >= 0 && end > start, `${file}: ${from.trim()} not found`)
  return code.slice(start, end)
}
const engine = slice('ClockService.qml', '  function monthIsCurrent()', '  function goToToday()')
const footer = slice('ClockView.qml', '  function updatedAgoText()', '  function agendaMessageText()')
// FoamyI18n with the kit's own updatedAgo over the plugin's English catalog.
const i18n = {t: (key, values) => I18n.text(key, 'en', values), tn: (key, count, values) => I18n.plural(key, 'en', count, values), number: String}
vm.runInNewContext(slice('kit/FoamyI18n.qml', '  function updatedAgo(', '  function number(') + '; i18n.updatedAgo = updatedAgo',
  {i18n, t: i18n.t, tn: i18n.tn, Number, Math, isFinite, Date})

const MINUTE = 60000
const INTERVAL = 30 * MINUTE
// Values made in the vm context have its own prototypes; compare plain copies.
const plain = value => JSON.parse(JSON.stringify(value))

// The shown month of the fixed clock (2026-09-27, weeks from Monday) and the next.
const SEPTEMBER = {start: '2026-08-31', end: '2026-10-12'}
const OCTOBER = {start: '2026-09-28', end: '2026-11-09'}

function process() {
  let running = false
  const p = {
    starts: 0,
    signals: 0,
    get running() { return running },
    set running(value) { if (value && !running) p.starts++; running = value },
    signal() { p.signals++ }
  }
  return p
}

function service(inputs = {}) {
  const clock = {ms: new Date(2026, 8, 27, 12, 0).getTime()}
  class FixedDate extends Date {
    constructor(...args) { if (args.length === 0) super(clock.ms); else super(...args) }
    static now() { return clock.ms }
  }
  const cacheProcess = process()
  const agendaProcess = process()
  const deferred = []
  const root = {
    activated: true, agendaEnabled: true, backgroundRefresh: true, demanded: true, monthsAhead: 3, weekStart: 1,
    today: new Date(2026, 8, 27), selectedDateKey: '2026-08-31',
    agendaRangeStartKey: SEPTEMBER.start, agendaRangeEndKey: SEPTEMBER.end,
    agendaEvents: [], calendarDates: {}, monthView: null, pendingMonth: null, pendingMonthBytes: 0, pendingMonthChunks: 0,
    agendaState: 'loading', agendaMessage: '', overviewState: 'missing', agendaDateKey: '', selectedCalendars: 0,
    lastAgendaRefreshMs: 0, agendaCached: false, agendaProcessRangeStartKey: '', agendaProcessRangeEndKey: '',
    cacheProcessRangeStartKey: '', cacheProcessRangeEndKey: '', agendaRequestCancelled: false, agendaPrefetch: false,
    agendaRefreshPending: false, prefetchAttempts: {}, agendaForceRefresh: false, agendaPayloadApplied: false,
    lastAgendaRangeRefreshMs: 0, lastAgendaRangeKey: '', agendaRefreshIntervalMs: INTERVAL,
    agendaReset() {},
    get now() { return new FixedDate() },
    // QML bindings node cannot evaluate, repeated from ClockService.qml:
    // agendaActive, backgroundActive, agendaRefreshing and agendaRangeKey.
    get agendaActive() { return this.activated && this.agendaEnabled },
    get backgroundActive() { return this.agendaEnabled && this.backgroundRefresh && !this.demanded },
    get agendaRefreshing() { return agendaProcess.running && !this.agendaPrefetch },
    get agendaRangeKey() { return this.agendaRangeStartKey + ':' + this.agendaRangeEndKey }
  }
  Object.assign(root, inputs)
  const context = vm.createContext({root, service: root, cacheProcess, agendaProcess, Model, Date: FixedDate,
    Qt: {callLater: fn => deferred.push(fn)}, FoamyI18n: i18n})
  vm.runInContext(engine + footer, context)
  for (const name of ['monthIsCurrent', 'showSelectedDay', 'showDay', 'requestAgendaDate', 'prefetchRanges', 'schedulePrefetch',
    'finishPrefetch', 'resetAgendaView', 'refreshAgenda', 'applyAgendaPayload', 'dotsForDate', 'dateIsIncomplete']) root[name] = context[name]
  return {
    root, cacheProcess, agendaProcess, deferred, context,
    get starts() { return cacheProcess.starts + agendaProcess.starts },
    get signals() { return agendaProcess.signals },
    advance(ms) { clock.ms += ms },
    nowMs() { return clock.ms },
    // Run what Qt.callLater queued, as the event loop would.
    flush() { for (let i = 0; deferred.length > 0; i++) { assert.ok(i < 20, 'callLater loop'); deferred.shift()() } },
    footer: () => context.updatedAgoText(),
    titles: () => plain(root.agendaEvents.map(e => e.title)),
    show(range) { root.agendaRangeStartKey = range.start; root.agendaRangeEndKey = range.end }
  }
}

// A month in the helper's shape: 42 dates from `range.start`, the events and
// each date's indices into them.
function month(fx, {range = SEPTEMBER, events, on, state = 'ok', updatedAt = Math.floor(fx.nowMs() / 1000)} = {}) {
  events = events || [{id: 'work:1', title: 'Planning', color: '#aabbcc'}, {id: 'work:2', title: 'Review', color: '#aabbcc'}]
  on = on || {'2026-08-31': [0], '2026-09-01': [1]}
  const [y, m, d] = range.start.split('-').map(Number)
  const dates = {}
  for (let i = 0; i < 42; i++) {
    const key = Model.keyForDate(new Date(y, m - 1, d + i))
    dates[key] = {events: on[key] || [], state, complete: true, updatedAt, cached: false}
  }
  return {date: range.start, rangeEnd: range.end, state, complete: true, selectedCalendars: 1, updatedAt, cached: false, dates, events}
}

// The lines calendar-events.py emit_view() prints for a month.
function wire(payload) {
  const lines = [{...payload, kind: 'month-start', events: []}]
  for (let i = 0; i < payload.events.length; i += 100)
    lines.push({kind: 'month-events', date: payload.date, rangeEnd: payload.rangeEnd, events: payload.events.slice(i, i + 100)})
  lines.push({kind: 'month-end', date: payload.date, rangeEnd: payload.rangeEnd})
  return lines.map(line => JSON.stringify(line))
}

function apply(fx, line, fromCache = false) {
  return fx.context.applyAgendaPayload(line, fromCache, fx.root.agendaRangeStartKey, fx.root.agendaRangeEndKey)
}

function deliver(fx, payload, fromCache = false) {
  return wire(payload).map(line => apply(fx, line, fromCache))
}

test('a month shows only after month-end; one dot per calendar, at most five', () => {
  const fx = service()
  const events = ['a:1', 'a:2', 'b:1', 'c:1', 'd:1', 'e:1', 'f:1'].map((id, i) => ({id, title: id, color: `#00000${i}`}))
  const payload = month(fx, {events: [{id: 'work:1', title: 'Planning', color: '#aabbcc'}, ...events], on: {'2026-08-31': [0], '2026-09-02': [1, 2, 3, 4, 5, 6, 7]}})
  const lines = wire(payload)
  assert.equal(apply(fx, lines[0]), false)
  assert.equal(apply(fx, lines[1]), false)
  assert.deepEqual(fx.titles(), [])
  assert.deepEqual(plain(fx.root.dotsForDate('2026-08-31')), [])
  assert.equal(apply(fx, lines[2]), true)
  assert.deepEqual(fx.titles(), ['Planning'])
  assert.deepEqual(plain(fx.root.dotsForDate('2026-08-31')), [{id: 'work', color: '#aabbcc'}])
  assert.deepEqual(plain(fx.root.dotsForDate('2026-09-02')),
    [['a', '#000000'], ['b', '#000002'], ['c', '#000003'], ['d', '#000004'], ['e', '#000005']].map(([id, color]) => ({id, color})))
})

// monthsAhead 0: the shown month is the whole horizon and an open popup
// refreshes it itself, so no prefetch is due and the check can be strict.
test('every loaded day selects without a process', () => {
  const fx = service({monthsAhead: 0})
  deliver(fx, month(fx))
  for (const key of Object.keys(month(fx).dates)) {
    fx.root.selectedDateKey = key
    fx.root.requestAgendaDate()
    assert.equal(fx.root.agendaState, 'ok', key)
  }
  assert.equal(fx.starts, 0)
  assert.equal(fx.signals, 0)
  fx.root.selectedDateKey = '2026-09-01'
  fx.root.requestAgendaDate()
  assert.deepEqual(fx.titles(), ['Review'])
  fx.root.selectedDateKey = '2026-09-02'
  fx.root.requestAgendaDate()
  assert.deepEqual(fx.titles(), [])
  assert.equal(fx.root.agendaState, 'ok') // A loaded empty date is not a cache miss.
})

test('a day click leaves the running month refresh alone', () => {
  const fx = service({monthsAhead: 0})
  deliver(fx, month(fx))
  fx.root.refreshAgenda(true)
  assert.equal(fx.agendaProcess.starts, 1)
  fx.root.selectedDateKey = '2026-09-01'
  fx.root.requestAgendaDate()
  assert.deepEqual(fx.titles(), ['Review'])
  assert.equal(fx.starts, 1)
  assert.equal(fx.signals, 0)
})

test('partial status belongs to its date, also when read from disk', () => {
  const fx = service()
  const payload = month(fx)
  payload.state = 'partial'
  payload.dates['2026-08-31'].state = 'partial'
  assert.equal(deliver(fx, payload, true).at(-1), true)
  assert.equal(fx.footer(), 'Partial update · open calendar')
  fx.root.selectedDateKey = '2026-09-01'
  fx.root.showSelectedDay()
  assert.equal(fx.root.agendaState, 'ok')
  assert.equal(fx.footer(), 'Updated just now')
  assert.equal(fx.root.dateIsIncomplete('2026-08-31'), true)
  assert.equal(fx.root.dateIsIncomplete('2026-09-01'), false)
})

// A saved copy from yesterday reads in hours (a live check once showed
// "Updated 1283 minutes ago"), and "Updating…" while Evolution is asked.
test('the footer ages in hours and says Updating… while Evolution is asked', () => {
  const fx = service()
  deliver(fx, month(fx, {updatedAt: Math.floor(fx.nowMs() / 1000) - 1283 * 60}), true)
  assert.equal(fx.footer(), 'Updated 21 hours ago')
  fx.root.refreshAgenda(true)
  assert.equal(fx.agendaProcess.running, true)
  assert.equal(fx.footer(), 'Updating…')
})

test('a broken transaction keeps the shown month', async t => {
  // A month that would change the shown events and dots if it were committed.
  const intruder = fx => month(fx, {events: [{id: 'x:1', title: 'Intruder', color: '#ff0000'}], on: {'2026-08-31': [0], '2026-09-02': [0]}})
  const chunkOf = size => {
    // A legal chunk line of `size` characters.
    const line = {kind: 'month-events', date: SEPTEMBER.start, rangeEnd: SEPTEMBER.end, events: [{id: 'x:1', title: '', color: '#ff0000'}]}
    line.events[0].title = 'x'.repeat(size - JSON.stringify(line).length)
    return JSON.stringify(line)
  }
  const rows = {
    'month-end refers to events never sent': fx => { const l = wire(intruder(fx)); return [l[0], l[2]] },
    'a legal chunk line over 262144 characters': fx => { const l = wire(intruder(fx)); return [l[0], chunkOf(262145), l[2]] },
    'an eleventh chunk': fx => { const l = wire(intruder(fx)); return [l[0], ...Array(11).fill(l[1]), l[2]] },
    'a header for another range': fx => wire(intruder(fx)).map(line => line.replaceAll(SEPTEMBER.start, '2026-07-20')),
    'a cut-off line, as a killed helper leaves it': fx => { const l = wire(intruder(fx)); return [l[0], '{"kind":"month-ev', l[2]] },
    'nine legal lines over the month byte limit': fx => { const l = wire(intruder(fx)); return [l[0], ...Array(9).fill(chunkOf(250000)), l[2]] },
    'a chunk with 101 events': fx => {
      const payload = intruder(fx)
      const l = wire(payload)
      const chunk = {kind: 'month-events', date: SEPTEMBER.start, rangeEnd: SEPTEMBER.end, events: Array(101).fill(payload.events[0])}
      return [l[0], JSON.stringify(chunk), l[2]]
    },
    'a header with 41 dates': fx => {
      const payload = intruder(fx)
      delete payload.dates['2026-10-11']
      return wire(payload)
    },
    'an unknown kind': fx => { const l = wire(intruder(fx)); return [l[0], l[1], JSON.stringify({kind: 'month-other', date: SEPTEMBER.start, rangeEnd: SEPTEMBER.end}), l[2]] },
    'a missing month': fx => wire(month(fx, {state: 'missing', events: [{id: 'x:1', title: 'Intruder', color: '#ff0000'}], on: {'2026-08-31': [0]}})),
    'a bad date record': fx => {
      const payload = intruder(fx)
      payload.dates['2026-09-03'].state = 'bogus'
      return wire(payload)
    }
  }
  for (const [name, lines] of Object.entries(rows)) {
    await t.test(name, () => {
      const fx = service()
      deliver(fx, month(fx))
      const titles = fx.titles()
      const dots = plain(fx.root.calendarDates)
      for (const [i, line] of lines(fx).entries()) assert.equal(apply(fx, line), false, `line ${i}`)
      assert.deepEqual(fx.titles(), titles)
      assert.deepEqual(plain(fx.root.calendarDates), dots)
      assert.equal(apply(fx, wire(intruder(fx)).at(-1)), false, 'a following month-end alone')
      assert.deepEqual(fx.titles(), titles)
    })
  }
})

test('a new visible month cancels the old request; a day click does not', () => {
  const fx = service({monthsAhead: 0})
  deliver(fx, month(fx))
  fx.root.refreshAgenda(true)
  fx.root.selectedDateKey = '2026-09-01'
  fx.root.requestAgendaDate()
  assert.equal(fx.signals, 0)
  fx.show(OCTOBER)
  fx.root.requestAgendaDate()
  assert.equal(fx.signals, 1)
})

test('output is ignored when the agenda is off', () => {
  const fx = service({agendaEnabled: false})
  assert.deepEqual(deliver(fx, month(fx)), [false, false, false])
  assert.deepEqual(fx.titles(), [])
  assert.deepEqual(plain(fx.root.dotsForDate('2026-08-31')), [])
})

test('prefetch covers this month and three ahead across a year end', () => {
  const expected = {
    1: [['2026-10-26', '2026-12-07'], ['2026-11-30', '2027-01-11'], ['2026-12-28', '2027-02-08'], ['2027-02-01', '2027-03-15']],
    0: [['2026-11-01', '2026-12-13'], ['2026-11-29', '2027-01-10'], ['2026-12-27', '2027-02-07'], ['2027-01-31', '2027-03-14']]
  }
  for (const [weekStart, ranges] of Object.entries(expected)) {
    const fx = service({today: new Date(2026, 10, 27), weekStart: Number(weekStart)})
    assert.deepEqual(plain(fx.root.prefetchRanges()).map(r => [r.start, r.end]), ranges, `week start ${weekStart}`)
  }
})

test('months ahead (0-6) sets the horizon', () => {
  for (const [ahead, count] of [[0, 1], [1, 2], [6, 7]]) {
    const fx = service({monthsAhead: ahead})
    assert.equal(fx.root.prefetchRanges().length, count, `monthsAhead ${ahead}`)
  }
})

test('prefetch: one month at a time, nearest first, the shown month skipped, then a wait of one interval', () => {
  const fx = service()
  deliver(fx, month(fx))
  const ranges = plain(fx.root.prefetchRanges())
  fx.root.schedulePrefetch()
  for (let offset = 1; offset <= 3; offset++) {
    assert.equal(fx.agendaProcess.starts, offset)
    assert.equal(fx.root.agendaPrefetch, true) // --cache-only
    assert.deepEqual([fx.root.agendaProcessRangeStartKey, fx.root.agendaProcessRangeEndKey], [ranges[offset].start, ranges[offset].end])
    fx.root.schedulePrefetch()
    fx.root.selectedDateKey = offset % 2 ? '2026-09-01' : '2026-08-31'
    fx.root.requestAgendaDate() // A day click leaves the prefetch running.
    assert.equal(fx.agendaProcess.starts, offset)
    assert.equal(fx.signals, 0)
    // agendaProcess.onExited for a prefetch, then the request it queues.
    fx.agendaProcess.running = false
    fx.root.finishPrefetch()
    assert.equal(fx.root.agendaPrefetch, false)
    fx.flush()
  }
  assert.equal(fx.starts, 3)
  fx.advance(INTERVAL - MINUTE)
  fx.root.schedulePrefetch()
  assert.equal(fx.starts, 3)
  fx.advance(MINUTE)
  fx.root.schedulePrefetch()
  assert.equal(fx.starts, 4)
  assert.equal(fx.root.agendaProcessRangeStartKey, ranges[1].start)
})

test('a new visible month preempts a prefetch, then reads the disk', () => {
  const fx = service()
  deliver(fx, month(fx))
  fx.root.schedulePrefetch()
  assert.equal(fx.root.agendaPrefetch, true)
  fx.show(OCTOBER)
  fx.root.requestAgendaDate()
  assert.equal(fx.signals, 1)
  assert.equal(fx.cacheProcess.running, false)
  fx.agendaProcess.running = false
  fx.root.finishPrefetch()
  fx.flush()
  assert.equal(fx.cacheProcess.running, true)
  assert.deepEqual([fx.root.cacheProcessRangeStartKey, fx.root.cacheProcessRangeEndKey], [OCTOBER.start, OCTOBER.end])
})

test('a manual refresh interrupts a prefetch and runs forced', () => {
  const fx = service()
  deliver(fx, month(fx))
  fx.root.schedulePrefetch()
  assert.equal(fx.agendaProcess.starts, 1)
  fx.root.refreshAgenda(true)
  assert.equal(fx.signals, 1)
  fx.agendaProcess.running = false
  fx.root.finishPrefetch()
  fx.flush()
  assert.equal(fx.agendaProcess.starts, 2)
  assert.equal(fx.agendaProcess.running, true)
  assert.equal(fx.root.agendaPrefetch, false)
  assert.equal(fx.root.agendaForceRefresh, true) // --max-age 0
  assert.equal(fx.root.agendaProcessRangeStartKey, SEPTEMBER.start)
})

// The `r` key works while the disk is read (the button is disabled then);
// the refresh runs when the read ends, even when the disk copy is fresh.
test('a refresh asked for during the disk read runs when the read ends', () => {
  const fx = service()
  fx.root.requestAgendaDate()
  assert.equal(fx.cacheProcess.running, true)
  fx.root.refreshAgenda(true)
  assert.equal(fx.agendaProcess.starts, 0)
  deliver(fx, month(fx), true)
  fx.cacheProcess.running = false
  fx.root.refreshAgenda(false) // cacheProcess.onExited
  assert.equal(fx.agendaProcess.running, true)
  assert.equal(fx.root.agendaPrefetch, false)
  assert.equal(fx.root.agendaForceRefresh, true)
})

test('before the first open only the background check may start a helper', () => {
  for (const backgroundRefresh of [true, false]) {
    const fx = service({activated: false, demanded: false, backgroundRefresh})
    fx.root.requestAgendaDate()
    fx.root.refreshAgenda(true)
    fx.flush()
    assert.equal(fx.starts, 0, `background ${backgroundRefresh}`)
    if (!backgroundRefresh) {
      fx.root.schedulePrefetch()
      assert.equal(fx.starts, 0)
    }
  }
})

test('agenda off schedules nothing; a periodic check does not interrupt a prefetch', () => {
  const fx = service()
  deliver(fx, month(fx))
  fx.root.agendaEnabled = false
  fx.root.schedulePrefetch()
  assert.equal(fx.starts, 0)
  fx.root.agendaEnabled = true
  fx.root.schedulePrefetch()
  assert.equal(fx.agendaProcess.starts, 1)
  fx.advance(INTERVAL)
  fx.root.refreshAgenda(false) // refreshTimer
  assert.equal(fx.signals, 0)
  assert.equal(fx.agendaProcess.starts, 1)
})

// With every popup closed the prefetch goes by the real date: `today` is what
// the popup saw when it was last open, as nothing ticks while closed.
test('closed with background updates: this month and the months ahead, one per check, nothing for the shell', () => {
  const fx = service({activated: false, demanded: false, today: new Date(2026, 7, 15)})
  const expected = [['2026-08-31', '2026-10-12'], ['2026-09-28', '2026-11-09'], ['2026-10-26', '2026-12-07'], ['2026-11-30', '2027-01-11']]
  for (const [i, range] of expected.entries()) {
    fx.root.schedulePrefetch()
    assert.equal(fx.agendaProcess.starts, i + 1)
    assert.equal(fx.root.agendaPrefetch, true)
    assert.deepEqual([fx.root.agendaProcessRangeStartKey, fx.root.agendaProcessRangeEndKey], range)
    fx.agendaProcess.running = false
    fx.root.finishPrefetch()
    assert.equal(fx.deferred.length, 0, 'no foreground request while closed')
  }
  fx.root.schedulePrefetch()
  assert.equal(fx.starts, 4, 'four fresh months wait for the refresh interval')
  const off = service({activated: false, demanded: false, backgroundRefresh: false})
  off.root.schedulePrefetch()
  assert.equal(off.starts, 0)
})

test('never-attempted months first, then the oldest attempt', () => {
  const key = r => r.start + ':' + r.end
  const rows = [
    {name: 'one attempted month', ages: {1: 60}, expected: 2},
    {name: 'all attempted, the oldest wins', ages: {1: 40, 2: 90, 3: 60}, expected: 2},
    {name: 'all attempted, the nearest is oldest', ages: {1: 120, 2: 90, 3: 60}, expected: 1}
  ]
  for (const row of rows) {
    const fx = service()
    deliver(fx, month(fx))
    const ranges = plain(fx.root.prefetchRanges())
    fx.root.prefetchAttempts = Object.fromEntries(Object.entries(row.ages).map(([i, minutes]) => [key(ranges[i]), fx.nowMs() - minutes * MINUTE]))
    fx.root.schedulePrefetch()
    assert.equal(fx.root.agendaProcessRangeStartKey, ranges[row.expected].start, row.name)
  }
})

test('a fresh month asks Evolution for nothing; a stale one is refreshed once; a failed attempt waits one interval', () => {
  const fx = service({monthsAhead: 0})
  deliver(fx, month(fx))
  fx.root.requestAgendaDate()
  assert.equal(fx.starts, 0)
  fx.advance(INTERVAL)
  fx.root.requestAgendaDate()
  assert.equal(fx.agendaProcess.starts, 1)
  assert.equal(fx.root.agendaPrefetch, false)
  assert.equal(fx.root.agendaForceRefresh, false)
  // What agendaProcess.onExited records after a run that committed no month
  // (node cannot run the handler).
  fx.agendaProcess.running = false
  fx.root.lastAgendaRangeKey = fx.root.agendaRangeKey
  fx.root.lastAgendaRangeRefreshMs = fx.nowMs()
  fx.root.requestAgendaDate()
  assert.equal(fx.agendaProcess.starts, 1)
  fx.advance(INTERVAL)
  fx.root.requestAgendaDate()
  assert.equal(fx.agendaProcess.starts, 2)
})
