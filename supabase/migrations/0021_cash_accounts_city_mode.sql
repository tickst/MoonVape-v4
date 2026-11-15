-- =============================================================================
-- MoonVape v4 · миграция 0021 · режим управления городом, денежные счета, взаиморасчёты
-- Запускать ПОСЛЕ 0020. Один Run в SQL Editor. Перед запуском — резервная копия БД.
-- Выполнять, когда никто не выдаёт заказы (несколько секунд): стартовый остаток счёта Hannover
-- фиксируется на момент запуска.
--
-- МОДЕЛЬ
--   cities.finance_mode (хранится в БД, а не выводится из названия города):
--     owner_operated — городом управляет владелец. Деньги города принадлежат владельцу,
--                      задолженности нет, передача денег не требуется и запрещена на уровне БД.
--     city_managed   — городом управляет администратор. Задолженность = остаток городской кассы
--                      (что город держит у себя и должен передать владельцу).
--   cash_accounts — счета: городские кассы, банк владельца, прочие.
--   cash_entries  — неизменяемый журнал движения денег по счетам (со знаком).
--   Выручка по заказам НЕ копируется в журнал: поступления городской кассы считаются из orders
--   (paid_at в окне [opened_at, closed_at) счёта). Один источник правды — двойного учёта нет.
--   Баланс счёта = opening_balance + продажи (для городской кассы) + Σ cash_entries.amount.
--   Перевод между счетами — пара проводок (transfer_out / transfer_in), не доход и не расход.
--
-- ИСТОРИЯ СОХРАНЯЕТСЯ
--   Заказы, finance_entries и cash_transfers не меняются. Задолженность Hannover на момент
--   миграции переносится в стартовый остаток кассы Hannover (число не меняется).
--   cash_transfers замораживается (только чтение): новые передачи идут через счета.
--   München переводится в owner_operated по указанию владельца (запись в city_mode_history).
-- =============================================================================

do $$ begin
  if exists(select 1 from schema_migrations where version='0021') then raise exception 'migration 0021 already applied'; end if;
  if not exists(select 1 from schema_migrations where version='0020') then raise exception 'run 0020 first'; end if;
end $$;

-- ----------------------------------------------------------------- Режим города
alter table cities add column if not exists finance_mode text not null default 'city_managed';
do $$ begin
  if not exists(select 1 from pg_constraint where conname='cities_finance_mode_check') then
    alter table cities add constraint cities_finance_mode_check check (finance_mode in ('owner_operated','city_managed'));
  end if;
end $$;

create table city_mode_history(
  id bigserial primary key,
  city_id text not null references cities(id),
  old_mode text,
  new_mode text not null check (new_mode in ('owner_operated','city_managed')),
  reason text not null default '',
  changed_by bigint not null,
  changed_at timestamptz not null default now(),
  idempotency_key text unique
);
alter table city_mode_history enable row level security;

-- ----------------------------------------------------------------- Счета и журнал
create table cash_accounts(
  id bigserial primary key,
  name text not null unique check (length(trim(name)) between 1 and 80),
  kind text not null check (kind in ('city_cash','owner_bank','owner_cash','other')),
  city_id text references cities(id),
  opening_balance numeric(12,2) not null default 0,
  opened_at timestamptz not null default now(),
  closed_at timestamptz,                 -- только для городской кассы: окно учёта выручки
  active boolean not null default true,
  allow_negative boolean not null default false,
  created_by bigint not null,
  created_at timestamptz not null default now(),
  check ((kind = 'city_cash') = (city_id is not null)),
  check (closed_at is null or closed_at >= opened_at)
);
-- Одна открытая городская касса на город.
create unique index cash_accounts_city_open_uq on cash_accounts(city_id) where kind='city_cash' and closed_at is null;
alter table cash_accounts enable row level security;

