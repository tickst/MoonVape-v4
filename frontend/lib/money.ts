// Деньги в интерфейсе: пользовательский ввод → строка с фиксированным числом знаков (без float).
// Backend принимает Decimal; строка '7.50' не теряет точность и не даёт артефактов вида 0.30000000000000004.

/** '7,5' → '7.50'. Возвращает null для пустого ввода, отрицательных значений, экспоненты и лишних знаков. */
export function parseMoney(input: string, places = 2): string | null {
  const s = String(input ?? '').trim().replace(/\s/g, '').replace(',', '.')
  if (!/^\d+(\.\d+)?$/.test(s)) return null
  const [int, frac = ''] = s.split('.')
  if (frac.length > places) return null
  return int.replace(/^0+(?=\d)/, '') + (places > 0 ? '.' + frac.padEnd(places, '0') : '')
}

/** Для сообщений: '12,50 €' из строки или числа (только отображение). */
export const fmtEur = (v: unknown) => (Number.isFinite(+(v as any)) ? +(v as any) : 0).toFixed(2).replace('.', ',') + ' €'

/** Положительная сумма? (для блокировки кнопок). */
export const isPositive = (s: string | null) => s !== null && Number(s) > 0
