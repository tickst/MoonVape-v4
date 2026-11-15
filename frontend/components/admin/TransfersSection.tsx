'use client'
import { useEffect, useState } from 'react'
import { Notify, adminApi as api, eur } from '@/lib/shared'
import { Confirm, Empty, Icon, Loading, Sheet } from '../ui'
import { Chosen, ItemPicker } from './PicklistField'
import { Kv, Note, dt, newKey } from './common'

type Props = { cities: any[]; onNotify: Notify }
const STATUS: Record<string, string> = { draft: 'Черновик', in_transit: 'В пути', received: 'Получено', cancelled: 'Отменено' }
const FILTERS: [string, string][] = [['', 'Все'], ['draft', 'Черновики'], ['in_transit', 'В пути'], ['received', 'Получены']]

// Перемещение: отправка списывает товар по FIFO и «замораживает» его себестоимость, получение создаёт партии с теми же ценой и датой.
export default function TransfersSection({ cities, onNotify }: Props) {
  const [status, setStatus] = useState(''), [list, setList] = useState<any[] | null>(null)
  const [form, setForm] = useState<any>(null), [sel, setSel] = useState<number | null>(null)
  const nm = (id: string) => cities.find(c => c.id === id)?.name || id
  const load = () => api('/api/admin/stock-transfers' + (status ? '?status=' + status : '')).then(setList).catch(e => { setList(x => x ?? []); onNotify('Перемещения не загружены: ' + e.message, 'err') })
  useEffect(() => { load() }, [status])

  return (<>
    <div className="mv-row mv-between"><h1 className="mv-h1">Перемещения</h1>
      <button className="mv-btn sm" style={{ width: 'auto' }} disabled={cities.length < 2}
        onClick={() => setForm({ id: null, from: cities[0]?.id || '', to: cities[1]?.id || '', note: '', chosen: {} as Chosen, key: newKey() })}>Новое</button></div>
    <div className="mv-chips">{FILTERS.map(([k, l]) => <button key={k} className={'mv-pill' + (status === k ? ' on' : '')} onClick={() => setStatus(k)}>{l}</button>)}</div>
    {list === null && <Loading />}
    <div className="mv-col" style={{ marginTop: 10 }}>{(list || []).map(t => (
      <button key={t.id} className="mv-card tap mv-tap" onClick={() => setSel(t.id)}>
        <div className="mv-row mv-between"><b>{t.number}</b><span className={'mv-badge ' + (t.status === 'in_transit' ? 'processing' : t.status === 'received' ? 'completed' : t.status === 'cancelled' ? 'cancelled' : 'new')}>{STATUS[t.status]}</span></div>
        <div className="mv-sub">{nm(t.from_city)} → {nm(t.to_city)} · {t.units} шт.{+t.value > 0 ? ` · по себестоимости ${eur(+t.value)}` : ''}</div>
      </button>))}</div>
    {list && !list.length && <Empty icon={Icon.box(30)} title="Перемещений нет" text="Создайте перемещение между городами" />}

    {form && <TransferForm form={form} setForm={setForm} cities={cities} onNotify={onNotify} onSaved={() => { setForm(null); load() }} />}
    {sel !== null && <TransferSheet id={sel} nm={nm} onNotify={onNotify} onClose={() => { setSel(null); load() }}
      onEdit={(f: any) => { setSel(null); setForm(f) }} />}
  </>)
}

function TransferForm({ form, setForm, cities, onNotify, onSaved }: any) {
  const [busy, setBusy] = useState(false)
  const set = (patch: any) => setForm({ ...form, ...patch })
  const items = Object.entries(form.chosen as Chosen).map(([id, c]: any) => ({ inventory_id: id, quantity: parseInt(c.qty || '0', 10) }))
  const ok = form.from !== form.to && items.length > 0 && items.every(i => i.quantity > 0)
  const save = async () => {
    setBusy(true)
    try {
      await api('/api/admin/stock-transfers' + (form.id ? '/' + form.id : ''), { method: form.id ? 'PUT' : 'POST',
        body: JSON.stringify({ from_city: form.from, to_city: form.to, note: form.note.trim(), items, idempotency_key: form.key }) })
      onNotify('Черновик перемещения сохранён'); onSaved()
    } catch (e: any) { onNotify('Не сохранено: ' + e.message, 'err') } finally { setBusy(false) }
  }
  return (<Sheet onClose={() => setForm(null)}>
    <h3 style={{ margin: '16px 0 10px', fontWeight: 800 }}>{form.id ? 'Правка перемещения' : 'Новое перемещение'}</h3>
    <div className="mv-col" style={{ gap: 10 }}>
      <div className="mv-grid2">
        <select className="mv-input" value={form.from} onChange={e => set({ from: e.target.value, chosen: {} })}>{cities.map((c: any) => <option key={c.id} value={c.id}>Из: {c.name}</option>)}</select>
        <select className="mv-input" value={form.to} onChange={e => set({ to: e.target.value })}>{cities.map((c: any) => <option key={c.id} value={c.id}>В: {c.name}</option>)}</select></div>
      {form.from === form.to && <Note warn>Выберите разные города</Note>}
      <input className="mv-input" placeholder="Примечание" maxLength={500} value={form.note} onChange={e => set({ note: e.target.value })} />
      <b>Позиции склада «{cities.find((c: any) => c.id === form.from)?.name}»</b>
      <ItemPicker city={form.from} chosen={form.chosen} onChange={c => set({ chosen: c })} maxByStock />
      <button className="mv-btn" disabled={busy || !ok} onClick={save}>Сохранить черновик</button>
    </div>
  </Sheet>)
}