create table cash_entries(
  id bigserial primary key,
  account_id bigint not null references cash_accounts(id),
  amount numeric(12,2) not null check (amount <> 0),          -- со знаком: + приход, − расход
  kind text not null check (kind in ('deposit','withdrawal','expense','transfer_in','transfer_out','adjustment','purchase')),
  transfer_id uuid,                                           -- общий для пары transfer_out/transfer_in
  finance_entry_id bigint references finance_entries(id),
  purchase_id bigint,                                         -- FK добавляется в 0022
  reverses_id bigint references cash_entries(id),             -- сторно: та же kind, обратный знак
  reason text not null default '',
  actor bigint not null,
  occurred_at timestamptz not null default now(),
  idempotency_key text not null unique,
  created_at timestamptz not null default now(),
  check (reverses_id is null or length(trim(reason)) >= 5),
  check (reverses_id is not null
         or (kind in ('deposit','transfer_in') and amount > 0)
         or (kind in ('withdrawal','expense','transfer_out','purchase') and amount < 0)
         or kind = 'adjustment')
);
create unique index cash_entries_reverses_uq on cash_entries(reverses_id) where reverses_id is not null;
create index cash_entries_account_idx on cash_entries(account_id, occurred_at desc);
create index cash_entries_transfer_idx on cash_entries(transfer_id) where transfer_id is not null;
alter table cash_entries enable row level security;

create or replace function _cash_guard() returns trigger language plpgsql set search_path=public as $$
begin raise exception 'cash_immutable'; end $$;
create trigger trg_cash_guard before update or delete on cash_entries for each row execute function _cash_guard();

-- Журнал finance_entries получает ссылку на счёт (добавление колонки не вызывает триггер _finance_guard).
alter table finance_entries add column if not exists account_id bigint references cash_accounts(id);

-- Старый журнал передач замораживается: он остаётся историей, новые передачи — через счета.
create or replace function _cash_transfers_frozen() returns trigger language plpgsql set search_path=public as $$
begin raise exception 'cash_transfers_frozen'; end $$;
create trigger trg_cash_transfers_frozen before insert or update or delete on cash_transfers for each row execute function _cash_transfers_frozen();

-- ----------------------------------------------------------------- Баланс
create or replace function _account_sales(p_account bigint) returns numeric language sql stable set search_path=public as $$
  select coalesce(sum(o.paid_amount - o.refunded_amount), 0)
  from cash_accounts a
  join orders o on o.city_id = a.city_id and o.paid_at is not null and o.paid_at >= a.opened_at
                and (a.closed_at is null or o.paid_at < a.closed_at)
  where a.id = p_account and a.kind = 'city_cash'
$$;

create or replace function _account_balance(p_account bigint) returns numeric language sql stable set search_path=public as $$
  select a.opening_balance + _account_sales(a.id) + coalesce((select sum(e.amount) from cash_entries e where e.account_id = a.id), 0)
  from cash_accounts a where a.id = p_account
$$;

-- ----------------------------------------------------------------- Начальные данные
do $$
declare c record; owner_id bigint; owed numeric; mode text;
begin
  select telegram_id into owner_id from admins where role='owner' and is_active order by created_at limit 1;
  owner_id := coalesce(owner_id, 0);
  -- München управляется владельцем (решение владельца). Hannover и прочие остаются city_managed.
  update cities set finance_mode='owner_operated' where id='muenchen';
  for c in select * from cities order by sort, id loop
    insert into city_mode_history(city_id,old_mode,new_mode,reason,changed_by)
    values(c.id,null,(select finance_mode from cities where id=c.id),'Начальный режим при миграции 0021',owner_id);
    select finance_mode into mode from cities where id=c.id;
    if mode = 'city_managed' then
      owed := (_settlement(c.id)->>'owed')::numeric;      -- прежняя формула: ещё не заменена
    else
      owed := 0;
    end if;
    insert into cash_accounts(name,kind,city_id,opening_balance,opened_at,created_by)
    values('Касса '||c.name,'city_cash',c.id,coalesce(owed,0),now(),owner_id);
  end loop;
  insert into cash_accounts(name,kind,opening_balance,opened_at,created_by)
  values('Банковский счёт владельца','owner_bank',0,now(),owner_id);
end $$;

-- ----------------------------------------------------------------- Взаиморасчёты с учётом режима
create or replace function _settlement(p_city text) returns jsonb language plpgsql stable set search_path=public as $$
declare c cities%rowtype; a cash_accounts%rowtype;
  collected_all numeric; refunded_all numeric; legacy_tr numeric;
  sales numeric; expenses numeric; transfers_out numeric; deposits numeric; withdrawals numeric; adjustments numeric; purchases numeric;
  bal numeric; tr jsonb;
