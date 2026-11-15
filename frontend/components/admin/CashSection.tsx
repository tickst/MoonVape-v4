'use client'
import { useEffect, useState } from 'react'
import { Notify, adminApi as api, eur } from '@/lib/shared'
import { parseMoney } from '@/lib/money'
import { Confirm, Loading, Sheet } from '../ui'
import { Note, PeriodBar, dt, newKey, usePeriod } from './common'

type Props = { cities: any[]; onNotify: Notify; onChanged?: () => void }
const KIND: Record<string, string> = { city_cash: 'Касса города', owner_bank: 'Банк владельца', owner_cash: 'Наличные владельца', other: 'Другой счёт' }
const ROW: Record<string, string> = { sale: 'Продажа (выручка)', deposit: 'Внесение', withdrawal: 'Изъятие', expense: 'Расход', transfer_in: 'Перевод: приход', transfer_out: 'Перевод: расход',
  adjustment: 'Корректировка остатка', purchase: 'Оплата закупки' }
// Эти движения денег не являются доходом или расходом бизнеса.
const NOT_PNL = new Set(['deposit', 'withdrawal', 'transfer_in', 'transfer_out', 'adjustment', 'purchase'])

export default function CashSection({ cities, onNotify, onChanged }: Props) {
  const [accounts, setAccounts] = useState<any[] | null>(null)
  const [act, setAct] = useState<{ kind: 'transfer' | 'move' | 'adjust' | 'create'; account?: any } | null>(null), [open, setOpen] = useState<any>(null)
  const load = () => api('/api/admin/cash/accounts').then(setAccounts).catch(e => { setAccounts(x => x ?? []); onNotify('Счета не загружены: ' + e.message, 'err') })
  useEffect(() => { load() }, [])
  const changed = () => { load(); onChanged?.() }
  const cityName = (id: string) => cities.find(c => c.id === id)?.name || id
  const live = (accounts || []).filter(a => !a.closed_at)
  const total = live.reduce((s, a) => s + +a.balance, 0)

  return (<>
    <div className="mv-card" style={{ marginTop: 10 }}>
      <div className="mv-sub">Всего на активных счетах</div><div className="mv-price lg">{eur(total)}</div>
      <div className="mv-sub" style={{ fontSize: 12, marginTop: 4 }}>Остаток = стартовый + выручка кассы города + движение по счёту. Переводы между счетами в прибыль не входят.</div>
    </div>
    <div className="mv-row" style={{ gap: 8, margin: '10px 0', flexWrap: 'wrap' }}>
      <button className="mv-btn sm" style={{ width: 'auto' }} onClick={() => setAct({ kind: 'transfer' })}>Перевод</button>
      <button className="mv-btn ghost sm" style={{ width: 'auto' }} onClick={() => setAct({ kind: 'create' })}>Новый счёт</button>
    </div>
    {accounts === null && <Loading />}
    <div className="mv-col">{(accounts || []).map(a => (
      <div key={a.id} className="mv-card" style={{ opacity: a.closed_at || !a.active ? 0.65 : 1 }}>
        <button className="mv-link" style={{ width: '100%', textAlign: 'left', color: 'var(--text)', padding: 0 }} onClick={() => setOpen(a)}>
          <div className="mv-row mv-between"><b>{a.name}</b><b className="mv-accent">{eur(+a.balance)}</b></div>
          <div className="mv-sub" style={{ fontSize: 12 }}>{KIND[a.kind]}{a.city_id ? ' · ' + cityName(a.city_id) : ''}{a.closed_at ? ' · закрыта' : ''}{!a.active && !a.closed_at ? ' · отключена' : ''}</div>
          {a.city_mode === 'owner_operated' && !a.closed_at && <div className="mv-sub" style={{ fontSize: 12 }}>Город управляется владельцем: деньги принадлежат владельцу, передача не требуется</div>}
          {a.city_mode === 'city_managed' && !a.closed_at && <div className="mv-sub" style={{ fontSize: 12 }}>Остаток — сумма, которую город должен передать владельцу</div>}
        </button>
        {a.active && <div className="mv-row" style={{ gap: 6, marginTop: 8, flexWrap: 'wrap' }}>
          <button className="mv-btn ghost sm" style={{ width: 'auto' }} onClick={() => setAct({ kind: 'move', account: a })}>Внести / изъять</button>
          <button className="mv-btn ghost sm" style={{ width: 'auto' }} onClick={() => setAct({ kind: 'adjust', account: a })}>Корректировка</button></div>}
      </div>))}</div>

    {act?.kind === 'transfer' && <TransferForm accounts={live.filter(a => a.active)} onNotify={onNotify} onDone={() => { setAct(null); changed() }} onClose={() => setAct(null)} />}
    {act?.kind === 'move' && <MoveForm account={act.account} onNotify={onNotify} onDone={() => { setAct(null); changed() }} onClose={() => setAct(null)} />}
    {act?.kind === 'adjust' && <AdjustForm account={act.account} onNotify={onNotify} onDone={() => { setAct(null); changed() }} onClose={() => setAct(null)} />}
    {act?.kind === 'create' && <CreateForm onNotify={onNotify} onDone={() => { setAct(null); changed() }} onClose={() => setAct(null)} />}
    {open && <Statement account={open} onNotify={onNotify} onClose={() => { setOpen(null); changed() }} />}
  </>)
}

