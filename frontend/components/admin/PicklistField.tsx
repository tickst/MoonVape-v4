'use client'
import { useEffect, useState } from 'react'
import { adminApi as api } from '@/lib/shared'
import { SearchField, matchText } from './Filters'

/** Выбор позиций склада города с количеством/ценой. `fields` — какие числовые поля показывать у выбранной позиции. */
export type PickRow = { inventory_id: string; product_name: string; variant_name?: string | null; available: number; quantity: number }
export type Chosen = Record<string, { qty: string; price?: string }>

export function ItemPicker({ city, chosen, onChange, withPrice, maxByStock }: {
  city: string; chosen: Chosen; onChange: (c: Chosen) => void; withPrice?: boolean; maxByStock?: boolean
}) {
  const [rows, setRows] = useState<PickRow[] | null>(null), [q, setQ] = useState(''), [err, setErr] = useState('')
  useEffect(() => { setRows(null); setErr(''); if (city) api('/api/admin/inventory?city=' + city).then(setRows).catch(e => setErr(e.message)) }, [city])
  const label = (r: PickRow) => r.product_name + (r.variant_name ? ' · ' + r.variant_name : '')
  const list = (rows || []).filter(r => matchText(q, r.product_name, r.variant_name))
  const set = (id: string, patch: Partial<{ qty: string; price: string }> | null) => {
    const n = { ...chosen }; if (patch === null) delete n[id]; else n[id] = { qty: '', price: '', ...n[id], ...patch }; onChange(n)
  }
  if (!city) return <div className="mv-sub">Сначала выберите город</div>
  if (err) return <div className="mv-note">{err}</div>
  return (<div className="mv-col" style={{ gap: 6 }}>
    <SearchField value={q} onChange={setQ} placeholder="Найти позицию" />
    {rows === null && <div className="mv-sub">Загрузка…</div>}
    {list.slice(0, 60).map(r => { const c = chosen[r.inventory_id]; return (
      <div key={r.inventory_id} className="mv-card" style={{ padding: 10, borderColor: c ? 'var(--accent)' : undefined }}>
        <div className="mv-row mv-between" style={{ gap: 8 }}>
          <button className="mv-link mv-grow" style={{ textAlign: 'left', color: 'var(--text)' }} onClick={() => set(r.inventory_id, c ? null : { qty: '1' })}>
            <b className="mv-trunc" style={{ display: 'block' }}>{label(r)}</b>
            <span className="mv-sub" style={{ fontSize: 12 }}>на складе {r.quantity} · доступно {r.available}</span></button>
          {c && <div className="mv-row" style={{ gap: 6, flexShrink: 0 }}>
            <input className="mv-input sm" style={{ width: 64, textAlign: 'right' }} inputMode="numeric" placeholder="шт." value={c.qty}
              onChange={e => set(r.inventory_id, { qty: e.target.value.replace(/\D/g, '') })} />
            {withPrice && <input className="mv-input sm" style={{ width: 84, textAlign: 'right' }} inputMode="decimal" placeholder="€/шт" value={c.price}
              onChange={e => set(r.inventory_id, { price: e.target.value })} />}
          </div>}
        </div>
        {c && maxByStock && Number(c.qty) > r.available && <div className="mv-danger" style={{ fontSize: 12, marginTop: 4 }}>Больше, чем доступно ({r.available})</div>}
      </div>) })}
    {rows && list.length > 60 && <div className="mv-sub">Показаны первые 60 — уточните поиск</div>}
  </div>)
}