begin
  select * into c from cities where id=p_city;
  if not found then raise exception 'bad_city'; end if;
  select * into a from cash_accounts where kind='city_cash' and city_id=p_city and closed_at is null;
  collected_all := coalesce((select sum(paid_amount) from orders where city_id=p_city and paid_at is not null),0);
  refunded_all  := coalesce((select sum(refunded_amount) from orders where city_id=p_city),0);
  legacy_tr     := coalesce((select sum(amount) from cash_transfers where city_id=p_city),0);

  if c.finance_mode = 'owner_operated' then
    return jsonb_build_object('city_id',p_city,'city_name',c.name,'mode','owner_operated','transfer_required',false,
      'message', c.name||' — управляется владельцем. Передача денег владельцу не требуется',
      'collected',collected_all,'refunded',refunded_all,'transferred',legacy_tr,'owed',0,
      'cash_account_id',a.id,'cash_balance', case when a.id is null then null else _account_balance(a.id) end,
      'transfers','[]'::jsonb);
  end if;

  if a.id is null then      -- город без кассы (создан вручную): прежняя формула
    return jsonb_build_object('city_id',p_city,'city_name',c.name,'mode','city_managed','transfer_required',true,
      'collected',collected_all,'refunded',refunded_all,'transferred',legacy_tr,
      'owed',collected_all-refunded_all-legacy_tr,'cash_account_id',null,'cash_balance',null,
      'transfers',(select coalesce(jsonb_agg(jsonb_build_object('id','L'||t.id,'amount',t.amount,'note',t.note,'created_at',t.created_at,'source','legacy') order by t.created_at desc),'[]'::jsonb)
                   from cash_transfers t where t.city_id=p_city));
  end if;

  sales := _account_sales(a.id);
  select coalesce(-sum(amount) filter (where kind='expense'),0), coalesce(-sum(amount) filter (where kind='transfer_out'),0),
         coalesce(sum(amount) filter (where kind='deposit'),0),  coalesce(-sum(amount) filter (where kind='withdrawal'),0),
         coalesce(sum(amount) filter (where kind='adjustment'),0), coalesce(-sum(amount) filter (where kind='purchase'),0)
    into expenses, transfers_out, deposits, withdrawals, adjustments, purchases
  from cash_entries where account_id=a.id;
  bal := a.opening_balance + sales - expenses - transfers_out + deposits - withdrawals + adjustments - purchases;

  select coalesce(jsonb_agg(x order by ts desc),'[]'::jsonb) into tr from (
    select t.created_at ts, jsonb_build_object('id','L'||t.id,'amount',t.amount,'note',t.note,'created_at',t.created_at,'source','legacy') x
      from cash_transfers t where t.city_id=p_city
    union all
    select e.created_at, jsonb_build_object('id','T'||e.transfer_id::text,'transfer_id',e.transfer_id,'amount',-e.amount,'note',e.reason,
             'created_at',e.created_at,'source','account','reversed',exists(select 1 from cash_entries r where r.reverses_id=e.id))
      from cash_entries e where e.account_id=a.id and e.kind='transfer_out' and e.reverses_id is null
    order by 1 desc limit 100) s;

  return jsonb_build_object('city_id',p_city,'city_name',c.name,'mode','city_managed','transfer_required',true,
    'cash_account_id',a.id,'cash_balance',bal,
    'collected',collected_all,'refunded',refunded_all,'transferred',legacy_tr+transfers_out,
    'opening',a.opening_balance,'sales',sales,'expenses',expenses,'deposits',deposits,'withdrawals',withdrawals,
    'adjustments',adjustments,'purchases',purchases,'legacy_transferred',legacy_tr,
    'owed',bal,'transfers',tr);
end $$;

