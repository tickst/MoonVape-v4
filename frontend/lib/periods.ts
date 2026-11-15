// Периоды отчётов. Все даты — по берлинскому времени бизнеса (как и в БД: Europe/Berlin).
export const PRESETS: [string, string][] = [
  ['today', 'Сегодня'], ['yesterday', 'Вчера'], ['7d', '7 дней'], ['30d', '30 дней'],
  ['month', 'Этот месяц'], ['prev_month', 'Прошлый месяц'], ['custom', 'Период'],
]

export const todayBerlin = (now: Date = new Date()) => now.toLocaleDateString('sv-SE', { timeZone: 'Europe/Berlin' })

export const addDays = (s: string, n: number) => {
  const d = new Date(s + 'T00:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10)
}

/** Границы пресета включительно: [с, по]. `today` передаётся в тестах. */
export function presetRange(p: string, today: string = todayBerlin()): [string, string] {
  if (p === 'today') return [today, today]
  if (p === 'yesterday') { const y = addDays(today, -1); return [y, y] }
  if (p === '7d') return [addDays(today, -6), today]
  if (p === '30d') return [addDays(today, -29), today]
  if (p === 'month') return [today.slice(0, 8) + '01', today]
  if (p === 'prev_month') { const end = addDays(today.slice(0, 8) + '01', -1); return [end.slice(0, 8) + '01', end] }
  return [today, today]
}

/** Период некорректен, если не заполнен, перевёрнут или длиннее года (как в БД: bad_period). */
export const badRange = (from: string, to: string) => {
  if (!from || !to || to < from) return true
  return (Date.parse(to + 'T00:00:00Z') - Date.parse(from + 'T00:00:00Z')) / 86400000 > 366
}
