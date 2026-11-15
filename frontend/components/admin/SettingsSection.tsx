'use client'
import { useEffect, useState } from 'react'
import { Notify, adminApi as api } from '@/lib/shared'
import { Confirm, Loading, Sheet } from '../ui'
import BroadcastSection from './BroadcastSection'
import CitiesSection from './CitiesSection'
import { Kv, Note, Tabs, dt, dtDay, newKey } from './common'

type Role = 'owner' | 'city_admin'
type Props = { role: Role; cityId: string | null; cities: any[]; catalog: any; onNotify: Notify; onRefresh: () => void; reloadCities: () => void }

const MODE: Record<string, string> = { owner_operated: 'Управляется владельцем', city_managed: 'Управляется городом' }

export default function SettingsSection(props: Props) {
  const { role } = props
  const [tab, setTab] = useState(role === 'owner' ? 'cities' : 'notify')
  return (<>
    <h1 className="mv-h1">{role === 'owner' ? 'Настройки' : 'Оповещения'}</h1>
    {role === 'owner' && <Tabs items={[['cities', 'Города'], ['notify', 'Оповещения'], ['rules', 'Правила']]} value={tab} onChange={setTab} />}
    <div style={{ marginTop: 10 }}>
      {tab === 'cities' && role === 'owner' && <CitiesTab {...props} />}
      {tab === 'notify' && <NotifyTab {...props} />}
      {tab === 'rules' && role === 'owner' && <RulesTab onNotify={props.onNotify} />}
    </div>
  </>)
}

// ---------------------------------------------------------------- Города: режим управления
function CitiesTab({ cities, onNotify, reloadCities }: Props) {
  const [modes, setModes] = useState<any[] | null>(null), [sel, setSel] = useState<any>(null)
  const load = () => api('/api/admin/cities/modes').then(setModes).catch(e => { setModes([]); onNotify('Режимы городов не загружены: ' + e.message, 'err') })
  useEffect(() => { load() }, [])
  return (<>
    {!modes && <Loading />}
    <div className="mv-col">{(modes || []).map(c => (
      <div key={c.city_id} className="mv-card">
        <div className="mv-row mv-between"><b>{c.name}</b><span className="mv-badge new">{MODE[c.finance_mode]}</span></div>
        <div className="mv-sub" style={{ fontSize: 13, marginTop: 6 }}>{c.finance_mode === 'owner_operated'
          ? 'Выручка принадлежит владельцу. Задолженности нет, передача денег не требуется.'
          : 'Администратор города принимает деньги и передаёт их владельцу. Ведётся задолженность.'}</div>
        <button className="mv-btn ghost sm" style={{ marginTop: 10 }} onClick={() => setSel(c)}>Изменить режим</button>
        {c.history.length > 0 && <div className="mv-sub" style={{ fontSize: 12, marginTop: 8 }}>Последнее изменение: {dtDay(c.history[0].changed_at)} · {c.history[0].reason}</div>}
      </div>))}</div>
    <h2 className="mv-h2" style={{ marginTop: 18 }}>Каналы</h2>
    <CitiesSection cities={cities} onNotify={onNotify} onRefresh={reloadCities} />
    {sel && <ModeSheet city={sel} onNotify={onNotify} onClose={() => setSel(null)} onDone={() => { setSel(null); load(); reloadCities() }} />}
  </>)
}