-- ----------------------------------------------------------------- Перевод между счетами
create or replace function _do_account_transfer(p_actor bigint, p_from bigint, p_to bigint, p_amount numeric, p_reason text, p_key text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare fa cash_accounts%rowtype; ta cash_accounts%rowtype; bal numeric; tid uuid; dup cash_entries%rowtype;
        k_out text := p_key||':out'; k_in text := p_key||':in'; rs text := trim(coalesce(p_reason,''));
begin
  if p_key is null or length(p_key) < 8 then raise exception 'key_required'; end if;
  if p_amount is null or p_amount <= 0 or p_amount > 1000000 then raise exception 'bad_amount'; end if;
  if p_from is null or p_to is null or p_from = p_to then raise exception 'bad_accounts'; end if;
  if length(rs) > 300 then raise exception 'bad_text'; end if;
  perform 1 from cash_accounts where id in (p_from,p_to) order by id for update;     -- единый порядок блокировок
  select * into dup from cash_entries where idempotency_key = k_out;
  if found then return jsonb_build_object('duplicate',true,'transfer_id',dup.transfer_id); end if;
  select * into fa from cash_accounts where id=p_from;
  select * into ta from cash_accounts where id=p_to;
  if fa.id is null or ta.id is null then raise exception 'account_not_found'; end if;
  if not fa.active or not ta.active then raise exception 'account_inactive'; end if;
  bal := _account_balance(p_from);
  if not fa.allow_negative and bal < p_amount then raise exception 'insufficient_funds'; end if;
  tid := gen_random_uuid();
  insert into cash_entries(account_id,amount,kind,transfer_id,reason,actor,idempotency_key) values(p_from,-round(p_amount,2),'transfer_out',tid,rs,p_actor,k_out);
  insert into cash_entries(account_id,amount,kind,transfer_id,reason,actor,idempotency_key) values(p_to,round(p_amount,2),'transfer_in',tid,rs,p_actor,k_in);
  perform _audit_c(p_actor,'cash_transfer','cash_transfer',tid::text,null,
    jsonb_build_object('from',fa.name,'to',ta.name,'amount',round(p_amount,2),'reason',rs), coalesce(fa.city_id,ta.city_id));
  return jsonb_build_object('duplicate',false,'transfer_id',tid,'balance_before',bal,'balance_after',bal-round(p_amount,2));
end $$;

create or replace function account_transfer(p_actor bigint, p_from bigint, p_to bigint, p_amount numeric, p_reason text, p_key text)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  perform _finance_owner(p_actor);
  return _do_account_transfer(p_actor, p_from, p_to, p_amount, p_reason, p_key);
end $$;

-- Сторно перевода: обе проводки отменяются обратными. Не доход и не расход.
create or replace function account_transfer_reverse(p_actor bigint, p_transfer uuid, p_reason text, p_key text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare eo cash_entries%rowtype; ei cash_entries%rowtype; rs text := trim(coalesce(p_reason,'')); ta cash_accounts%rowtype; bal numeric;
begin
  perform _finance_owner(p_actor);
  if p_key is null or length(p_key) < 8 then raise exception 'key_required'; end if;
  if exists(select 1 from cash_entries where idempotency_key = p_key||':rout') then return jsonb_build_object('duplicate',true); end if;
  if length(rs) < 5 or length(rs) > 300 then raise exception 'reason_required'; end if;
  select * into eo from cash_entries where transfer_id=p_transfer and kind='transfer_out' and reverses_id is null;
  select * into ei from cash_entries where transfer_id=p_transfer and kind='transfer_in'  and reverses_id is null;
  if eo.id is null or ei.id is null then raise exception 'entry_not_found'; end if;
  perform 1 from cash_accounts where id in (eo.account_id, ei.account_id) order by id for update;
  if exists(select 1 from cash_entries where reverses_id in (eo.id, ei.id)) then raise exception 'already_reversed'; end if;
  select * into ta from cash_accounts where id=ei.account_id;
  bal := _account_balance(ta.id);
  if not ta.allow_negative and bal < ei.amount then raise exception 'insufficient_funds'; end if;
  insert into cash_entries(account_id,amount,kind,transfer_id,reverses_id,reason,actor,idempotency_key)
    values(eo.account_id,-eo.amount,'transfer_out',p_transfer,eo.id,rs,p_actor,p_key||':rout');
  insert into cash_entries(account_id,amount,kind,transfer_id,reverses_id,reason,actor,idempotency_key)
    values(ei.account_id,-ei.amount,'transfer_in',p_transfer,ei.id,rs,p_actor,p_key||':rin');
  perform _audit_c(p_actor,'cash_transfer_reverse','cash_transfer',p_transfer::text,jsonb_build_object('amount',ei.amount),jsonb_build_object('reason',rs),
    (select city_id from cash_accounts where id=eo.account_id));
  return jsonb_build_object('duplicate',false,'transfer_id',p_transfer);
end $$;

-- Передача денег городом владельцу (совместимый интерфейс). Только для city_managed.
create or replace function record_cash_transfer(p_actor bigint, p_city text, p_amount numeric, p_note text, p_key text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare c cities%rowtype; a cash_accounts%rowtype; o cash_accounts%rowtype; bal numeric; r jsonb;
begin
  perform _finance_owner(p_actor);
  if p_amount is null or p_amount <= 0 then raise exception 'bad_amount'; end if;
  select * into c from cities where id=p_city;
  if not found then raise exception 'bad_city'; end if;
  if c.finance_mode <> 'city_managed' then raise exception 'transfer_not_required'; end if;
  select * into a from cash_accounts where kind='city_cash' and city_id=p_city and closed_at is null;
  if a.id is null then raise exception 'cash_account_missing'; end if;
  select * into o from cash_accounts where kind='owner_bank' and active order by id limit 1;
  if o.id is null then raise exception 'owner_account_missing'; end if;
  perform pg_advisory_xact_lock(hashtext('settlement:'||p_city));
  bal := _account_balance(a.id);
  if p_amount > bal and not exists(select 1 from cash_entries where idempotency_key = p_key||':out') then raise exception 'exceeds_balance'; end if;
  r := _do_account_transfer(p_actor, a.id, o.id, p_amount, coalesce(p_note,''), p_key);
  if (r->>'duplicate')::boolean then return jsonb_build_object('duplicate',true,'id',r->>'transfer_id'); end if;
  return jsonb_build_object('duplicate',false,'owed_before',bal,'owed_after',bal-p_amount,'transfer_id',r->>'transfer_id');
end $$;

-- ----------------------------------------------------------------- Смена режима города
create or replace function admin_set_city_mode(p_actor bigint, p_city text, p_mode text, p_reason text, p_key text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare c cities%rowtype; a cash_accounts%rowtype; bal numeric; rs text := trim(coalesce(p_reason,'')); na bigint; dup city_mode_history%rowtype;
        v_now timestamptz := clock_timestamp();   -- одна граница для закрытия старой и открытия новой кассы (окна не пересекаются)
begin
  perform _finance_owner(p_actor);
  if p_key is null or length(p_key) < 8 then raise exception 'key_required'; end if;
  select * into dup from city_mode_history where idempotency_key=p_key;
  if found then return jsonb_build_object('duplicate',true,'mode',dup.new_mode); end if;
  if p_mode is null or p_mode not in ('owner_operated','city_managed') then raise exception 'bad_mode'; end if;
  if length(rs) < 5 or length(rs) > 300 then raise exception 'reason_required'; end if;
  select * into c from cities where id=p_city for update;
  if not found then raise exception 'bad_city'; end if;
  if c.finance_mode = p_mode then raise exception 'mode_unchanged'; end if;
  select * into a from cash_accounts where kind='city_cash' and city_id=p_city and closed_at is null for update;

  if p_mode = 'owner_operated' then
    -- Нельзя «растворить» долг сменой режима: сначала город передаёт деньги (или владелец делает корректировку).
    if a.id is not null then
      bal := _account_balance(a.id);
      if abs(bal) > 0.004 then raise exception 'settle_first'; end if;
    end if;
  else
    -- Касса владельца становится кассой города: старая закрывается (остаётся у владельца), новая начинается с нуля.
    -- Иначе деньги владельца превратились бы в «долг города» — искусственная задолженность.
    if a.id is not null then
      update cash_accounts set closed_at=v_now, name=name||' (закрыта #'||id||')' where id=a.id;
    end if;
    insert into cash_accounts(name,kind,city_id,opening_balance,opened_at,created_by)
    values('Касса '||c.name,'city_cash',p_city,0,v_now,p_actor) returning id into na;
  end if;

  update cities set finance_mode=p_mode where id=p_city;
  insert into city_mode_history(city_id,old_mode,new_mode,reason,changed_by,idempotency_key) values(p_city,c.finance_mode,p_mode,rs,p_actor,p_key);
  perform _audit_c(p_actor,'city_mode_change','city',p_city,jsonb_build_object('mode',c.finance_mode),jsonb_build_object('mode',p_mode,'reason',rs),p_city);
  return jsonb_build_object('duplicate',false,'city_id',p_city,'mode',p_mode);
end $$;

create or replace function admin_city_modes(p_actor bigint) returns jsonb
language plpgsql stable security definer set search_path=public as $$
begin
  perform _finance_owner(p_actor);
  return coalesce((select jsonb_agg(jsonb_build_object('city_id',c.id,'name',c.name,'finance_mode',c.finance_mode,
      'history',(select coalesce(jsonb_agg(jsonb_build_object('old_mode',h.old_mode,'new_mode',h.new_mode,'reason',h.reason,'changed_by',h.changed_by,'changed_at',h.changed_at) order by h.id desc),'[]'::jsonb)
                 from city_mode_history h where h.city_id=c.id)) order by c.sort, c.id) from cities c), '[]'::jsonb);
end $$;

-- ----------------------------------------------------------------- Управление счетами
create or replace function cash_account_create(p_actor bigint, p_name text, p_kind text, p_opening numeric) returns jsonb
language plpgsql security definer set search_path=public as $$
declare a cash_accounts%rowtype;
begin
  perform _finance_owner(p_actor);
  if p_kind is null or p_kind not in ('owner_bank','owner_cash','other') then raise exception 'bad_kind'; end if;
  if nullif(trim(coalesce(p_name,'')),'') is null or length(trim(p_name)) > 80 then raise exception 'bad_name'; end if;
  if p_opening is null or p_opening < 0 or p_opening > 100000000 then raise exception 'bad_amount'; end if;
  begin
    insert into cash_accounts(name,kind,opening_balance,created_by) values(trim(p_name),p_kind,round(p_opening,2),p_actor) returning * into a;
  exception when unique_violation then raise exception 'name_taken';
  end;
  perform _audit(p_actor,'cash_account_create','cash_account',a.id::text,null,jsonb_build_object('name',a.name,'kind',a.kind,'opening_balance',a.opening_balance));
  return jsonb_build_object('id',a.id,'name',a.name);
end $$;

create or replace function cash_account_set_active(p_actor bigint, p_account bigint, p_active boolean) returns jsonb
language plpgsql security definer set search_path=public as $$
declare a cash_accounts%rowtype;
begin
  perform _finance_owner(p_actor);
  select * into a from cash_accounts where id=p_account for update;
  if not found then raise exception 'account_not_found'; end if;
  if a.kind = 'city_cash' then raise exception 'city_account_locked'; end if;
  if not p_active and abs(_account_balance(a.id)) > 0.004 then raise exception 'balance_not_zero'; end if;
  if a.active is distinct from p_active then
    update cash_accounts set active=p_active where id=a.id;
    perform _audit(p_actor,'cash_account_toggle','cash_account',a.id::text,jsonb_build_object('active',a.active),jsonb_build_object('active',p_active));
  end if;
  return jsonb_build_object('id',a.id,'active',p_active);
end $$;

-- Корректировка остатка (пересчёт кассы). Не доход и не расход. Причина обязательна.
create or replace function cash_adjust(p_actor bigint, p_account bigint, p_amount numeric, p_reason text, p_key text) returns jsonb
language plpgsql security definer set search_path=public as $$
declare a cash_accounts%rowtype; rs text := trim(coalesce(p_reason,'')); e cash_entries%rowtype; bal numeric;
begin
  perform _finance_owner(p_actor);
  if p_key is null or length(p_key) < 8 then raise exception 'key_required'; end if;
  select * into a from cash_accounts where id=p_account for update;
  if not found then raise exception 'account_not_found'; end if;
  select * into e from cash_entries where idempotency_key=p_key;
  if found then return jsonb_build_object('duplicate',true,'id',e.id); end if;
  if p_amount is null or p_amount = 0 or abs(p_amount) > 1000000 then raise exception 'bad_amount'; end if;
  if length(rs) < 5 or length(rs) > 300 then raise exception 'reason_required'; end if;
  bal := _account_balance(a.id);
  if p_amount < 0 and not a.allow_negative and bal + p_amount < 0 then raise exception 'insufficient_funds'; end if;
  insert into cash_entries(account_id,amount,kind,reason,actor,idempotency_key) values(a.id,round(p_amount,2),'adjustment',rs,p_actor,p_key) returning * into e;
  perform _audit_c(p_actor,'cash_adjust','cash_account',a.id::text,jsonb_build_object('balance',bal),jsonb_build_object('balance',bal+round(p_amount,2),'reason',rs),a.city_id);
  return jsonb_build_object('duplicate',false,'id',e.id);
end $$;

create or replace function cash_accounts_overview(p_actor bigint) returns jsonb
language plpgsql stable security definer set search_path=public as $$
begin
  perform _finance_owner(p_actor);
  return coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'name',a.name,'kind',a.kind,'city_id',a.city_id,
      'city_mode',c.finance_mode,'opening_balance',a.opening_balance,'opened_at',a.opened_at,'closed_at',a.closed_at,
      'active',a.active,'balance',_account_balance(a.id)) order by (a.closed_at is not null), a.kind, a.id)
    from cash_accounts a left join cities c on c.id=a.city_id), '[]'::jsonb);
