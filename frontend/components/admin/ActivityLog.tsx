'use client'
import { useEffect, useState } from 'react'
import { Notify, adminApi as api } from '@/lib/shared'
import { Loading } from '../ui'
import { PeriodBar, Tabs, dt, usePeriod } from './common'

const SOURCES: [string, string][] = [['', 'Всё'], ['audit', 'Изменения'], ['order', 'Заказы'], ['stock', 'Склад'], ['finance', 'Финансы'], ['cash', 'Деньги']]
const ACTION: Record<string, string> = {
  customer_price_create: 'Персональная цена: создана', customer_price_update: 'Персональная цена: изменена', customer_price_toggle: 'Персональная цена: вкл/выкл',
  customer_price_delete: 'Персональная цена: удалена', city_mode_change: 'Режим города изменён', cash_transfer: 'Перевод между счетами', cash_transfer_reverse: 'Сторно перевода',
  cash_adjust: 'Корректировка остатка', cash_account_create: 'Счёт создан', cash_account_toggle: 'Счёт включён/отключён', purchase_post: 'Закупка проведена',
  purchase_cancel: 'Закупка отменена', purchase_reverse: 'Закупка сторнирована', transfer_send: 'Перемещение отправлено', transfer_receive: 'Перемещение получено',
  transfer_cancel: 'Перемещение отменено', stock_set: 'Остаток изменён вручную', fifo_self_heal: 'Автокоррекция партий (FIFO)', product_update: 'Товар изменён',
  variant_price: 'Цена варианта изменена', variant_rename: 'Вариант переименован', category_create: 'Категория создана', category_update: 'Категория изменена',
  setting_change: 'Настройка изменена', order_issued: 'Заказ выдан', order_cancelled: 'Заказ отменён', order_approve_prices: 'Цены заказа согласованы',
  order_age_checked: 'Возраст проверен', customers_export: 'Экспорт клиентов', finance_failed: 'Финансовая операция не выполнена', broadcast_create: 'Рассылка создана',
  supplier_create: 'Поставщик добавлен',
}

// Единый журнал действий: кто, что и когда. Только чтение.
export default function ActivityLog({ cities, onNotify }: { cities: any[]; onNotify: Notify }) {
  const p = usePeriod('7d'), [source, setSource] = useState(''), [city, setCity] = useState(''), [rows, setRows] = useState<any[] | null>(null)
  useEffect(() => {
    if (p.bad) return
    setRows(null)
    const q = new URLSearchParams({ date_from: p.from, date_to: p.to }); if (source) q.set('source', source); if (city) q.set('city', city)
    api('/api/admin/activity?' + q).then(setRows).catch(e => { setRows([]); onNotify('Журнал не загружен: ' + e.message, 'err') })
  }, [p.from, p.to, source, city])
  return (<>
    <PeriodBar p={p} />
    <div style={{ marginTop: 8 }}><Tabs items={SOURCES} value={source} onChange={setSource} /></div>
    <select className="mv-input sm" style={{ marginTop: 8 }} value={city} onChange={e => setCity(e.target.value)}><option value="">Все города</option>{cities.map(c => <option key={c.id} value={c.id}>{c.name}</option>)}</select>
    {rows === null && !p.bad && <Loading />}
    <div className="mv-col" style={{ gap: 6, marginTop: 10 }}>{(rows || []).map((r, i) => (
      <div key={i} className="mv-card" style={{ padding: 12 }}>
        <div className="mv-row mv-between"><b>{ACTION[r.action] || r.action}</b><span className="mv-sub" style={{ fontSize: 11 }}>{r.source}</span></div>
        <div className="mv-sub" style={{ fontSize: 12 }}>{dt(r.ts)} · исполнитель {r.actor && r.actor !== 'null' ? r.actor : '—'}{r.city_id ? ' · ' + (cities.find(c => c.id === r.city_id)?.name || r.city_id) : ''}</div>
        {r.detail && <div className="mv-sub" style={{ fontSize: 12, marginTop: 4, overflowWrap: 'anywhere' }}>{brief(r.detail)}</div>}
      </div>))}
      {rows && !rows.length && <div className="mv-sub">Записей за период нет</div>}</div>
  </>)
}

const brief = (d: any): string => {
  const flat = (o: any): string => o && typeof o === 'object'
    ? Object.entries(o).filter(([, v]) => v !== null && v !== '' && v !== undefined).map(([k, v]) => `${k}: ${typeof v === 'object' ? flat(v) : v}`).join(', ') : String(o ?? '')
  return flat(d).slice(0, 300)
}
