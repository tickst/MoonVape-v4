'use client'
import { useEffect, useState } from 'react'
import { Notify, adminApi as api, eur } from '@/lib/shared'
import { Loading } from '../ui'
import { Note, PeriodBar, Tabs, usePeriod } from './common'

type Props = { cities: any[]; catalog: any; onNotify: Notify }
const LOW_MARGIN = 20 // % — порог «низкая маржа»
const money = (v: any) => (v == null ? '—' : eur(+v))

// Аналитика: прибыльность товаров и городов, остатки по себестоимости, товары без продаж и с низкой маржой. Только владелец.
export default function AnalyticsSection({ cities, catalog, onNotify }: Props) {
  const [view, setView] = useState('products'), p = usePeriod('30d')
  const [city, setCity] = useState(''), [categoryId, setCategoryId] = useState('')
  const [products, setProducts] = useState<any[] | null>(null), [summary, setSummary] = useState<any>(null)
  const [filter, setFilter] = useState<'all' | 'low' | 'nosales' | 'stock'>('all')
  const [val, setVal] = useState<any>(null), [check, setCheck] = useState<any[] | null>(null)

  useEffect(() => {
    if (p.bad) return
    const q = new URLSearchParams({ date_from: p.from, date_to: p.to }); if (city) q.set('city', city); if (categoryId) q.set('category_id', categoryId)
    setProducts(null); setSummary(null)
    api('/api/admin/finance/products?' + q).then(setProducts).catch(e => { setProducts([]); onNotify('Товары не загружены: ' + e.message, 'err') })
    const sq = new URLSearchParams({ date_from: p.from, date_to: p.to }); if (city) sq.set('city', city)
    api('/api/admin/finance/summary?' + sq).then(setSummary).catch(e => onNotify('Отчёт не загружен: ' + e.message, 'err'))
  }, [p.from, p.to, city, categoryId])
  useEffect(() => {
    if (view !== 'stock') return
    api('/api/admin/stock/valuation').then(setVal).catch(e => onNotify('Остатки не загружены: ' + e.message, 'err'))
    api('/api/admin/stock/check').then(setCheck).catch(() => setCheck([]))
  }, [view])

  const rows = (products || []).filter((r: any) =>
    filter === 'low' ? r.units > 0 && r.margin_pct != null && r.margin_pct < LOW_MARGIN
    : filter === 'nosales' ? r.units === 0 && r.stock_units > 0
    : filter === 'stock' ? r.stock_units > 0 : true)
  const cats: any[] = catalog?.categories || []

  return (<>
    <h1 className="mv-h1">Аналитика</h1>
    <Tabs items={[['products', 'Товары'], ['cities', 'Города'], ['stock', 'Остатки']]} value={view} onChange={setView} />

    {view !== 'stock' && <div style={{ marginTop: 10 }}><PeriodBar p={p} />
      <div className="mv-col" style={{ gap: 8, marginTop: 10 }}>
        <select className="mv-input sm" value={city} onChange={e => setCity(e.target.value)}><option value="">Вся сеть</option>{cities.map(c => <option key={c.id} value={c.id}>{c.name}</option>)}</select>
        {view === 'products' && <select className="mv-input sm" value={categoryId} onChange={e => setCategoryId(e.target.value)}><option value="">Все категории</option>{cats.map(c => <option key={c.id} value={c.id}>{c.name}</option>)}</select>}
      </div></div>}

    {view === 'products' && <>
      <div className="mv-chips" style={{ marginTop: 10 }}>{([['all', 'Все'], ['low', `Маржа < ${LOW_MARGIN}%`], ['nosales', 'Без продаж (есть остаток)'], ['stock', 'С остатком']] as [string, string][]).map(([k, l]) =>
        <button key={k} className={'mv-pill' + (filter === k ? ' on' : '')} onClick={() => setFilter(k as any)}>{l}</button>)}</div>
      {products === null && !p.bad && <Loading />}
      <div className="mv-col" style={{ gap: 6, marginTop: 8 }}>{rows.map((r: any) => (
        <div key={r.product_id} className="mv-card" style={{ padding: 12 }}>
          <div className="mv-row mv-between"><b className="mv-trunc">{r.name}{!r.active && ' (архив)'}</b><span>{money(r.revenue)}</span></div>
          <div className="mv-sub" style={{ fontSize: 12, marginTop: 4 }}>продано {r.units} шт. · прибыль {money(r.gross_profit)} · маржа {r.margin_pct != null ? r.margin_pct + '%' : '—'}
            {r.cogs_missing_lines > 0 && ' · нет себестоимости'}</div>
          <div className="mv-sub" style={{ fontSize: 12 }}>на складе {r.stock_units} шт. · {money(r.stock_value)} по себестоимости</div>
        </div>))}
        {products && !rows.length && <div className="mv-sub">Нет товаров по выбранному фильтру</div>}</div>
    </>}

    {view === 'cities' && <>
      {!summary && !p.bad && <Loading />}
      <div className="mv-col" style={{ marginTop: 10 }}>{(summary?.by_city || []).map((b: any) => {
        const m = b.metrics; return (<div key={b.city_id} className="mv-card">
          <div className="mv-row mv-between"><b>{b.city}</b><b className="mv-accent">{money(m.net_profit)}</b></div>
          <div className="mv-sub" style={{ fontSize: 12 }}>{b.mode === 'owner_operated' ? 'управляется владельцем' : 'управляется городом'} · чистая прибыль</div>
          <div className="mv-col" style={{ gap: 4, marginTop: 8, fontSize: 14 }}>
            <div className="mv-row mv-between"><span className="mv-muted">Выручка</span><span>{money(m.revenue)}</span></div>
            <div className="mv-row mv-between"><span className="mv-muted">Себестоимость</span><span>{money(m.cogs)}</span></div>
            <div className="mv-row mv-between"><span className="mv-muted">Валовая прибыль</span><span>{money(m.gross_profit)}{m.margin_pct != null ? ` (${m.margin_pct}%)` : ''}</span></div>
            <div className="mv-row mv-between"><span className="mv-muted">Расходы города</span><span>{money(m.expenses)}</span></div>
            <div className="mv-row mv-between"><span className="mv-muted">Заказов · средний чек</span><span>{m.orders} · {money(m.avg_check)}</span></div></div>
        </div>) })}</div>
      {summary?.unallocated_expenses != null && +summary.unallocated_expenses !== 0 && <Note>Расходы без города: {money(summary.unallocated_expenses)} — в города не распределены.</Note>}
    </>}

    {view === 'stock' && <>
      {!val && <Loading />}
      {val && <><div className="mv-card" style={{ marginTop: 10 }}>
        <div className="mv-sub">Всего по себестоимости (склады + в пути)</div><div className="mv-price lg">{money(val.total_value)}</div>
        <div className="mv-sub" style={{ fontSize: 12 }}>{val.total_units} шт.</div></div>
        <div className="mv-col" style={{ marginTop: 10 }}>{val.by_city.map((c: any) => <div key={c.city_id} className="mv-card">
          <div className="mv-row mv-between"><b>{c.name}</b><b>{money(c.value)}</b></div>
          <div className="mv-sub" style={{ fontSize: 12 }}>{c.units} шт.{c.unknown_cost_units > 0 ? ` · ${c.unknown_cost_units} шт. без известной себестоимости` : ''}</div></div>)}
          {val.in_transit.units > 0 && <div className="mv-card"><div className="mv-row mv-between"><b>В пути</b><b>{money(val.in_transit.value)}</b></div><div className="mv-sub" style={{ fontSize: 12 }}>{val.in_transit.units} шт.</div></div>}</div></>}
      {check && check.length > 0 && <Note warn>Расхождение учёта партий: у {check.length} поз. остаток склада не равен сумме партий. Продажи не блокируются (недостающее достраивается автоматически и пишется в журнал), но сообщите разработчику.</Note>}
      {check && check.length === 0 && val && <div className="mv-sub" style={{ marginTop: 10, fontSize: 12 }}>Проверка партий: остатки складов совпадают с партиями.</div>}
    </>}
  </>)
}