end $$;

create or replace function cash_account_statement(p_actor bigint, p_account bigint, p_date_from date, p_date_to date, p_limit int default 200)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare wf timestamptz; wt timestamptz; a cash_accounts%rowtype; lim int := least(greatest(coalesce(p_limit,200),1),500); res jsonb;
begin
  perform _finance_owner(p_actor);
  select * into a from cash_accounts where id=p_account;
  if not found then raise exception 'account_not_found'; end if;
  select w.win_from, w.win_to into wf, wt from _fin_window(p_date_from, p_date_to) w;
  select coalesce(jsonb_agg(x order by ts desc, sid desc), '[]'::jsonb) into res from (
    select * from (
      select e.occurred_at ts, e.id sid, jsonb_build_object('id',e.id,'kind',e.kind,'amount',e.amount,'occurred_at',e.occurred_at,
               'reason',e.reason,'actor',e.actor,'reverses_id',e.reverses_id,'transfer_id',e.transfer_id,'finance_entry_id',e.finance_entry_id,
               'reversed',exists(select 1 from cash_entries r where r.reverses_id=e.id)) x
        from cash_entries e where e.account_id=a.id and e.occurred_at >= wf and e.occurred_at < wt
      union all
      select o.paid_at, 0, jsonb_build_object('id',null,'kind','sale','amount',o.paid_amount-o.refunded_amount,'occurred_at',o.paid_at,
               'reason','Заказ '||o.number,'actor',null,'order_id',o.id)
        from orders o where a.kind='city_cash' and o.city_id=a.city_id and o.paid_at is not null and o.paid_at >= a.opened_at
         and (a.closed_at is null or o.paid_at < a.closed_at) and o.paid_at >= wf and o.paid_at < wt) u
    order by ts desc, sid desc limit lim) s;
  return jsonb_build_object('account',jsonb_build_object('id',a.id,'name',a.name,'kind',a.kind,'city_id',a.city_id,'opening_balance',a.opening_balance,
            'opened_at',a.opened_at,'closed_at',a.closed_at,'active',a.active),'balance',_account_balance(a.id),'rows',res);
