'use client'
import { useEffect, useState } from 'react'
import { Notify, adminApi as api, eur } from '@/lib/shared'
import { parseMoney } from '@/lib/money'
import { Confirm, Empty, Icon, Loading, Sheet } from '../ui'
import { Chosen, ItemPicker } from './PicklistField'
import { Kv, Note, Tabs, dtDay, newKey } from './common'

type Props = { cities: any[]; onNotify: Notify }
const STATUS: Record<string, string> = { draft: 'Черновик', posted: 'Проведена', cancelled: 'Отменена', reversed: 'Сторнирована' }
const FILTERS: [string, string][] = [['', 'Все'], ['draft', 'Черновики'], ['posted', 'Проведены'], ['reversed', 'Сторно']]

// Закупка — не расход: товар становится себестоимостью, когда продан (FIFO). Доставка и допрасходы входят в себестоимость партии.
export default function PurchasesSection({ cities, onNotify }: Props) {
  const [tab, setTab] = useState('purchases'), [status, setStatus] = useState('')
  const [list, setList] = useState<any[] | null>(null), [suppliers, setSuppliers] = useState<any[]>([]), [accounts, setAccounts] = useState<any[]>([])
  const [form, setForm] = useState<any>(null), [sel, setSel] = useState<number | null>(null)

  const loadList = () => api('/api/admin/purchases' + (status ? '?status=' + status : '')).then(setList).catch(e => { setList(x => x ?? []); onNotify('Закупки не загружены: ' + e.message, 'err') })
  const loadSup = () => api('/api/admin/suppliers').then(setSuppliers).catch(e => onNotify('Поставщики не загружены: ' + e.message, 'err'))
  useEffect(() => { loadList() }, [status])
  useEffect(() => { loadSup(); api('/api/admin/cash/accounts').then(setAccounts).catch(() => {}) }, [])

  return (<>
    <div className="mv-row mv-between"><h1 className="mv-h1">Закупки</h1>
      {tab === 'purchases' && <button className="mv-btn sm" style={{ width: 'auto' }} onClick={() => setForm({ id: null, city_id: cities[0]?.id || '', supplier_id: '', date: '', shipping: '', extra: '', note: '', chosen: {} as Chosen, key: newKey() })}>Новая</button>}</div>
    <Tabs items={[['purchases', 'Закупки'], ['suppliers', 'Поставщики']]} value={tab} onChange={setTab} />

    {tab === 'purchases' && <>
      <div className="mv-chips" style={{ marginTop: 8 }}>{FILTERS.map(([k, l]) => <button key={k} className={'mv-pill' + (status === k ? ' on' : '')} onClick={() => setStatus(k)}>{l}</button>)}</div>
      {list === null && <Loading />}
      <div className="mv-col" style={{ marginTop: 10 }}>{(list || []).map(p => (
        <button key={p.id} className="mv-card tap mv-tap" onClick={() => setSel(p.id)}>
          <div className="mv-row mv-between"><b>{p.number}</b><b>{eur(+(p.total_cost ?? p.items_total ?? 0))}</b></div>
          <div className="mv-sub">{p.supplier || 'Без поставщика'} · {cities.find(c => c.id === p.city_id)?.name || p.city_id} · {dtDay(p.purchase_date)}</div>
          <div className="mv-sub" style={{ fontSize: 12, marginTop: 4 }}>{STATUS[p.status]} · {p.units} шт.{+p.shipping_cost + +p.extra_cost > 0 ? ` · доставка и допрасходы ${eur(+p.shipping_cost + +p.extra_cost)}` : ''}</div>
        </button>))}</div>
      {list && !list.length && <Empty icon={Icon.box(30)} title="Закупок нет" text="Нажмите «Новая», чтобы оформить поступление товара" />}
    </>}

    {tab === 'suppliers' && <SuppliersTab suppliers={suppliers} reload={loadSup} onNotify={onNotify} />}

    {form && <PurchaseForm form={form} setForm={setForm} cities={cities} suppliers={suppliers.filter(s => s.active)} onNotify={onNotify}
      onSaved={() => { setForm(null); loadList() }} />}
    {sel !== null && <PurchaseSheet id={sel} cities={cities} accounts={accounts} onNotify={onNotify}
      onClose={() => { setSel(null); loadList() }} onEdit={(f: any) => { setSel(null); setForm(f) }} />}
  </>)
}