function useAction(onNotify: Notify, onDone: () => void) {
  const [busy, setBusy] = useState(false), [key, setKey] = useState(newKey)
  const run = async (path: string, method: string, body: any, ok: string) => {
    setBusy(true)
    try { const r = await api(path, { method, body: JSON.stringify({ ...body, idempotency_key: key }) }); onNotify(r?.duplicate ? 'Эта операция уже проведена — повтора нет' : ok); setKey(newKey()); onDone() }
    catch (e: any) { onNotify('Не выполнено: ' + e.message, 'err') } finally { setBusy(false) }
  }
  return { busy, run }
}

function TransferForm({ accounts, onNotify, onDone, onClose }: any) {
  const [from, setFrom] = useState(accounts[0]?.id || ''), [to, setTo] = useState(accounts[1]?.id || ''), [amount, setAmount] = useState(''), [reason, setReason] = useState('')
  const [confirm, setConfirm] = useState(false), { busy, run } = useAction(onNotify, onDone)
  const amt = parseMoney(amount), fromA = accounts.find((a: any) => a.id === Number(from)), toA = accounts.find((a: any) => a.id === Number(to))
  return (<Sheet onClose={onClose}>
    <h3 style={{ margin: '16px 0 8px', fontWeight: 800 }}>Перевод между счетами</h3>
    <Note>Перевод — не доход и не расход. В выручку и прибыль не входит.</Note>
    <div className="mv-col" style={{ gap: 10, marginTop: 10 }}>
      <select className="mv-input" value={from} onChange={e => setFrom(e.target.value)}>{accounts.map((a: any) => <option key={a.id} value={a.id}>Откуда: {a.name} · {eur(+a.balance)}</option>)}</select>
      <select className="mv-input" value={to} onChange={e => setTo(e.target.value)}>{accounts.map((a: any) => <option key={a.id} value={a.id}>Куда: {a.name}</option>)}</select>
      <input className="mv-input" inputMode="decimal" placeholder="Сумма, €" value={amount} onChange={e => setAmount(e.target.value)} />
      <input className="mv-input" placeholder="Причина / комментарий" maxLength={300} value={reason} onChange={e => setReason(e.target.value)} />
      {fromA && amt && Number(amt) > +fromA.balance && <Note warn>Недостаточно средств на счёте «{fromA.name}»</Note>}
      <button className="mv-btn" disabled={busy || !amt || Number(amt) <= 0 || from === to || (fromA && Number(amt) > +fromA.balance)} onClick={() => setConfirm(true)}>Перевести</button>
    </div>
    {confirm && <Confirm title="Выполнить перевод?" text={`${eur(Number(amt))}: ${fromA?.name} → ${toA?.name}. Операцию можно исправить только сторно.`} ok="Перевести" onCancel={() => setConfirm(false)}
      onOk={() => { setConfirm(false); run('/api/admin/cash/transfers', 'POST', { from_account_id: Number(from), to_account_id: Number(to), amount: amt, reason: reason.trim() }, 'Перевод выполнен') }} />}
  </Sheet>)
}