function TransferSheet({ id, nm, onNotify, onClose, onEdit }: any) {
  const [t, setT] = useState<any>(null), [busy, setBusy] = useState(false)
  const [confirm, setConfirm] = useState<'send' | 'receive' | 'cancel' | null>(null), [reason, setReason] = useState('')
  const [sendKey] = useState(newKey), [recvKey] = useState(newKey)
  const reload = () => api('/api/admin/stock-transfers/' + id).then(setT).catch(e => onNotify('Перемещение не загружено: ' + e.message, 'err'))
  useEffect(() => { reload() }, [id])
  const run = async (action: string, body: any, ok: string) => {
    setConfirm(null); setBusy(true)
    try { await api(`/api/admin/stock-transfers/${id}/${action}`, { method: 'POST', body: JSON.stringify(body) }); onNotify(ok); await reload() }
    catch (e: any) { onNotify('Не выполнено: ' + e.message, 'err') } finally { setBusy(false) }
  }
  return (<Sheet onClose={onClose}>
    {!t && <Loading />}
    {t && <>
      <h2 style={{ margin: '16px 0 4px', fontSize: 22, fontWeight: 800 }}>{t.number}</h2>
      <div className="mv-sub">{STATUS[t.status]} · {nm(t.from_city)} → {nm(t.to_city)}</div>
      <div className="mv-col" style={{ gap: 8, marginTop: 12 }}>{t.items.map((i: any) => <div key={i.id} className="mv-card mv-row mv-between" style={{ padding: 12 }}>
        <div className="mv-grow"><b className="mv-trunc">{i.product_name}{i.variant_name ? ' · ' + i.variant_name : ''}</b>{+i.cost > 0 && <div className="mv-sub" style={{ fontSize: 12 }}>себестоимость {eur(+i.cost)}</div>}</div><b>{i.quantity} шт.</b></div>)}</div>
      <div className="mv-card mv-col" style={{ gap: 8, marginTop: 12 }}>
        <Kv l="Создано" v={dt(t.created_at)} />{t.sent_at && <Kv l="Отправлено" v={dt(t.sent_at)} />}{t.received_at && <Kv l="Получено" v={dt(t.received_at)} />}
        {t.cancel_reason && <Kv l="Причина отмены" v={t.cancel_reason} />}{t.note && <Kv l="Примечание" v={t.note} />}</div>
      {t.status === 'in_transit' && <Note>Товар в пути: он не числится ни на одном складе, но учитывается в стоимости остатков.</Note>}
      <div className="mv-col" style={{ marginTop: 12 }}>
        {t.status === 'draft' && <><button className="mv-btn" disabled={busy} onClick={() => setConfirm('send')}>Отправить</button>
          <button className="mv-btn ghost" disabled={busy} onClick={() => onEdit({ id: t.id, from: t.from_city, to: t.to_city, note: t.note || '', key: newKey(),
            chosen: Object.fromEntries(t.items.map((i: any) => [i.from_inventory_id, { qty: String(i.quantity) }])) })}>Править</button></>}
        {t.status === 'in_transit' && <button className="mv-btn" disabled={busy} onClick={() => setConfirm('receive')}>Подтвердить получение</button>}
        {(t.status === 'draft' || t.status === 'in_transit') && <button className="mv-btn danger" disabled={busy} onClick={() => { setReason(''); setConfirm('cancel') }}>{t.status === 'draft' ? 'Отменить' : 'Отменить и вернуть на склад отправителя'}</button>}
      </div>
    </>}
    {confirm === 'send' && <Confirm title="Отправить товар?" text="Товар будет списан со склада отправителя (по FIFO). Количество не может быть больше свободного остатка." ok="Отправить" onOk={() => run('send', { idempotency_key: sendKey }, 'Отправлено, товар в пути')} onCancel={() => setConfirm(null)} />}
    {confirm === 'receive' && <Confirm title="Подтвердить получение?" text="Товар появится на складе назначения с прежней себестоимостью." ok="Получено" onOk={() => run('receive', { idempotency_key: recvKey }, 'Получение подтверждено')} onCancel={() => setConfirm(null)} />}
    {confirm === 'cancel' && <Sheet center onClose={() => setConfirm(null)}>
      <h3 style={{ margin: '8px 0' }}>Отмена перемещения</h3>
      <input className="mv-input" placeholder="Причина (не менее 5 символов)" value={reason} onChange={e => setReason(e.target.value)} />
      <button className="mv-btn danger" style={{ marginTop: 10 }} disabled={busy || reason.trim().length < 5} onClick={() => run('cancel', { reason: reason.trim() }, 'Перемещение отменено')}>Подтвердить</button></Sheet>}
  </Sheet>)
}
