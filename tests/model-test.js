const assert = require('node:assert/strict')
const M = require('../Model.js')
assert.equal(M.isoWeek(2021,0,1),53)
assert.equal(M.isoWeek(2021,0,4),1)
for (let start=0;start<7;start++) {
 const grid=M.monthGrid(2024,1,start,'2024-02-29')
 assert.equal(grid.length,6)
 assert.equal(grid.flatMap(w=>w.days).length,42)
 assert.equal(grid[0].days[0].weekday,start)
 assert.equal(grid.flatMap(w=>w.days).filter(d=>d.today).length,1)
}
assert.equal(M.normalizedWeekStart('locale',0),0)
assert.equal(M.normalizedWeekStart('monday',0),1)
assert.equal(M.clockNeedsSeconds("HH:mm 'seconds'"),false)
assert.equal(M.clockNeedsSeconds('HH:mm:ss'),true)
const ring=M.clockFormatRing('custom','alternate',M.clockFormats(false))
let current=ring[0];const seen=new Set()
for (let i=0;i<ring.length;i++) { seen.add(current);current=M.nextClockFormat(ring,current) }
assert.equal(seen.size,ring.length)
assert.equal(current,ring[0])
// Each row's week number is the ISO week of its Thursday, whatever the week start.
for (const start of [0,1,6]) assert.deepEqual(M.monthGrid(2021,0,start,'').map(w=>w.week),[53,1,2,3,4,5],`week start ${start}`)
assert.equal(M.monthGrid(2024,1,1,'').flatMap(w=>w.days).filter(d=>d.inMonth).length,29)
// The week-start toggle flips Monday and Sunday; any other start lands on Monday.
assert.deepEqual([1,0,6].map(M.toggledWeekStart),[0,1,1])
console.log('ok — ISO boundaries, month grids, format cycling')