function MoveForm({ account, onNotify, onDone, onClose }: any) {
  const [op, setOp] = useState<'cash_in' | 'cash_out'>('cash_in'), [amount, setAmount] = useState(''), [desc, setDesc] = useState('')
  const [confirm, setConfirm] = useState(false), { busy, run } = useAction(onNotify, onDone)
  const amt = parseMoney(amount)
  return (<Sheet onClose={onClose}>
    <h3 style={{ margin: '16px 0 8px', fontWeight: 800 }}>{account.name}</h3>
    <Note>Внесение и изъятие — движение денег, не доход и не расход. Расходы бизнеса записывайте в «Финансы → Сводка».</Note>
    <div className="mv-col" style={{ gap: 10, marginTop: 10 }}>
      <select className="mv-input" value={op} onChange={e => setOp(e.target.value as any)}><option value="cash_in">Внесение денег</option><option value="cash_out">Изъятие денег</option></select>
      <input className="mv-input" inputMode="decimal" placeholder="Сумма, €" value={amount} onChange={e => setAmount(e.target.value)} />
      <input className="mv-input" placeholder="Причина" maxLength={300} value={desc} onChange={e => setDesc(e.target.value)} />
      <button className="mv-btn" disabled={busy || !amt || Number(amt) <= 0} onClick={() => setConfirm(true)}>Записать</button>
    </div>
    {confirm && <Confirm title={op === 'cash_in' ? 'Внести деньги?' : 'Изъять деньги?'} text={`${eur(Number(amt))} · ${account.name}. Запись неизменяема; ошибку исправляют сторно.`} ok="Записать" onCancel={() => setConfirm(false)}
      onOk={() => { setConfirm(false); run('/api/admin/finance/entries', 'POST', { op_type: op, amount: amt, city_id: account.city_id || null, category: '', description: desc.trim(), account_id: account.id }, 'Операция записана') }} />}
  </Sheet>)
}

function AdjustForm({ account, onNotify, onDone, onClose }: any) {
  const [sign, setSign] = useState<'+' | '-'>('+'), [amount, setAmount] = useState(''), [reason, setReason] = useState('')
  const [confirm, setConfirm] = useState(false), { busy, run } = useAction(onNotify, onDone)
  const amt = parseMoney(amount)
  return (<Sheet onClose={onClose}>
    <h3 style={{ margin: '16px 0 8px', fontWeight: 800 }}>Корректировка: {account.name}</h3>
    <Note>Для приведения учёта к реальному остатку (пересчёт кассы, начальный остаток). Причина обязательна. Не доход и не расход.</Note>
    <div className="mv-col" style={{ gap: 10, marginTop: 10 }}>
      <select className="mv-input" value={sign} onChange={e => setSign(e.target.value as any)}><option value="+">Увеличить остаток</option><option value="-">Уменьшить остаток</option></select>
      <input className="mv-input" inputMode="decimal" placeholder="Сумма, €" value={amount} onChange={e => setAmount(e.target.value)} />
      <input className="mv-input" placeholder="Причина (не менее 5 символов)" maxLength={300} value={reason} onChange={e => setReason(e.target.value)} />
      <button className="mv-btn" disabled={busy || !amt || Number(amt) <= 0 || reason.trim().length < 5} onClick={() => setConfirm(true)}>Применить</button>
    </div>
    {confirm && <Confirm title="Скорректировать остаток?" text={`${sign}${eur(Number(amt))} на счёте «${account.name}». Действие попадёт в журнал.`} ok="Применить" onCancel={() => setConfirm(false)}
      onOk={() => { setConfirm(false); run(`/api/admin/cash/accounts/${account.id}/adjust`, 'POST', { amount: (sign === '-' ? '-' : '') + amt, reason: reason.trim() }, 'Остаток скорректирован') }} />}
  </Sheet>)
}

function CreateForm({ onNotify, onDone, onClose }: any) {
  const [name, setName] = useState(''), [kind, setKind] = useState('owner_bank'), [opening, setOpening] = useState('0')
  const [busy, setBusy] = useState(false), amt = parseMoney(opening)
  const save = async () => {
    setBusy(true)
    try { await api('/api/admin/cash/accounts', { method: 'POST', body: JSON.stringify({ name: name.trim(), kind, opening_balance: amt }) }); onNotify('Счёт создан'); onDone() }
    catch (e: any) { onNotify('Не создан: ' + e.message, 'err') } finally { setBusy(false) }
  }
  return (<Sheet onClose={onClose}>
    <h3 style={{ margin: '16px 0 10px', fontWeight: 800 }}>Новый счёт</h3>
    <div className="mv-col" style={{ gap: 10 }}>
      <input className="mv-input" placeholder="Название" maxLength={80} value={name} onChange={e => setName(e.target.value)} />
      <select className="mv-input" value={kind} onChange={e => setKind(e.target.value)}><option value="owner_bank">Банковский счёт</option><option value="owner_cash">Наличные владельца</option><option value="other">Другой</option></select>
      <label className="mv-label">Начальный баланс, €</label>
      <input className="mv-input" inputMode="decimal" value={opening} onChange={e => setOpening(e.target.value)} />
      <button className="mv-btn" disabled={busy || !name.trim() || !amt} onClick={save}>Создать</button></div>
  </Sheet>)
}

