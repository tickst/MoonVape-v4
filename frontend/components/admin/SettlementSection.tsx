'use client'
import { useEffect, useState } from 'react'
import { Notify, adminApi as api, eur } from '@/lib/shared'
import { parseMoney } from '@/lib/money'
import { Confirm, Loading } from '../ui'
import { dtDay } from './common'

type Props = { role: 'owner' | 'city_admin'; cityId: string | null; cities: any[]; onNotify: Notify }

// Режим города хранится в БД (cities.finance_mode):
//   owner_operated — городом управляет владелец: деньги принадлежат владельцу, долга нет, передача не нужна и запрещена;
//   city_managed   — задолженность = остаток городской кассы: что город получил и должен передать владельцу.
export default function SettlementSection({ role, cityId, cities, onNotify }: Props) {
  const [data, setData] = useState<any>(null)
  const [city, setCity] = useState('')
  const [amount, setAmount] = useState(''), [note, setNote] = useState('')
  const [key, setKey] = useState(() => crypto.randomUUID())
  const [confirm, setConfirm] = useState(false), [busy, setBusy] = useState(false)

  const load = () => {
    setData(null)
    const path = role === 'owner' ? '/api/admin/settlement' : `/api/admin/settlement?city=${cityId || ''}`
    api(path).then(d => { setData(d); const l = Array.isArray(d) ? d : [d]; setCity(c => c || l.find((x: any) => x.transfer_required)?.city_id || '') })
      .catch(e => onNotify('Не удалось загрузить взаиморасчёты: ' + e.message, 'err'))
  }
  useEffect(load, [])

  const list: any[] = data ? (Array.isArray(data) ? data : [data]) : []
  const managed = list.filter(s => s.transfer_required)
  const nameOf = (id: string) => cities.find(c => c.id === id)?.name || id
  const amtStr = parseMoney(amount), amt = amtStr ? Number(amtStr) : 0
  const selected = managed.find(x => x.city_id === city)

  const send = async () => {
    setConfirm(false); setBusy(true)
    try {
      const r = await api('/api/admin/settlement/transfers', { method: 'POST', body: JSON.stringify({ city_id: city, amount: amtStr, note: note.trim(), idempotency_key: key }) })
      onNotify(r.duplicate ? 'Эта передача уже учтена — повторного списания нет' : 'Передача зафиксирована')
      setAmount(''); setNote(''); setKey(crypto.randomUUID()); load()
    } catch (e: any) { onNotify('Не сохранено: ' + e.message, 'err') } finally { setBusy(false) }
  }

  return (<>
    <h1 className="mv-h1">Взаиморасчёты</h1>
    {!data && <Loading />}
    {data && <div className="mv-col" style={{ gap: 12, marginTop: 12 }}>
      {list.map(s => s.transfer_required ? (
        <div key={s.city_id} className="mv-card" style={{ borderColor: s.owed > 0 ? 'rgba(245,166,74,.4)' : undefined }}>
          <div className="mv-city-tag">{(s.city_name || nameOf(s.city_id)).toUpperCase()} · УПРАВЛЯЕТСЯ ГОРОДОМ</div>
          <div className="mv-sub">Должен передать владельцу</div>
          <div className="mv-price lg" style={{ marginTop: 4 }}>{eur(+s.owed || 0)}</div>
          <div className="mv-col" style={{ gap: 6, marginTop: 12, fontSize: 14 }}>
            {s.cash_account_id != null ? <>
              <Line l="Начальный остаток кассы" v={eur(+s.opening)} />
              <Line l="Выручка (оплаченные заказы)" v={'+' + eur(+s.sales)} />
              {+s.deposits > 0 && <Line l="Внесено в кассу" v={'+' + eur(+s.deposits)} />}
              {+s.expenses > 0 && <Line l="Расходы города" v={'−' + eur(+s.expenses)} />}
              {+s.withdrawals > 0 && <Line l="Изъято из кассы" v={'−' + eur(+s.withdrawals)} />}
              {+s.purchases > 0 && <Line l="Оплата закупок" v={'−' + eur(+s.purchases)} />}
              {+s.adjustments !== 0 && <Line l="Корректировки" v={eur(+s.adjustments)} />}
              <Line l="Передано владельцу (после начала учёта)" v={'−' + eur(+s.transferred - +s.legacy_transferred)} />
              {+s.legacy_transferred > 0 && <div className="mv-sub" style={{ fontSize: 12 }}>Ранее передано (до учёта по счетам): {eur(+s.legacy_transferred)} — уже учтено в начальном остатке.</div>}
            </> : <>
              <Line l="Получено от покупателей (оплачено)" v={eur(+s.collected)} />
              <Line l="Возвращено покупателям" v={'−' + eur(+s.refunded)} />
              <Line l="Уже передано владельцу" v={'−' + eur(+s.transferred)} /></>}
          </div>
          {s.transfers?.length > 0 && <>
            <div className="mv-sub" style={{ margin: '12px 0 6px' }}>Передачи</div>
            {s.transfers.slice(0, 10).map((t: any) => <div key={t.id} className="mv-row mv-between" style={{ fontSize: 13, padding: '4px 0', opacity: t.reversed ? 0.55 : 1 }}>
              <span>{dtDay(t.created_at)}{t.note ? ' · ' + t.note : ''}{t.reversed ? ' · сторно' : ''}{t.source === 'legacy' ? ' · до v4' : ''}</span><span>{eur(+t.amount)}</span></div>)}
          </>}
        </div>
      ) : (
        <div key={s.city_id} className="mv-card">
          <div className="mv-city-tag">{(s.city_name || nameOf(s.city_id)).toUpperCase()} · УПРАВЛЯЕТСЯ ВЛАДЕЛЬЦЕМ</div>
          <div style={{ fontWeight: 800, marginTop: 4 }}>{s.message}</div>
          <div className="mv-sub" style={{ marginTop: 6, fontSize: 13 }}>Выручка и расходы города полностью учитываются в общей прибыли. Задолженности перед владельцем нет.</div>
          {s.cash_balance != null && <div className="mv-row mv-between" style={{ marginTop: 10, fontSize: 14 }}><span className="mv-muted">Остаток кассы города</span><b>{eur(+s.cash_balance)}</b></div>}
        </div>))}
    </div>}

    {role === 'owner' && data && managed.length > 0 && <div className="mv-card" style={{ marginTop: 16 }}>
      <b>Зафиксировать получение денег</b>
      <div className="mv-sub" style={{ margin: '6px 0 12px' }}>Деньги переводятся с кассы города на банковский счёт владельца (не доход и не расход). Повторная отправка с тем же ключом не спишет деньги дважды.</div>
      <div className="mv-col" style={{ gap: 10 }}>
        <select className="mv-input" value={city} onChange={e => setCity(e.target.value)}>{managed.map(c => <option key={c.city_id} value={c.city_id}>{c.city_name || nameOf(c.city_id)}</option>)}</select>
        <input className="mv-input" inputMode="decimal" placeholder="Сумма (€), например 100,00" value={amount} onChange={e => setAmount(e.target.value)} />
        <input className="mv-input" placeholder="Комментарий (необязательно)" value={note} onChange={e => setNote(e.target.value)} />
        {selected && <div className="mv-sub">Задолженность: {eur(+selected.owed)}</div>}
        {selected && amt > +selected.owed && <div className="mv-danger" style={{ fontSize: 13 }}>Сумма больше задолженности</div>}
        <button className="mv-btn" disabled={busy || !(amt > 0) || !selected || amt > +selected.owed} onClick={() => setConfirm(true)}>Зафиксировать</button>
      </div>
    </div>}
    {confirm && <Confirm title="Зафиксировать получение?" text={`${eur(amt)} от ${nameOf(city)}. Задолженность уменьшится. Ошибку исправляют сторно в «Финансы → Счета».`} ok="Зафиксировать" onOk={send} onCancel={() => setConfirm(false)} />}
  </>)
}

const Line = ({ l, v }: { l: string; v: string }) => <div className="mv-row mv-between"><span className="mv-muted">{l}</span><span>{v}</span></div>
