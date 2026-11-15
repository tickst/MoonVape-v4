import { test } from 'node:test'
import assert from 'node:assert/strict'
import { parseMoney, fmtEur, isPositive } from './money.ts'
import { presetRange, addDays, badRange, todayBerlin } from './periods.ts'

test('parseMoney: запятая, точка, дополнение нулями', () => {
  assert.equal(parseMoney('7,5'), '7.50'); assert.equal(parseMoney('7.5'), '7.50'); assert.equal(parseMoney('10'), '10.00')
  assert.equal(parseMoney(' 0,05 '), '0.05'); assert.equal(parseMoney('007'), '7.00'); assert.equal(parseMoney('0'), '0.00')
})
test('parseMoney: отклоняет мусор, минус, лишние знаки, экспоненту', () => {
  for (const bad of ['', ' ', '-1', '1e3', '7.123', 'abc', '1,2,3', '.5', '5.', '0x10', null as any, undefined as any]) assert.equal(parseMoney(bad), null, String(bad))
})
test('parseMoney: 4 знака для закупочных цен', () => {
  assert.equal(parseMoney('3,1234', 4), '3.1234'); assert.equal(parseMoney('3.12', 4), '3.1200'); assert.equal(parseMoney('3.12345', 4), null)
})
test('parseMoney: нет float-артефактов', () => { assert.equal(parseMoney(String(0.1 + 0.2)), null); assert.equal(parseMoney('0.30'), '0.30') })
test('fmtEur / isPositive', () => {
  assert.equal(fmtEur('7.5'), '7,50 €'); assert.equal(fmtEur(null), '0,00 €'); assert.equal(isPositive('0.00'), false); assert.equal(isPositive('0.01'), true); assert.equal(isPositive(null), false)
})
test('presetRange: сегодня, вчера, 7 и 30 дней', () => {
  const t = '2026-11-14'
  assert.deepEqual(presetRange('today', t), [t, t]); assert.deepEqual(presetRange('yesterday', t), ['2026-11-13', '2026-11-13'])
  assert.deepEqual(presetRange('7d', t), ['2026-11-08', t]); assert.deepEqual(presetRange('30d', t), ['2026-10-16', t])
})
test('presetRange: этот и прошлый месяц, граница года и високосный февраль', () => {
  assert.deepEqual(presetRange('month', '2026-11-14'), ['2026-11-01', '2026-11-14'])
  assert.deepEqual(presetRange('prev_month', '2026-11-14'), ['2026-10-01', '2026-10-31'])
  assert.deepEqual(presetRange('prev_month', '2027-01-05'), ['2026-12-01', '2026-12-31'])
  assert.deepEqual(presetRange('prev_month', '2024-03-10'), ['2024-02-01', '2024-02-29'])
  assert.deepEqual(presetRange('yesterday', '2026-01-01'), ['2025-12-31', '2025-12-31'])
})
test('badRange', () => {
  assert.equal(badRange('', '2026-01-01'), true); assert.equal(badRange('2026-02-01', '2026-01-01'), true)
  assert.equal(badRange('2026-01-01', '2026-01-01'), false); assert.equal(badRange('2025-01-01', '2026-06-01'), true)
})
test('todayBerlin: полночь по UTC уже следующий день в Берлине', () => {
  assert.equal(todayBerlin(new Date('2026-06-30T22:30:00Z')), '2026-07-01')   // CEST = UTC+2
  assert.equal(todayBerlin(new Date('2026-12-31T23:30:00Z')), '2027-01-01')   // CET = UTC+1
  assert.equal(addDays('2026-02-28', 1), '2026-03-01')
})
