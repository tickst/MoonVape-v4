'use client'
import { ReactNode, useState } from 'react'
import { PRESETS, badRange, presetRange } from '@/lib/periods'
import { Sheet } from '../ui'

export const newKey = () => crypto.randomUUID()
export const dt = (s?: string | null) => (s ? new Date(s).toLocaleString('ru-RU', { timeZone: 'Europe/Berlin' }) : '—')
export const dtDay = (s?: string | null) => (s ? new Date(s).toLocaleDateString('ru-RU', { timeZone: 'Europe/Berlin' }) : '—')

/** Период отчёта: пресеты (сегодня, вчера, 7/30 дней, месяц, прошлый месяц) и произвольный диапазон. */
export function usePeriod(initial = '30d') {
  const [preset, setPreset] = useState(initial)
  const [[from, to], setRange] = useState<[string, string]>(presetRange(initial))
  const pick = (p: string) => { setPreset(p); if (p !== 'custom') setRange(presetRange(p)) }
  return { preset, from, to, bad: badRange(from, to), pick, setFrom: (v: string) => setRange([v, to]), setTo: (v: string) => setRange([from, v]) }
}
export type Period = ReturnType<typeof usePeriod>

export function PeriodBar({ p }: { p: Period }) {
  return (<>
    <div className="mv-row" style={{ gap: 6, flexWrap: 'wrap' }}>
      {PRESETS.map(([k, l]) => <button key={k} className={`mv-btn sm ${p.preset === k ? '' : 'ghost'}`} style={{ width: 'auto' }} onClick={() => p.pick(k)}>{l}</button>)}
    </div>
    {p.preset === 'custom' && <div className="mv-row" style={{ gap: 8, marginTop: 8 }}>
      <input className="mv-input sm" type="date" value={p.from} onChange={e => p.setFrom(e.target.value)} />
      <input className="mv-input sm" type="date" value={p.to} onChange={e => p.setTo(e.target.value)} />
    </div>}
    {p.bad && <div className="mv-note" style={{ marginTop: 8 }}>Проверьте период: «по» не раньше «с», не длиннее года</div>}
  </>)
}

export function Tabs({ items, value, onChange }: { items: [string, string][]; value: string; onChange: (k: string) => void }) {
  return <div className="mv-chips" role="tablist">{items.map(([k, l]) =>
    <button key={k} role="tab" aria-selected={value === k} className={'mv-pill' + (value === k ? ' on' : '')} onClick={() => onChange(k)}>{l}</button>)}</div>
}

export function Kv({ l, v }: { l: string; v: ReactNode }) {
  return <div className="mv-row mv-between" style={{ fontSize: 14, alignItems: 'flex-start' }}><span className="mv-muted">{l}</span><span style={{ textAlign: 'right', maxWidth: '65%', overflowWrap: 'anywhere' }}>{v}</span></div>
}

export const Note = ({ children, warn }: { children: ReactNode; warn?: boolean }) =>
  <div className="mv-note" style={{ marginTop: 8, ...(warn ? { borderColor: 'rgba(245,166,74,.5)' } : {}) }}>{children}</div>

/** CSV в шторке: «Копировать» работает в любом Telegram-клиенте, «Скачать» — там, где разрешены загрузки. */
export function CsvSheet({ title, text, filename, onClose }: { title: string; text: string; filename: string; onClose: () => void }) {
  const [copied, setCopied] = useState(false)
  const copy = async () => { try { await navigator.clipboard.writeText(text); setCopied(true) } catch { /* выделите текст вручную */ } }
  const save = () => {
    const url = URL.createObjectURL(new Blob(['\ufeff' + text], { type: 'text/csv;charset=utf-8' }))
    const a = document.createElement('a'); a.href = url; a.download = filename; a.click(); setTimeout(() => URL.revokeObjectURL(url), 2000)
  }
  return (<Sheet onClose={onClose}>
    <h3 style={{ margin: '16px 0 8px', fontWeight: 800 }}>{title}</h3>
    <div className="mv-sub" style={{ marginBottom: 8 }}>Содержит персональные данные клиентов. Храните и передавайте только по необходимости (GDPR).</div>
    <textarea className="mv-input" readOnly style={{ height: 180, fontFamily: 'monospace', fontSize: 12 }} value={text} onFocus={e => e.currentTarget.select()} />
    <div className="mv-col" style={{ marginTop: 10 }}>
      <button className="mv-btn" onClick={copy}>{copied ? 'Скопировано ✓' : 'Копировать'}</button>
      <button className="mv-btn ghost" onClick={save}>Скачать .csv</button>
    </div>
  </Sheet>)
}