function SuppliersTab({ suppliers, reload, onNotify }: { suppliers: any[]; reload: () => void; onNotify: Notify }) {
  const [name, setName] = useState(''), [contact, setContact] = useState(''), [busy, setBusy] = useState(false)
  const add = async () => {
    setBusy(true)
    try { await api('/api/admin/suppliers', { method: 'POST', body: JSON.stringify({ name: name.trim(), contact: contact.trim(), note: '' }) }); setName(''); setContact(''); onNotify('Поставщик добавлен'); reload() }
    catch (e: any) { onNotify('Не сохранено: ' + e.message, 'err') } finally { setBusy(false) }
  }
  const toggle = async (s: any) => {
    try { await api('/api/admin/suppliers/' + s.id, { method: 'PUT', body: JSON.stringify({ name: s.name, contact: s.contact, note: s.note, active: !s.active }) }); reload() }
    catch (e: any) { onNotify('Не сохранено: ' + e.message, 'err') }
  }
  return (<div className="mv-col" style={{ marginTop: 10 }}>
    {suppliers.map(s => <div key={s.id} className="mv-card mv-row mv-between" style={{ opacity: s.active ? 1 : 0.6 }}>
      <div className="mv-grow"><b>{s.name}</b><div className="mv-sub mv-trunc">{s.contact || '—'}</div></div>
      <button className="mv-btn ghost sm" style={{ width: 'auto' }} onClick={() => toggle(s)}>{s.active ? 'Скрыть' : 'Вернуть'}</button></div>)}
    <div className="mv-card mv-col" style={{ gap: 8 }}><b>Новый поставщик</b>
      <input className="mv-input" placeholder="Название" value={name} onChange={e => setName(e.target.value)} />
      <input className="mv-input" placeholder="Контакты (необязательно)" value={contact} onChange={e => setContact(e.target.value)} />
      <button className="mv-btn" disabled={busy || !name.trim()} onClick={add}>Добавить</button></div>
  </div>)
}