function ModeSheet({ city, onNotify, onClose, onDone }: any) {
  const target = city.finance_mode === 'owner_operated' ? 'city_managed' : 'owner_operated'
  const [reason, setReason] = useState(''), [confirm, setConfirm] = useState(false), [busy, setBusy] = useState(false), [key] = useState(newKey)
  const go = async () => {
    setConfirm(false); setBusy(true)
    try { await api(`/api/admin/cities/${city.city_id}/mode`, { method: 'PUT', body: JSON.stringify({ mode: target, reason: reason.trim(), idempotency_key: key }) }); onNotify('Режим города изменён'); onDone() }
    catch (e: any) { onNotify('Не изменено: ' + e.message, 'err') } finally { setBusy(false) }
  }
  return (<Sheet onClose={onClose}>
    <h3 style={{ margin: '16px 0 8px', fontWeight: 800 }}>{city.name}: {MODE[target].toLowerCase()}</h3>
    {target === 'city_managed'
      ? <Note>Касса города закрывается и остаётся у владельца; начнётся новая касса с нуля. Старые деньги не превращаются в долг города. Исторические операции не меняются.</Note>
      : <Note warn>Перейти можно, только если город полностью рассчитался (остаток кассы = 0). Иначе сначала зафиксируйте передачу денег. Исторические операции не меняются.</Note>}
    <input className="mv-input" style={{ marginTop: 10 }} placeholder="Причина (не менее 5 символов)" maxLength={300} value={reason} onChange={e => setReason(e.target.value)} />
    <button className="mv-btn" style={{ marginTop: 10 }} disabled={busy || reason.trim().length < 5} onClick={() => setConfirm(true)}>Изменить режим</button>
    {confirm && <Confirm title="Изменить режим города?" text={`${city.name}: ${MODE[city.finance_mode]} → ${MODE[target]}. Действие попадёт в журнал.`} ok="Изменить" onOk={go} onCancel={() => setConfirm(false)} />}
  </Sheet>)
}

// ---------------------------------------------------------------- Оповещения
function NotifyTab(p: Props) {
  const { role, cityId, cities, onNotify } = p
  const [journal, setJournal] = useState<any[] | null>(null), [stats, setStats] = useState<any>(null), [flag, setFlag] = useState<boolean | null>(null), [confirm, setConfirm] = useState(false)
  const loadFlag = () => role === 'owner' && api('/api/admin/settings').then(s => setFlag(!!s.broadcasts_enabled)).catch(() => {})
  useEffect(() => {
    api('/api/admin/broadcasts' + (role === 'city_admin' ? `?city=${cityId || ''}` : '')).then(setJournal).catch(e => { setJournal([]); onNotify('Журнал рассылок не загружен: ' + e.message, 'err') })
    if (role === 'owner') { api('/api/admin/notifications').then(setStats).catch(() => {}); loadFlag() }
  }, [])
  const setBroadcasts = async (v: boolean) => {
    setConfirm(false)
    try { await api('/api/admin/settings/broadcasts_enabled', { method: 'PUT', body: JSON.stringify({ value: v }) }); setFlag(v); onNotify(v ? 'Рассылки включены' : 'Рассылки выключены') }
    catch (e: any) { onNotify('Не сохранено: ' + e.message, 'err') }
  }
  const failed = stats?.by_kind?.filter((k: any) => k.status === 'failed').reduce((s: number, k: any) => s + k.n, 0) || 0
  return (<>
    {role === 'owner' && flag !== null && <div className="mv-card" style={{ borderColor: flag ? undefined : 'rgba(245,166,74,.5)' }}>
      <div className="mv-row mv-between"><b>Рассылки по наличию</b><span className={'mv-badge ' + (flag ? 'completed' : 'processing')}>{flag ? 'Включены' : 'Выключены'}</span></div>
      <div className="mv-sub" style={{ fontSize: 13, margin: '6px 0 10px' }}>Рассылка уходит только тем, кто дал согласие. Включайте только после юридической проверки рекламы и рассылок по продукции для вейпинга (см. docs/LEGAL_CHECKLIST.md).</div>
      <button className="mv-btn ghost sm" onClick={() => flag ? setBroadcasts(false) : setConfirm(true)}>{flag ? 'Выключить' : 'Включить…'}</button>
    </div>}
    {confirm && <Confirm title="Включить рассылки?" text="Вы подтверждаете, что реклама и рассылки проверены на соответствие праву Германии и ЕС (в т. ч. ограничения рекламы табачных изделий и e-сигарет, UWG, GDPR)." ok="Включить" onOk={() => setBroadcasts(true)} onCancel={() => setConfirm(false)} />}

    <div style={{ marginTop: 12 }}><BroadcastSection role={role} cityId={cityId} cities={cities} catalog={p.catalog} onNotify={onNotify} /></div>

    <h2 className="mv-h2" style={{ marginTop: 18 }}>Журнал рассылок</h2>
    {!journal && <Loading />}
    <div className="mv-col" style={{ gap: 6 }}>{(journal || []).map(b => (
      <div key={b.id} className="mv-card" style={{ padding: 12 }}>
        <div className="mv-row mv-between"><b>{cities.find(c => c.id === b.city_id)?.name || b.city_id}</b><span className="mv-sub" style={{ fontSize: 12 }}>{dt(b.created_at)}</span></div>
        <div className="mv-sub mv-trunc" style={{ fontSize: 13 }}>{b.preview}</div>
        <div className="mv-sub" style={{ fontSize: 12, marginTop: 4 }}>получателей {b.recipients} · доставлено {b.sent} · ошибок {b.failed} · в очереди {b.pending}</div>
      </div>))}{journal && !journal.length && <div className="mv-sub">Рассылок не было</div>}</div>

    {role === 'owner' && stats && <>
      <h2 className="mv-h2" style={{ marginTop: 18 }}>Очередь уведомлений (7 дней)</h2>
      <div className="mv-card mv-col" style={{ gap: 6 }}>
        {stats.by_kind.map((k: any, i: number) => <Kv key={i} l={`${k.kind} · ${k.status}`} v={k.n} />)}
        {!stats.by_kind.length && <div className="mv-sub">Сообщений не было</div>}
        {stats.overdue_pending > 0 && <Note warn>В очереди зависло сообщений: {stats.overdue_pending}</Note>}
        {failed > 0 && <Note warn>Не доставлено: {failed}. Последние ошибки ниже.</Note>}
      </div>
      {stats.failed_recent.length > 0 && <div className="mv-col" style={{ gap: 6, marginTop: 8 }}>{stats.failed_recent.slice(0, 10).map((f: any) => (
        <div key={f.id} className="mv-card" style={{ padding: 12 }}><div className="mv-row mv-between"><b>{f.kind}</b><span className="mv-sub" style={{ fontSize: 12 }}>{dt(f.created_at)}</span></div>
          <div className="mv-sub" style={{ fontSize: 12 }}>попыток {f.attempts}{f.last_error ? ' · ' + f.last_error : ''}</div></div>))}</div>}
    </>}
  </>)
}

