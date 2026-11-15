'use client'
import { useEffect, useState } from 'react'
import { Notify, adminApi as api, adminText, eur } from '@/lib/shared'
import { parseMoney } from '@/lib/money'
import { Confirm, Empty, Icon, Loading, Sheet, StatusBadge } from '../ui'
import { SearchField } from './Filters'
import { CsvSheet, Kv, Note, Tabs, dt, dtDay } from './common'

type Props = { cities: any[]; catalog: any; onNotify: Notify }

const SORTS: [string, string][] = [['recent', 'Недавние'], ['spent', 'По сумме'], ['orders', 'По заказам']]
const ACTIVE: [string, string][] = [['', 'Все'], ['30', 'Активные 30 дн.'], ['90', 'Активные 90 дн.']]
const PRICE_STATUS: Record<string, string> = { active: 'Действует', disabled: 'Отключена', expired: 'Истекла', scheduled: 'Ещё не началась' }
const PAGE = 30

// CRM — только владелец. Персональные цены никогда не показываются администраторам городов и другим покупателям.
export default function CustomersSection({ cities, catalog, onNotify }: Props) {
  const [q, setQ] = useState(''), [sort, setSort] = useState('recent'), [active, setActive] = useState(''), [city, setCity] = useState('')
  const [rows, setRows] = useState<any[] | null>(null), [total, setTotal] = useState(0), [busy, setBusy] = useState(false)
  const [sel, setSel] = useState<string | null>(null), [csv, setCsv] = useState<string | null>(null)

  const query = (offset: number) => { const p = new URLSearchParams({ sort, limit: String(PAGE), offset: String(offset) }); if (q.trim()) p.set('q', q.trim()); if (active) p.set('active_days', active); if (city) p.set('city', city); return p }
  const load = (append = false) => {
    setBusy(true)
    api('/api/admin/customers?' + query(append ? rows?.length || 0 : 0)).then(r => { setTotal(r.total); setRows(append ? [...(rows || []), ...r.rows] : r.rows) })
      .catch(e => { setRows(x => x ?? []); onNotify('Клиенты не загружены: ' + e.message, 'err') }).finally(() => setBusy(false))
  }
  useEffect(() => { const t = setTimeout(() => load(false), 250); return () => clearTimeout(t) }, [q, sort, active, city])

  const exportCsv = async () => {
    try { const p = query(0); p.delete('limit'); p.delete('offset'); p.delete('sort'); setCsv(await adminText('/api/admin/customers/export?' + p)) }
    catch (e: any) { onNotify('Экспорт не выполнен: ' + e.message, 'err') }
  }
  const nameOf = (c: any) => [c.first_name, c.last_name].filter(Boolean).join(' ') || (c.username ? '@' + c.username : 'Без имени')

  return (<>
    <div className="mv-row mv-between"><h1 className="mv-h1">Клиенты</h1><button className="mv-btn ghost sm" style={{ width: 'auto' }} onClick={exportCsv}>CSV</button></div>
    <div className="mv-toolbar"><div className="mv-col">
      <SearchField value={q} onChange={setQ} placeholder="Имя, @username или Telegram ID" />
      <div className="mv-chips">{ACTIVE.map(([k, l]) => <button key={k} className={'mv-pill' + (active === k ? ' on' : '')} onClick={() => setActive(k)}>{l}</button>)}</div>
      <Tabs items={SORTS} value={sort} onChange={setSort} />
      <select className="mv-input sm" value={city} onChange={e => setCity(e.target.value)}><option value="">Все города</option>{cities.map(c => <option key={c.id} value={c.id}>{c.name}</option>)}</select>
    </div></div>

    {rows === null && <Loading />}
    <div className="mv-col" style={{ marginTop: 10 }}>{(rows || []).map(c => (
      <button key={c.id} className="mv-card tap mv-tap" onClick={() => setSel(c.id)}>
        <div className="mv-row mv-between"><b className="mv-trunc">{nameOf(c)}</b>
          <b>{eur(+c.spent)}</b></div>
        <div className="mv-sub mv-trunc">{c.username ? '@' + c.username + ' · ' : ''}ID {c.telegram_id}{c.city_id ? ' · ' + (cities.find(x => x.id === c.city_id)?.name || c.city_id) : ''}</div>
        <div className="mv-sub" style={{ marginTop: 4, fontSize: 12 }}>заказов {c.orders_count} · ср. чек {c.avg_check != null ? eur(+c.avg_check) : '—'} · последний {dtDay(c.last_order_at)}{c.personal_prices > 0 ? ` · 💎 ${c.personal_prices}` : ''}</div>
      </button>))}</div>
    {rows && !rows.length && <Empty icon={Icon.user(30)} title="Клиенты не найдены" text="Измените запрос или фильтры" />}
    {rows && rows.length < total && <button className="mv-btn ghost" style={{ marginTop: 10 }} disabled={busy} onClick={() => load(true)}>Показать ещё ({total - rows.length})</button>}

    {sel && <CustomerSheet id={sel} cities={cities} catalog={catalog} onNotify={onNotify} onClose={() => { setSel(null); load(false) }} />}
    {csv !== null && <CsvSheet title="Экспорт клиентов" text={csv} filename="moonvape-customers.csv" onClose={() => setCsv(null)} />}
  </>)
}