function PurchaseForm({ form, setForm, cities, suppliers, onNotify, onSaved }: any) {
  const [busy, setBusy] = useState(false)
  const set = (patch: any) => setForm({ ...form, ...patch })
  const items = Object.entries(form.chosen as Chosen)
  const ship = form.shipping === '' ? '0.00' : parseMoney(form.shipping), extra = form.extra === '' ? '0.00' : parseMoney(form.extra)
  const parsed = items.map(([id, c]) => ({ id, qty: parseInt(c.qty || '0', 10), price: parseMoney(c.price || '', 4) }))
  const itemsOk = parsed.length > 0 && parsed.every(p => p.qty > 0 && p.price !== null)
  const itemsSum = parsed.reduce((s, p) => s + (p.price ? p.qty * Number(p.price) : 0), 0)
  const save = async () => {
    if (!itemsOk || ship === null || extra === null) return onNotify('Проверьте количество и цены (до 4 знаков), доставку и допрасходы', 'err')
    setBusy(true)
    try {
      const body = { supplier_id: form.supplier_id ? Number(form.supplier_id) : null, city_id: form.city_id, purchase_date: form.date || null,
        shipping_cost: ship, extra_cost: extra, note: form.note.trim(), idempotency_key: form.key,
        items: parsed.map(p => ({ inventory_id: p.id, quantity: p.qty, unit_price: p.price })) }
      await api('/api/admin/purchases' + (form.id ? '/' + form.id : ''), { method: form.id ? 'PUT' : 'POST', body: JSON.stringify(body) })
      onNotify('Черновик закупки сохранён. Товар поступит на склад после проведения'); onSaved()
    } catch (e: any) { onNotify('Не сохранено: ' + e.message, 'err') } finally { setBusy(false) }
  }
  return (<Sheet onClose={() => setForm(null)}>
    <h3 style={{ margin: '16px 0 10px', fontWeight: 800 }}>{form.id ? 'Правка закупки' : 'Новая закупка'}</h3>
    <div className="mv-col" style={{ gap: 10 }}>
      <select className="mv-input" value={form.city_id} onChange={e => set({ city_id: e.target.value, chosen: {} })}>{cities.map((c: any) => <option key={c.id} value={c.id}>Склад: {c.name}</option>)}</select>
      <select className="mv-input" value={form.supplier_id} onChange={e => set({ supplier_id: e.target.value })}><option value="">Поставщик не указан</option>{suppliers.map((s: any) => <option key={s.id} value={s.id}>{s.name}</option>)}</select>
      <input className="mv-input" type="date" value={form.date} onChange={e => set({ date: e.target.value })} />
      <div className="mv-grid2"><input className="mv-input" inputMode="decimal" placeholder="Доставка, €" value={form.shipping} onChange={e => set({ shipping: e.target.value })} />
        <input className="mv-input" inputMode="decimal" placeholder="Допрасходы, €" value={form.extra} onChange={e => set({ extra: e.target.value })} /></div>
      <input className="mv-input" placeholder="Примечание" maxLength={500} value={form.note} onChange={e => set({ note: e.target.value })} />
      <b style={{ marginTop: 4 }}>Позиции (нажмите, чтобы выбрать; укажите шт. и закупочную цену за штуку)</b>
      <ItemPicker city={form.city_id} chosen={form.chosen} onChange={c => set({ chosen: c })} withPrice />
      <div className="mv-row mv-between"><span className="mv-muted">Товары</span><b>{eur(itemsSum)}</b></div>
      <div className="mv-sub" style={{ fontSize: 12 }}>Доставка и допрасходы распределяются по позициям пропорционально их стоимости и входят в себестоимость партии.</div>
      <button className="mv-btn" disabled={busy || !itemsOk || ship === null || extra === null} onClick={save}>Сохранить черновик</button>
    </div>
  </Sheet>)
}