end $$;

-- ----------------------------------------------------------------- Журнал финансов со счётом
drop function if exists finance_post_entry(bigint, text, numeric, text, text, text, text);
create or replace function finance_post_entry(p_actor bigint, p_op text, p_amount numeric, p_city text,
                                              p_category text, p_description text, p_key text, p_account bigint)
returns jsonb language plpgsql security definer set search_path=public as $$
declare e finance_entries%rowtype; a cash_accounts%rowtype; cat text := nullif(trim(coalesce(p_category,'')),''); desc_t text := trim(coalesce(p_description,''));
        bal numeric; sgn numeric; ck text;
begin
  perform _finance_owner(p_actor);
  if p_key is null or length(p_key) < 8 then raise exception 'key_required'; end if;
  if p_account is not null then
    select * into a from cash_accounts where id=p_account for update;
    if not found then raise exception 'account_not_found'; end if;
  end if;
  select * into e from finance_entries where idempotency_key=p_key;
  if found then return jsonb_build_object('id',e.id,'duplicate',true); end if;
  if p_op is null or p_op not in ('expense','cash_in','cash_out') then raise exception 'bad_op'; end if;
  if p_amount is null or p_amount <= 0 or p_amount > 1000000 then raise exception 'bad_amount'; end if;
  if p_op = 'expense' and cat is null then raise exception 'category_required'; end if;
  if p_op in ('cash_in','cash_out') and p_account is null then raise exception 'account_required'; end if;
  if length(desc_t) > 300 or length(coalesce(cat,'')) > 60 then raise exception 'bad_text'; end if;
  if p_city is not null and not exists(select 1 from cities where id=p_city) then raise exception 'bad_city'; end if;
  if p_account is not null then
    if not a.active then raise exception 'account_inactive'; end if;
    if a.kind = 'city_cash' and p_city is not null and p_city <> a.city_id then raise exception 'account_city_mismatch'; end if;
    sgn := case when p_op = 'cash_in' then 1 else -1 end;
    bal := _account_balance(a.id);
    if sgn < 0 and not a.allow_negative and bal < p_amount then raise exception 'insufficient_funds'; end if;
  end if;
  begin
    insert into finance_entries(op_type,amount,city_id,category,description,actor,idempotency_key,account_id)
    values(p_op, round(p_amount,2), coalesce(p_city, a.city_id), coalesce(cat,''), desc_t, p_actor, p_key, p_account)
    returning * into e;
  exception when unique_violation then
    select * into e from finance_entries where idempotency_key=p_key;
    return jsonb_build_object('id',e.id,'duplicate',true);
  end;
  if p_account is not null then
    ck := case p_op when 'cash_in' then 'deposit' when 'cash_out' then 'withdrawal' else 'expense' end;
    insert into cash_entries(account_id,amount,kind,finance_entry_id,reason,actor,idempotency_key)
    values(a.id, sgn*round(p_amount,2), ck, e.id, left(coalesce(nullif(desc_t,''),coalesce(cat,'')),300), p_actor, 'fin:'||p_key);
  end if;
  return jsonb_build_object('id',e.id,'duplicate',false);