function CustomerSheet({ id, cities, catalog, onNotify, onClose }: { id: string; cities: any[]; catalog: any; onNotify: Notify; onClose: () => void }) {
  const [c, setC] = useState<any>(null), [busy, setBusy] = useState(false)
  const [edit, setEdit] = useState<any>(null)                       // { product_id, price, note, valid_until }
  const [del, setDel] = useState<any>(null)
  const reload = () => api('/api/admin/customers/' + id).then(setC).catch(e => onNotify('Профиль не загружен: ' + e.message, 'err'))
  useEffect(() => { reload() }, [id])
  const products: any[] = (catalog?.products || []).filter((p: any) => p.active !== false)

  const save = async () => {
    const price = parseMoney(edit.price)
    if (!edit.product_id || price === null) return onNotify('Выберите товар и введите цену (например, 7,50)', 'err')
    setBusy(true)
    try {
      const r = await api(`/api/admin/customers/${id}/prices`, { method: 'PUT', body: JSON.stringify({
        product_id: edit.product_id, price, note: edit.note.trim(), valid_until: edit.valid_until ? new Date(edit.valid_until + 'T23:59:59').toISOString() : null }) })
      onNotify(r.below_cost ? `Цена сохранена. ⚠ Она ниже себестоимости (${eur(+r.cost_price)}) — вы продаёте в убыток` : 'Персональная цена сохранена', r.below_cost ? 'err' : 'ok')
      setEdit(null); reload()
    } catch (e: any) { onNotify('Не сохранено: ' + e.message, 'err') } finally { setBusy(false) }
  }
  const toggle = async (p: any) => {
    setBusy(true)
    try { await api('/api/admin/customer-prices/' + p.id, { method: 'PATCH', body: JSON.stringify({ active: !p.active }) }); onNotify(p.active ? 'Цена отключена' : 'Цена включена'); reload() }
    catch (e: any) { onNotify('Не сохранено: ' + e.message, 'err') } finally { setBusy(false) }
  }
  const remove = async () => {
    const p = del; setDel(null); setBusy(true)
    try { await api('/api/admin/customer-prices/' + p.id, { method: 'DELETE' }); onNotify('Персональная цена удалена. Старые заказы не изменились'); reload() }
    catch (e: any) { onNotify('Не удалено: ' + e.message, 'err') } finally { setBusy(false) }
  }

  return (<Sheet onClose={onClose}>
    {!c && <Loading />}
    {c && <>
      <h2 style={{ margin: '16px 0 4px', fontSize: 22, fontWeight: 800 }}>{[c.first_name, c.last_name].filter(Boolean).join(' ') || 'Без имени'}</h2>
      <div className="mv-sub">{c.username ? '@' + c.username + ' · ' : ''}Telegram ID {c.telegram_id}</div>
      <div className="mv-card mv-col" style={{ gap: 8, marginTop: 12 }}>
        <Kv l="Город" v={cities.find(x => x.id === c.city_id)?.name || c.city_id || '—'} />
        <Kv l="Заказов (без отменённых)" v={c.orders_count} /><Kv l="Выдано" v={c.issued_count} />
        <Kv l="Всего куплено" v={eur(+c.spent)} /><Kv l="Средний чек" v={c.avg_check != null ? eur(+c.avg_check) : '—'} />
        <Kv l="Последний заказ" v={dt(c.last_order_at)} /><Kv l="Клиент с" v={dtDay(c.created_at)} />
        <Kv l="Согласие на сообщения" v={c.marketing_consent ? 'есть' : 'нет'} />
      </div>

      <div className="mv-row mv-between" style={{ marginTop: 18 }}><h3 className="mv-section-h" style={{ margin: 0 }}>💎 Персональные цены</h3>
        <button className="mv-btn sm" style={{ width: 'auto' }} onClick={() => setEdit({ product_id: '', price: '', note: '', valid_until: '' })}>Добавить</button></div>
      <div className="mv-sub" style={{ margin: '4px 0 8px' }}>Приоритет: персональная цена → оптовая ступень → розница. Видит только владелец. Старые заказы не меняются.</div>
      <div className="mv-col" style={{ gap: 8 }}>
        {c.prices.map((p: any) => (
          <div key={p.id} className="mv-card" style={{ padding: 12, opacity: p.status === 'active' ? 1 : 0.7, borderColor: p.below_cost ? 'rgba(255,107,107,.5)' : undefined }}>
            <div className="mv-row mv-between"><b className="mv-trunc">{p.product_name}</b><b className="mv-accent">{eur(+p.price)}</b></div>
            <div className="mv-sub" style={{ fontSize: 12, marginTop: 2 }}>стандарт {eur(+p.standard_price)} · {PRICE_STATUS[p.status] || p.status}{p.valid_until ? ' · до ' + dtDay(p.valid_until) : ''}</div>
            {p.below_cost && <div className="mv-danger" style={{ fontSize: 12, marginTop: 4 }}>⚠ Ниже себестоимости ({eur(+p.cost_price)}) — продажа в убыток</div>}
            {p.note && <div style={{ fontSize: 13, marginTop: 4 }}>{p.note}</div>}
            <div className="mv-row" style={{ gap: 6, marginTop: 8, flexWrap: 'wrap' }}>
              <button className="mv-btn ghost sm" style={{ width: 'auto' }} disabled={busy} onClick={() => setEdit({ product_id: p.product_id, price: String(p.price).replace('.', ','), note: p.note, valid_until: p.valid_until ? p.valid_until.slice(0, 10) : '' })}>Изменить</button>
              <button className="mv-btn ghost sm" style={{ width: 'auto' }} disabled={busy} onClick={() => toggle(p)}>{p.active ? 'Отключить' : 'Включить'}</button>
              <button className="mv-btn danger sm" style={{ width: 'auto' }} disabled={busy} onClick={() => setDel(p)}>Удалить</button>
            </div>
          </div>))}
        {!c.prices.length && <div className="mv-sub">Индивидуальных цен нет — клиент покупает по общим ценам.</div>}
      </div>

      {edit && <div className="mv-card mv-col" style={{ gap: 10, marginTop: 12 }}>
        <b>{c.prices.some((p: any) => p.product_id === edit.product_id) ? 'Изменить цену' : 'Новая цена'}</b>
        <select className="mv-input" value={edit.product_id} onChange={e => setEdit({ ...edit, product_id: e.target.value })}>
          <option value="">Товар…</option>{products.map((p: any) => <option key={p.id} value={p.id}>{p.name}{p.price != null ? ` · ${eur(+p.price)}` : ''}</option>)}</select>
        <input className="mv-input" inputMode="decimal" placeholder="Цена за штуку, € (например 7,50)" value={edit.price} onChange={e => setEdit({ ...edit, price: e.target.value })} />
        <input className="mv-input" placeholder="Примечание к договорённости" maxLength={500} value={edit.note} onChange={e => setEdit({ ...edit, note: e.target.value })} />
        <label className="mv-label">Действует до (необязательно)</label>
        <input className="mv-input" type="date" value={edit.valid_until} onChange={e => setEdit({ ...edit, valid_until: e.target.value })} />
        <div className="mv-row" style={{ gap: 8 }}>
          <button className="mv-btn" disabled={busy} onClick={save}>Сохранить</button>
          <button className="mv-btn ghost" onClick={() => setEdit(null)}>Отмена</button></div>
      </div>}

      <h3 className="mv-section-h" style={{ marginTop: 18 }}>История заказов</h3>
      <div className="mv-col" style={{ gap: 6 }}>{c.orders.map((o: any) => (
        <div key={o.id} className="mv-card mv-row mv-between" style={{ padding: 12 }}>
          <div><b>#{o.number}</b>{o.has_personal_price && ' 💎'}<div className="mv-sub" style={{ fontSize: 12 }}>{dt(o.created_at)} · {o.items} шт.</div></div>
          <div style={{ textAlign: 'right' }}><b>{eur(+o.total)}</b><div style={{ marginTop: 4 }}><StatusBadge status={o.status} /></div></div></div>))}
        {!c.orders.length && <div className="mv-sub">Заказов пока нет</div>}</div>
    </>}
    {del && <Confirm danger title="Удалить персональную цену?" text={`${del.product_name}: ${eur(+del.price)}. Уже оформленные заказы сохранят применённую цену. Действие попадёт в журнал.`} ok="Удалить" onOk={remove} onCancel={() => setDel(null)} />}
  </Sheet>)
}