function Statement({ account, onNotify, onClose }: { account: any; onNotify: Notify; onClose: () => void }) {
  const p = usePeriod('30d'), [data, setData] = useState<any>(null), [n, setN] = useState(0)
  const [rev, setRev] = useState<any>(null), [reason, setReason] = useState(''), [revKey, setRevKey] = useState(newKey), [busy, setBusy] = useState(false)
  useEffect(() => {
    if (p.bad) return
    setData(null)
    api(`/api/admin/cash/accounts/${account.id}/statement?date_from=${p.from}&date_to=${p.to}`).then(setData).catch(e => onNotify('Выписка не загружена: ' + e.message, 'err'))
  }, [p.from, p.to, n])
  const reverse = async () => {
    setBusy(true)
    try {
      const r = rev.row
      if (r.transfer_id) await api(`/api/admin/cash/transfers/${r.transfer_id}/reverse`, { method: 'POST', body: JSON.stringify({ reason: reason.trim(), idempotency_key: revKey }) })
      else await api(`/api/admin/finance/entries/${r.finance_entry_id}/reverse`, { method: 'POST', body: JSON.stringify({ reason: reason.trim(), idempotency_key: revKey }) })
      onNotify('Сторно записано. Исходная запись остаётся в журнале'); setRev(null); setReason(''); setRevKey(newKey()); setN(x => x + 1)
    } catch (e: any) { onNotify('Сторно не записано: ' + e.message, 'err') } finally { setBusy(false) }
  }
  return (<Sheet onClose={onClose}>
    <h3 style={{ margin: '16px 0 4px', fontWeight: 800 }}>{account.name}</h3>
    {data && <div className="mv-price lg">{eur(+data.balance)}</div>}
    <div style={{ margin: '10px 0' }}><PeriodBar p={p} /></div>
    {!data && !p.bad && <Loading />}
    <div className="mv-col" style={{ gap: 6 }}>{(data?.rows || []).map((r: any, i: number) => {
      const canRev = !r.reverses_id && !r.reversed && (r.transfer_id || r.finance_entry_id)
      return (<div key={(r.id ?? 's') + '-' + i} className="mv-card" style={{ padding: 12, opacity: r.reversed ? 0.6 : 1 }}>
        <div className="mv-row mv-between"><b>{r.reverses_id ? 'Сторно: ' : ''}{ROW[r.kind] || r.kind}</b><b style={{ color: +r.amount >= 0 ? 'var(--success)' : 'var(--danger)' }}>{+r.amount > 0 ? '+' : ''}{eur(+r.amount)}</b></div>
        <div className="mv-sub" style={{ fontSize: 12 }}>{dt(r.occurred_at)}{r.reason ? ' · ' + r.reason : ''}{r.reversed ? ' · сторнировано' : ''}{NOT_PNL.has(r.kind) ? ' · вне прибыли' : ''}</div>
        {canRev && rev?.row !== r && <button className="mv-link" onClick={() => { setRev({ row: r }); setReason('') }}>Сторно</button>}
        {rev?.row === r && <div className="mv-col" style={{ gap: 6, marginTop: 6 }}>
          <input className="mv-input sm" placeholder="Причина сторно (обязательна)" value={reason} onChange={e => setReason(e.target.value)} />
          <div className="mv-row" style={{ gap: 6 }}><button className="mv-btn sm" style={{ width: 'auto' }} disabled={busy || reason.trim().length < 5} onClick={reverse}>Записать сторно</button>
            <button className="mv-btn ghost sm" style={{ width: 'auto' }} onClick={() => setRev(null)}>Отмена</button></div></div>}
      </div>)
    })}{data && !data.rows.length && <div className="mv-sub">Движений за период нет</div>}</div>
  </Sheet>)
}