function PurchaseSheet({ id, cities, accounts, onNotify, onClose, onEdit }: any) {
  const [p, setP] = useState<any>(null), [busy, setBusy] = useState(false)
  const [account, setAccount] = useState(''), [confirm, setConfirm] = useState<'post' | 'cancel' | 'reverse' | null>(null), [reason, setReason] = useState('')
  const [postKey] = useState(newKey), [revKey] = useState(newKey)
  const reload = () => api('/api/admin/purchases/' + id).then(setP).catch(e => onNotify('Закупка не загружена: ' + e.message, 'err'))
  useEffect(() => { reload() }, [id])
  const run = async (path: string, body: any, ok: string) => {
    setConfirm(null); setBusy(true)
    try { await api(`/api/admin/purchases/${id}/${path}`, { method: 'POST', body: JSON.stringify(body) }); onNotify(ok); await reload() }
    catch (e: any) { onNotify('Не выполнено: ' + e.message, 'err') } finally { setBusy(false) }
  }
  const payable = (accounts || []).filter((a: any) => a.active && !a.closed_at)
  const total = p ? (+p.items_total || p.items.reduce((s: number, i: any) => s + i.quantity * +i.unit_price, 0)) + +p.shipping_cost + +p.extra_cost : 0
  return (<Sheet onClose={onClose}>
    {!p && <Loading />}
    {p && <>
      <h2 style={{ margin: '16px 0 4px', fontSize: 22, fontWeight: 800 }}>{p.number}</h2>
      <div className="mv-sub">{STATUS[p.status]} · {dtDay(p.purchase_date)} · {cities.find((c: any) => c.id === p.city_id)?.name || p.city_id}</div>
      <div className="mv-col" style={{ gap: 8, marginTop: 12 }}>{p.items.map((i: any) => <div key={i.id} className="mv-card" style={{ padding: 12 }}>
        <div className="mv-row mv-between"><b className="mv-trunc">{i.product_name}{i.variant_name ? ' · ' + i.variant_name : ''}</b><span>{i.quantity} шт.</span></div>
        <div className="mv-sub" style={{ fontSize: 12 }}>цена поставщика {eur(+i.unit_price)}{i.landed_unit_cost != null ? ` · себестоимость партии ${(+i.landed_unit_cost).toFixed(4).replace('.', ',')} €/шт.` : ''}</div></div>)}</div>
      <div className="mv-card mv-col" style={{ gap: 8, marginTop: 12 }}>
        <Kv l="Доставка" v={eur(+p.shipping_cost)} /><Kv l="Допрасходы" v={eur(+p.extra_cost)} /><Kv l="Итого" v={<b>{eur(p.total_cost != null ? +p.total_cost : total)}</b>} />
        {p.reverse_reason && <Kv l="Причина сторно" v={p.reverse_reason} />}
      </div>
      {p.status === 'draft' && <div className="mv-col" style={{ marginTop: 12 }}>
        <label className="mv-label">Оплата со счёта (необязательно)</label>
        <select className="mv-input" value={account} onChange={e => setAccount(e.target.value)}><option value="">Без списания со счёта</option>
          {payable.map((a: any) => <option key={a.id} value={a.id}>{a.name} · {eur(+a.balance)}</option>)}</select>
        <button className="mv-btn" disabled={busy} onClick={() => setConfirm('post')}>Провести: товар на склад</button>
        <button className="mv-btn ghost" disabled={busy} onClick={() => onEdit({ id: p.id, city_id: p.city_id, supplier_id: p.supplier_id || '', date: p.purchase_date, shipping: String(p.shipping_cost), extra: String(p.extra_cost), note: p.note || '',
          chosen: Object.fromEntries(p.items.map((i: any) => [i.inventory_id, { qty: String(i.quantity), price: String(+i.unit_price) }])), key: newKey() })}>Править</button>
        <button className="mv-btn danger" disabled={busy} onClick={() => { setReason(''); setConfirm('cancel') }}>Отменить черновик</button></div>}
      {p.status === 'posted' && <div className="mv-col" style={{ marginTop: 12 }}>
        <Note>Сторно возможно, пока ни одна единица из партий не продана и не перемещена.</Note>
        <button className="mv-btn danger" disabled={busy} onClick={() => { setReason(''); setConfirm('reverse') }}>Сторно закупки</button></div>}
    </>}
    {confirm === 'post' && <Confirm title="Провести закупку?" text={`Товар поступит на склад, будут созданы партии по себестоимости. ${account ? 'Сумма спишется со счёта. ' : ''}Действие попадёт в журнал.`} ok="Провести"
      onOk={() => run('post', { account_id: account ? Number(account) : null, idempotency_key: postKey }, 'Закупка проведена, товар на складе')} onCancel={() => setConfirm(null)} />}
    {(confirm === 'cancel' || confirm === 'reverse') && <Sheet center onClose={() => setConfirm(null)}>
      <h3 style={{ margin: '8px 0' }}>{confirm === 'cancel' ? 'Отменить черновик' : 'Сторно закупки'}</h3>
      <input className="mv-input" placeholder="Причина (не менее 5 символов)" value={reason} onChange={e => setReason(e.target.value)} />
      <button className="mv-btn danger" style={{ marginTop: 10 }} disabled={busy || reason.trim().length < 5}
        onClick={() => confirm === 'cancel' ? run('cancel', { reason: reason.trim() }, 'Черновик отменён') : run('reverse', { reason: reason.trim(), idempotency_key: revKey }, 'Закупка сторнирована, товар снят со склада')}>Подтвердить</button>
    </Sheet>}
  </Sheet>)
}