end $$;

create or replace function finance_reverse_entry(p_actor bigint, p_entry bigint, p_reason text, p_key text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare o finance_entries%rowtype; r finance_entries%rowtype; rs text := trim(coalesce(p_reason,'')); acc bigint; a cash_accounts%rowtype; c cash_entries%rowtype; bal numeric;
begin
  perform _finance_owner(p_actor);
  select * into r from finance_entries where idempotency_key=p_key;
  if found then return jsonb_build_object('id',r.id,'duplicate',true); end if;
  if length(rs) < 5 or length(rs) > 300 then raise exception 'reason_required'; end if;
  -- Порядок блокировок как при проведении: сначала счёт, затем запись.
  select account_id into acc from finance_entries where id=p_entry;
  if acc is not null then select * into a from cash_accounts where id=acc for update; end if;
  select * into o from finance_entries where id=p_entry for update;
  if not found then raise exception 'entry_not_found'; end if;
  if o.reverses_id is not null then raise exception 'cannot_reverse_reversal'; end if;
  if o.status <> 'posted' then raise exception 'already_reversed'; end if;
  if acc is not null then
    select * into c from cash_entries where finance_entry_id=o.id and reverses_id is null;
    if found and -c.amount < 0 then      -- сторно уменьшит баланс (отмена внесения)
      bal := _account_balance(acc);
      if not a.allow_negative and bal + (-c.amount) < 0 then raise exception 'insufficient_funds'; end if;
    end if;
  end if;
  begin
    insert into finance_entries(op_type,amount,city_id,category,description,reason,actor,reverses_id,idempotency_key,account_id)
    values(o.op_type, o.amount, o.city_id, o.category, 'Сторно записи #'||o.id, rs, p_actor, o.id, p_key, o.account_id)
    returning * into r;
  exception when unique_violation then
    select * into r from finance_entries where idempotency_key=p_key;
    return jsonb_build_object('id',r.id,'duplicate',true);
  end;
  update finance_entries set status='reversed' where id=o.id;
  if c.id is not null then
    insert into cash_entries(account_id,amount,kind,finance_entry_id,reverses_id,reason,actor,idempotency_key)
    values(c.account_id, -c.amount, c.kind, r.id, c.id, rs, p_actor, 'finrev:'||p_key);
  end if;
  return jsonb_build_object('id',r.id,'reversed_id',o.id,'duplicate',false);
end $$;

-- ----------------------------------------------------------------- Права
select _lockdown_public_tables();
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on all functions in schema public to service_role;

insert into schema_migrations(version) values('0021');