// ---------------------------------------------------------------- Правила
function RulesTab({ onNotify }: { onNotify: Notify }) {
  const [s, setS] = useState<any>(null), [thr, setThr] = useState('')
  const load = () => api('/api/admin/settings').then(v => { setS(v); setThr(String(v.low_stock_threshold ?? 2)) }).catch(e => onNotify('Настройки не загружены: ' + e.message, 'err'))
  useEffect(() => { load() }, [])
  const put = async (key: string, value: any, ok: string) => {
    try { await api('/api/admin/settings/' + key, { method: 'PUT', body: JSON.stringify({ value }) }); onNotify(ok); load() }
    catch (e: any) { onNotify('Не сохранено: ' + e.message, 'err') }
  }
  if (!s) return <Loading />
  const n = parseInt(thr, 10)
  return (<div className="mv-col">
    <div className="mv-card">
      <b>Проверка возраста при выдаче</b>
      <div className="mv-sub" style={{ fontSize: 13, margin: '6px 0 10px' }}>Если включено, заказ нельзя выдать, пока администратор не отметил «возраст проверен по документу». Простая кнопка «мне 18» в приложении не считается проверкой.</div>
      <button className="mv-btn ghost sm" onClick={() => put('require_age_check_on_issue', !s.require_age_check_on_issue, s.require_age_check_on_issue ? 'Проверка при выдаче выключена' : 'Проверка при выдаче включена')}>
        {s.require_age_check_on_issue ? 'Включено — выключить' : 'Выключено — включить'}</button></div>
    <div className="mv-card mv-col" style={{ gap: 8 }}>
      <b>Порог низкого остатка</b>
      <div className="mv-sub" style={{ fontSize: 13 }}>После выдачи заказа, если свободный остаток позиции не больше порога, владелец и администратор города получают сообщение.</div>
      <div className="mv-row" style={{ gap: 8 }}><input className="mv-input sm" inputMode="numeric" value={thr} onChange={e => setThr(e.target.value.replace(/\D/g, ''))} />
        <button className="mv-btn sm" style={{ width: 'auto' }} disabled={!(n >= 0 && n <= 50) || n === s.low_stock_threshold} onClick={() => put('low_stock_threshold', n, 'Порог сохранён')}>Сохранить</button></div></div>
  </div>)
}
