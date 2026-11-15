// Общие утилиты (UI-слой). Бизнес-логика живёт в backend и RPC Supabase.
export const eur = (n: number) => (Number.isFinite(+n) ? +n : 0).toFixed(2).replace('.', ',') + ' €'

// Статусы заказа (миграция 0012): new → prepared → issued; cancelled из new и prepared.
export const ST: Record<string, string> = {
  new: 'Новый', prepared: 'Подготовлен', issued: 'Выдан', cancelled: 'Отменён',
}
// Классы бейджей из globals.css: new / processing / completed / cancelled
export const ST_CLASS: Record<string, string> = {
  new: 'new', prepared: 'processing', issued: 'completed', cancelled: 'cancelled',
}
// Сообщения об ошибках из backend (detail) и RPC.
export const ERR: Record<string, string> = {
  insufficient_stock: 'Недостаточно товара в выбранном городе — обновите корзину',
  wholesale_manager: 'От 50 шт. — цена по договорённости с менеджером.',
  item_not_found: 'Товар больше недоступен',
  city_mismatch: 'Товар относится к другому городу. Проверьте корзину.',
  city_required: 'Сначала выберите город',
  age_required: 'Подтвердите, что вам есть 18 лет',
  price_missing: 'Цена товара ещё не указана — оформление недоступно',
  forbidden: 'Нет доступа',
  bad_city: 'Такого города нет',
  empty_order: 'Корзина пуста',
  bad_status: 'В этом статусе оплату отметить нельзя',
  bad_transition: 'Этот переход статуса недопустим',
  below_reserved: 'Остаток не может быть меньше резерва под заказы',
  exceeds_balance: 'Сумма больше текущей задолженности города',
  bad_amount: 'Укажите сумму больше нуля',
  broadcast_cooldown: 'Рассылка по этому городу уже запускалась недавно. Подождите 10 минут.',
  catalog_changed: 'Каталог изменился после предпросмотра. Обновите предпросмотр.',
  nothing_to_announce: 'Нет доступных товаров для этой рассылки',
  empty_text: 'Текст рассылки пуст',
  bad_transfer: 'Перемещение возможно только между разными городами одной позиции',
  bad_kind: 'Неверный тип операции',
  bad_quantity: 'Некорректное количество',
  not_admin: 'У вас нет доступа к админ-панели',
  edit_not_allowed: 'Заказ уже подготовлен — изменить его нельзя. Напишите менеджеру.',
  order_not_found: 'Заказ не найден',
  approval_required: 'Заказ ждёт согласования цены владельцем',
  not_approval_order: 'Этот заказ не требует согласования',
  prices_incomplete: 'Укажите цену для каждой позиции',
  tier_price_missing: 'Не задана оптовая цена для одного из товаров',
  bad_tiers: 'Некорректная сетка оптовых цен',
  bad_tier: 'Такой ступени у товара нет',
  bad_period: 'Проверьте период: дата «по» не раньше даты «с», период не длиннее года',
  bad_op: 'Неизвестный тип операции',
  bad_text: 'Слишком длинное описание или категория',
  category_required: 'Укажите категорию расхода',
  reason_required: 'Причина сторно: от 5 до 300 символов',
  entry_not_found: 'Запись журнала не найдена',
  already_reversed: 'Эта запись уже сторнирована',
  cannot_reverse_reversal: 'Сторно нельзя отменить сторно-записью',
  // v4: счета, режим города, закупки, перемещения, персональные цены
  transfer_not_required: 'Для этого города передача денег не требуется: им управляет владелец',
  settle_first: 'Сначала рассчитайтесь с городом: остаток кассы должен быть нулевым',
  mode_unchanged: 'Город уже работает в этом режиме',
  bad_mode: 'Неизвестный режим города',
  insufficient_funds: 'Недостаточно средств на счёте',
  account_not_found: 'Счёт не найден',
  account_inactive: 'Счёт отключён',
  account_required: 'Выберите счёт для этой операции',
  account_city_mismatch: 'Эта касса относится к другому городу',
  bad_accounts: 'Выберите два разных счёта',
  name_taken: 'Такое название уже используется',
  bad_name: 'Некорректное название',
  balance_not_zero: 'Нельзя отключить счёт с ненулевым остатком',
  city_account_locked: 'Городскую кассу отключить нельзя — смените режим города',
  owner_account_missing: 'Не найден банковский счёт владельца',
  cash_account_missing: 'У города нет открытой кассы',
  supplier_not_found: 'Поставщик не найден',
  duplicate_item: 'Позиция указана дважды',
  batch_consumed: 'Часть товара из этой закупки уже продана или перемещена — сторно невозможно',
  dest_inventory_missing: 'В городе назначения нет такой позиции склада',
  below_cost: 'Цена ниже себестоимости',
  bad_price: 'Некорректная цена',
  broadcasts_disabled: 'Рассылки выключены в настройках (требуется юридическая проверка)',
  age_check_required: 'Сначала подтвердите проверку возраста по документу',
  audit_immutable: 'Журнал изменять нельзя',
}
export const tg = () => (typeof window !== 'undefined' ? (window as any).Telegram?.WebApp : undefined)
export const API = process.env.NEXT_PUBLIC_API_URL || ''
export const SB = process.env.NEXT_PUBLIC_SUPABASE_URL
export const imgUrl = (p?: string) => (p ? `${SB}/storage/v1/object/public/product-images/${p}` : null)
export const variantLabel = (i: any) => [i.variant, i.flavor].filter(Boolean).join(' · ')
export const haptic = (k: 'light' | 'success' | 'error' = 'light') => {
  const h = tg()?.HapticFeedback
  if (!h) return
  k === 'light' ? h.impactOccurred?.('light') : h.notificationOccurred?.(k)
}

// Запросы админки: Authorization: tma <initData>. Ошибка: detail из backend или код.
export async function adminApi(path: string, opt: any = {}) {
  const r = await fetch(API + path, { ...opt, headers: { 'Content-Type': 'application/json', Authorization: 'tma ' + tg().initData } })
  const j = await r.json().catch(() => ({}))
  if (!r.ok) throw new Error(ERR[j.detail] || (typeof j.detail === 'string' ? j.detail : 'Ошибка сети'))
  return j
}
export type Notify = (msg: string, kind?: 'ok' | 'err') => void

// Текстовый ответ (CSV). Те же заголовки авторизации, что и у adminApi.
export async function adminText(path: string): Promise<string> {
  const r = await fetch(API + path, { headers: { Authorization: 'tma ' + tg().initData } })
  if (!r.ok) { const j = await r.json().catch(() => ({})); throw new Error(ERR[j.detail] || (typeof j.detail === 'string' ? j.detail : 'Ошибка сети')) }
  return r.text()
}
