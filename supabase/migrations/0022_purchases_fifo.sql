-- =============================================================================
-- MoonVape v4 · миграция 0022 · закупки, партии, FIFO-себестоимость
-- Запускать ПОСЛЕ 0021. Один Run в SQL Editor. Перед запуском — резервная копия БД.
--
-- МОДЕЛЬ
--   Закупка: draft → posted (поступление на склад) → при необходимости reversed (сторно).
--   Проведение закупки создаёт партии (stock_batches) по ПОЛНОЙ себестоимости:
--     цена поставщика + доля доставки и допрасходов (пропорционально стоимости позиции).
--   Закупка — не расход: товар становится себестоимостью только при продаже (FIFO).
--   Оплата закупки со счёта — движение денег (cash_entries.kind='purchase'), не расход в P&L.
--   Инвариант: Σ stock_batches.qty_remaining по позиции склада = inventory.quantity.
--   Продажа (выдача заказа): _fifo_consume списывает старейшие партии, пишет batch_consumptions,
--   считает фактическую себестоимость позиции (order_items.cogs_total).
--   Старые заказы: cogs_total = NULL → финансы используют прежний снимок unit_cost.
--   Существующие остатки превращаются в «начальные» партии по текущей cost_price товара.
--
-- Параллельность: все операции, меняющие остаток, сначала блокируют строки inventory в порядке id,
--   затем работают с партиями. Две выдачи одной позиции выполняются строго по очереди.
-- Если партий не хватает (расхождение учёта) — недостающее достраивается начальной партией
--   по cost_price и пишется аудит fifo_self_heal: продажа не блокируется из-за учёта.
-- =============================================================================

do $$ begin
  if exists(select 1 from schema_migrations where version='0022') then raise exception 'migration 0022 already applied'; end if;
  if not exists(select 1 from schema_migrations where version='0021') then raise exception 'run 0021 first'; end if;
end $$;

-- ----------------------------------------------------------------- Таблицы
create table suppliers(
  id bigserial primary key,
  name text not null unique check (length(trim(name)) between 1 and 120),
  contact text not null default '' check (length(contact) <= 300),
  note text not null default '' check (length(note) <= 500),
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table suppliers enable row level security;

create sequence purchase_seq;
create table purchases(
  id bigserial primary key,
  number text not null unique,
  supplier_id bigint references suppliers(id),
  city_id text not null references cities(id),
  status text not null default 'draft' check (status in ('draft','posted','cancelled','reversed')),
  purchase_date date not null default current_date,
  shipping_cost numeric(12,2) not null default 0 check (shipping_cost >= 0 and shipping_cost <= 1000000),
  extra_cost numeric(12,2) not null default 0 check (extra_cost >= 0 and extra_cost <= 1000000),
  note text not null default '' check (length(note) <= 500),
  items_total numeric(12,2),
  total_cost numeric(12,2),
  account_id bigint references cash_accounts(id),
  created_by bigint not null,
  created_at timestamptz not null default now(),
  posted_by bigint, posted_at timestamptz, post_key text unique,
  reversed_by bigint, reversed_at timestamptz, reverse_reason text,
  idempotency_key text not null unique
);
create index purchases_status_idx on purchases(status, purchase_date desc);
alter table purchases enable row level security;

create table purchase_items(
  id bigserial primary key,
  purchase_id bigint not null references purchases(id) on delete cascade,
  inventory_id uuid not null references inventory(id),
  quantity int not null check (quantity > 0 and quantity <= 100000),
  unit_price numeric(12,4) not null check (unit_price >= 0 and unit_price <= 100000),
  landed_unit_cost numeric(14,6),
  unique (purchase_id, inventory_id)
);
alter table purchase_items enable row level security;

alter table cash_entries add constraint cash_entries_purchase_fk foreign key (purchase_id) references purchases(id);

create table stock_batches(
  id bigserial primary key,
  inventory_id uuid not null references inventory(id),
  city_id text not null references cities(id),
  product_id uuid not null references products(id),
  source text not null check (source in ('opening','purchase','transfer','adjustment','receipt')),
  purchase_item_id bigint references purchase_items(id),
  transfer_item_id bigint,                                   -- FK добавляется в 0023
  received_at timestamptz not null default now(),            -- порядок FIFO; при перемещении сохраняется исходный
  qty_initial int not null check (qty_initial > 0),
  qty_remaining int not null check (qty_remaining >= 0),
  unit_cost numeric(14,6) check (unit_cost is null or unit_cost >= 0),   -- NULL = себестоимость неизвестна
  created_at timestamptz not null default now(),
  check (qty_remaining <= qty_initial)
);
create index stock_batches_fifo_idx on stock_batches(inventory_id, received_at, id) where qty_remaining > 0;
create index stock_batches_city_idx on stock_batches(city_id) where qty_remaining > 0;
alter table stock_batches enable row level security;

-- Партию можно только расходовать (qty_remaining уменьшается). Остальное неизменно, удалять нельзя.
create or replace function _batch_guard() returns trigger language plpgsql set search_path=public as $$
begin
  if tg_op = 'DELETE' then raise exception 'batch_immutable'; end if;
  if (to_jsonb(new) - 'qty_remaining') is distinct from (to_jsonb(old) - 'qty_remaining') or new.qty_remaining > old.qty_remaining then
    raise exception 'batch_immutable';
  end if;
  return new;
end $$;
create trigger trg_batch_guard before update or delete on stock_batches for each row execute function _batch_guard();

create table batch_consumptions(
  id bigserial primary key,
  batch_id bigint not null references stock_batches(id),
  inventory_id uuid not null references inventory(id),
  kind text not null check (kind in ('sale','writeoff','transfer','purchase_reversal')),
  quantity int not null check (quantity > 0),
  unit_cost numeric(14,6),
  order_id uuid references orders(id),
  order_item_id uuid references order_items(id) on delete set null,
  transfer_item_id bigint,
  actor bigint,
  created_at timestamptz not null default now()
);
create index batch_consumptions_item_idx on batch_consumptions(order_item_id) where order_item_id is not null;
create index batch_consumptions_order_idx on batch_consumptions(order_id) where order_id is not null;
-- Защита от двойного списания одной позиции из одной партии.
create unique index batch_consumptions_sale_uq on batch_consumptions(order_item_id, batch_id) where kind = 'sale';
alter table batch_consumptions enable row level security;

create or replace function _consumption_guard() returns trigger language plpgsql set search_path=public as $$
begin
  if tg_op = 'UPDATE' and (to_jsonb(new) - 'order_item_id') is not distinct from (to_jsonb(old) - 'order_item_id') then return new; end if;  -- on delete set null
  raise exception 'consumption_immutable';
end $$;
create trigger trg_consumption_guard before update or delete on batch_consumptions for each row execute function _consumption_guard();

alter table order_items add column if not exists cogs_total numeric(14,4);
alter table order_items add column if not exists cogs_incomplete boolean not null default false;
alter table order_items add column if not exists cost_method text;
do $$ begin
  if not exists(select 1 from pg_constraint where conname='order_items_cost_method_check') then
    alter table order_items add constraint order_items_cost_method_check check (cost_method is null or cost_method in ('snapshot','fifo'));
  end if;
end $$;

-- ----------------------------------------------------------------- Начальные партии из текущих остатков
insert into stock_batches(inventory_id,city_id,product_id,source,received_at,qty_initial,qty_remaining,unit_cost)
select i.id, i.city_id, i.product_id, 'opening', now(), i.quantity, i.quantity, p.cost_price
from inventory i join products p on p.id=i.product_id
where i.quantity > 0 and i.city_id is not null;

-- ----------------------------------------------------------------- Ядро FIFO
create or replace function _batch_add(p_inventory uuid, p_qty int, p_unit_cost numeric, p_received timestamptz,
                                      p_source text, p_purchase_item bigint, p_transfer_item bigint) returns bigint
language plpgsql set search_path=public as $$
declare i inventory%rowtype; bid bigint;
begin
  if p_qty is null or p_qty <= 0 then raise exception 'bad_quantity'; end if;
  select * into i from inventory where id=p_inventory;
  if not found then raise exception 'item_not_found'; end if;
  insert into stock_batches(inventory_id,city_id,product_id,source,purchase_item_id,transfer_item_id,received_at,qty_initial,qty_remaining,unit_cost)
  values(p_inventory,i.city_id,i.product_id,p_source,p_purchase_item,p_transfer_item,coalesce(p_received,now()),p_qty,p_qty,p_unit_cost)
  returning id into bid;
  return bid;
end $$;

-- Списывает p_qty из старейших партий позиции. Вызывающий ОБЯЗАН держать блокировку строки inventory.
-- Возвращает {cost, incomplete, parts:[{batch_id, qty, unit_cost, received_at}]}.
create or replace function _fifo_consume(p_inventory uuid, p_qty int, p_kind text, p_order uuid, p_order_item uuid,
                                         p_transfer_item bigint, p_actor bigint) returns jsonb
language plpgsql set search_path=public as $$
declare b record; need int := p_qty; take int; total numeric := 0; incomplete boolean := false; parts jsonb := '[]'::jsonb;
        pc numeric; i inventory%rowtype; sid bigint;
begin
  if p_qty is null or p_qty <= 0 then raise exception 'bad_quantity'; end if;
  for b in select id, qty_remaining, unit_cost, received_at from stock_batches
           where inventory_id=p_inventory and qty_remaining > 0 order by received_at, id for update
  loop
    take := least(need, b.qty_remaining);
    update stock_batches set qty_remaining = qty_remaining - take where id=b.id;
    insert into batch_consumptions(batch_id,inventory_id,kind,quantity,unit_cost,order_id,order_item_id,transfer_item_id,actor)
    values(b.id,p_inventory,p_kind,take,b.unit_cost,p_order,p_order_item,p_transfer_item,p_actor);
    total := total + take * coalesce(b.unit_cost,0);
    if b.unit_cost is null then incomplete := true; end if;
    parts := parts || jsonb_build_object('batch_id',b.id,'qty',take,'unit_cost',b.unit_cost,'received_at',b.received_at);
    need := need - take;
    exit when need = 0;
  end loop;
  if need > 0 then
    -- Расхождение учёта (остаток есть, партий не хватает): достраиваем партию по cost_price и фиксируем в аудите.
    select * into i from inventory where id=p_inventory;
    select cost_price into pc from products where id=i.product_id;
    insert into stock_batches(inventory_id,city_id,product_id,source,received_at,qty_initial,qty_remaining,unit_cost)
    values(p_inventory,i.city_id,i.product_id,'adjustment',now(),need,0,pc) returning id into sid;
    insert into batch_consumptions(batch_id,inventory_id,kind,quantity,unit_cost,order_id,order_item_id,transfer_item_id,actor)
    values(sid,p_inventory,p_kind,need,pc,p_order,p_order_item,p_transfer_item,p_actor);
    total := total + need * coalesce(pc,0);
    if pc is null then incomplete := true; end if;
    parts := parts || jsonb_build_object('batch_id',sid,'qty',need,'unit_cost',pc,'received_at',now());
    perform _audit_c(p_actor,'fifo_self_heal','inventory',p_inventory::text,null,jsonb_build_object('shortage',need,'kind',p_kind),i.city_id);
  end if;
  return jsonb_build_object('cost',total,'incomplete',incomplete,'parts',parts);
end $$;

-- ----------------------------------------------------------------- Выдача заказа с FIFO
create or replace function change_order_status(p_order uuid, p_new order_status, p_actor bigint) returns jsonb
language plpgsql security definer set search_path=public as $$
declare o orders; r record; ok boolean; fc jsonb;
begin
  select * into o from orders where id=p_order for update;
  if not found then raise exception 'order_not_found'; end if;
  perform _assert_role(p_actor, o.city_id);
  ok := (o.status='new' and p_new in ('prepared','cancelled'))
     or (o.status='prepared' and p_new in ('issued','cancelled'));
  if not ok then raise exception 'bad_transition'; end if;
  -- Заказ с неопределённой ценой нельзя подтвердить и выдать до согласования.
  if o.approval_required and p_new in ('prepared','issued') then raise exception 'approval_required'; end if;
  -- Проверка возраста при выдаче (включается настройкой require_age_check_on_issue).
  if p_new='issued' and o.age_verified_at is null and _setting_bool('require_age_check_on_issue') then raise exception 'age_check_required'; end if;

  -- Единый порядок блокировок: строки склада по id (параллельные выдачи/правки не ждут друг друга по кругу).
  perform 1 from inventory where id in (select inventory_id from order_items where order_id=p_order) order by id for update;

  if p_new='cancelled' then
    for r in select inventory_id, sum(quantity)::int q from order_items where order_id=p_order group by inventory_id order by inventory_id loop
      insert into inventory_transactions(inventory_id,order_id,op,quantity,qty_before,qty_after,city_id,actor,reason)
      select i.id,p_order,'release'::inv_op,r.q,i.quantity,i.quantity,i.city_id,p_actor,'Отмена заказа '||o.number from inventory i where i.id=r.inventory_id;
      update inventory set reserved_quantity=reserved_quantity-r.q where id=r.inventory_id;
    end loop;
  elsif p_new='issued' then
    for r in select inventory_id, sum(quantity)::int q from order_items where order_id=p_order group by inventory_id order by inventory_id loop
      insert into inventory_transactions(inventory_id,order_id,op,quantity,qty_before,qty_after,city_id,actor,reason)
      select i.id,p_order,'writeoff'::inv_op,r.q,i.quantity,i.quantity-r.q,i.city_id,p_actor,'Выдача по заказу '||o.number from inventory i where i.id=r.inventory_id;
      update inventory set quantity=quantity-r.q, reserved_quantity=reserved_quantity-r.q where id=r.inventory_id;
    end loop;
    -- Фактическая себестоимость каждой позиции по FIFO.
    for r in select id, inventory_id, quantity from order_items where order_id=p_order order by inventory_id, id loop
      fc := _fifo_consume(r.inventory_id, r.quantity, 'sale', p_order, r.id, null, p_actor);
      update order_items set cogs_total=(fc->>'cost')::numeric, cogs_incomplete=(fc->>'incomplete')::boolean, cost_method='fifo' where id=r.id;
    end loop;
  end if;

  -- Выдача = оплата: если заказ ещё не отмечен оплаченным, он считается оплаченным на сумму заказа.
  update orders set status=p_new, updated_at=now(),
    paid_at         = case when p_new='issued' then coalesce(paid_at, now()) else paid_at end,
    paid_amount     = case when p_new='issued' and paid_at is null then o.total else paid_amount end,
    paid_by         = case when p_new='issued' and paid_at is null then p_actor else paid_by end,
    refunded_amount = case when p_new='cancelled' and paid_at is not null then coalesce(paid_amount,0) else refunded_amount end,
    refunded_at     = case when p_new='cancelled' and paid_at is not null and refunded_at is null then now() else refunded_at end
  where id=p_order;
  insert into order_status_history(order_id,old_status,new_status,actor) values(p_order,o.status,p_new,p_actor::text);
  if p_new in ('issued','cancelled') then
    perform _audit_c(p_actor,'order_'||p_new::text,'order',p_order::text,jsonb_build_object('status',o.status),jsonb_build_object('status',p_new,'number',o.number),o.city_id);
  end if;
  return jsonb_build_object('id',p_order,'status',p_new,'number',o.number,'city_id',o.city_id);
end $$;

-- ----------------------------------------------------------------- Ручная корректировка остатка с партиями
create or replace function admin_set_stock(p_actor bigint, p_inventory uuid, p_new_qty int, p_kind text default 'adjust', p_reason text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare i inventory; qbefore int; delta int; uc numeric;
begin
  if p_new_qty is null or p_new_qty<0 then raise exception 'bad_quantity'; end if;
  if p_kind not in ('receipt','adjust') then raise exception 'bad_kind'; end if;
  select * into i from inventory where id=p_inventory for update;
  if not found then raise exception 'item_not_found'; end if;
  perform _assert_role(p_actor, i.city_id);
  if p_new_qty < i.reserved_quantity then raise exception 'below_reserved'; end if;
  qbefore := i.quantity; delta := p_new_qty - qbefore;
  if delta = 0 then return jsonb_build_object('id',p_inventory,'quantity',qbefore,'reserved',i.reserved_quantity,'changed',false); end if;
  if p_kind='receipt' and delta<0 then raise exception 'bad_kind'; end if;
  update inventory set quantity=p_new_qty where id=p_inventory;
  insert into inventory_transactions(inventory_id,op,quantity,qty_before,qty_after,city_id,actor,reason)
  values(p_inventory, p_kind::inv_op, abs(delta), qbefore, p_new_qty, i.city_id, p_actor, nullif(trim(coalesce(p_reason,'')),''));
  if delta > 0 then
    -- Ручной приход без закупки: себестоимость = последняя партия позиции, иначе cost_price товара.
    -- Для точной себестоимости оформляйте закупку.
    select unit_cost into uc from stock_batches where inventory_id=p_inventory order by received_at desc, id desc limit 1;
    if uc is null then select cost_price into uc from products where id=i.product_id; end if;
    perform _batch_add(p_inventory, delta, uc, now(), case when p_kind='receipt' then 'receipt' else 'adjustment' end, null, null);
  else
    perform _fifo_consume(p_inventory, -delta, 'writeoff', null, null, null, p_actor);
  end if;
  perform _audit_c(p_actor,'stock_set','inventory',p_inventory::text,jsonb_build_object('quantity',qbefore),
                   jsonb_build_object('quantity',p_new_qty,'kind',p_kind,'reason',nullif(trim(coalesce(p_reason,'')),'')),i.city_id);
  return jsonb_build_object('id',p_inventory,'quantity',p_new_qty,'reserved',i.reserved_quantity,'changed',true);
end $$;

-- ----------------------------------------------------------------- Поставщики
create or replace function supplier_save(p_actor bigint, p_id bigint, p_name text, p_contact text, p_note text, p_active boolean) returns jsonb
language plpgsql security definer set search_path=public as $$
declare s suppliers%rowtype;
begin
  perform _finance_owner(p_actor);
  if p_id is null then
    if nullif(trim(coalesce(p_name,'')),'') is null then raise exception 'bad_name'; end if;
    begin
      insert into suppliers(name,contact,note) values(trim(p_name),coalesce(trim(p_contact),''),coalesce(trim(p_note),'')) returning * into s;
    exception when unique_violation then raise exception 'name_taken'; end;
    perform _audit(p_actor,'supplier_create','supplier',s.id::text,null,jsonb_build_object('name',s.name));
  else
    select * into s from suppliers where id=p_id for update;
    if not found then raise exception 'item_not_found'; end if;
    update suppliers set name=coalesce(nullif(trim(p_name),''),name), contact=coalesce(trim(p_contact),contact),
           note=coalesce(trim(p_note),note), active=coalesce(p_active,active) where id=p_id returning * into s;
  end if;
  return jsonb_build_object('id',s.id,'name',s.name,'contact',s.contact,'note',s.note,'active',s.active);
end $$;

create or replace function suppliers_list(p_actor bigint) returns jsonb
language plpgsql stable security definer set search_path=public as $$
begin
  perform _finance_owner(p_actor);
  return coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'contact',contact,'note',note,'active',active) order by name) from suppliers),'[]'::jsonb);
end $$;

-- ----------------------------------------------------------------- Закупки
-- Создание (p_purchase = null) или правка черновика. Состав позиций заменяется целиком.
-- p_items: [{inventory_id, quantity, unit_price}]. Идемпотентность создания — по p_key.
create or replace function purchase_save(p_actor bigint, p_purchase bigint, p_supplier bigint, p_city text, p_date date,
                                         p_shipping numeric, p_extra numeric, p_note text, p_items jsonb, p_key text) returns jsonb
language plpgsql security definer set search_path=public as $$
declare p purchases%rowtype; it jsonb;
begin
  perform _finance_owner(p_actor);
  if p_key is null or length(p_key) < 8 then raise exception 'key_required'; end if;
  if p_purchase is null then
    select * into p from purchases where idempotency_key=p_key;
    if found then return jsonb_build_object('id',p.id,'number',p.number,'duplicate',true); end if;
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 200 then raise exception 'empty_order'; end if;
  if p_shipping is null or p_shipping < 0 or p_extra is null or p_extra < 0 then raise exception 'bad_amount'; end if;
  if p_supplier is not null and not exists(select 1 from suppliers where id=p_supplier and active) then raise exception 'supplier_not_found'; end if;
  if not exists(select 1 from cities where id=p_city) then raise exception 'bad_city'; end if;
  if (select count(*) from jsonb_array_elements(p_items) e) <> (select count(distinct e->>'inventory_id') from jsonb_array_elements(p_items) e) then
    raise exception 'duplicate_item';
  end if;
  for it in select e from jsonb_array_elements(p_items) e loop
    if (it->>'quantity') is null or (it->>'quantity')::int <= 0 or (it->>'unit_price') is null or (it->>'unit_price')::numeric < 0 then raise exception 'bad_quantity'; end if;
    if not exists(select 1 from inventory where id=(it->>'inventory_id')::uuid and city_id=p_city) then raise exception 'city_mismatch'; end if;
  end loop;

  if p_purchase is null then
    insert into purchases(number,supplier_id,city_id,purchase_date,shipping_cost,extra_cost,note,created_by,idempotency_key)
    values('PO-'||to_char(now() at time zone 'Europe/Berlin','YYYYMMDD')||'-'||lpad(nextval('purchase_seq')::text,4,'0'),
           p_supplier,p_city,coalesce(p_date,current_date),round(p_shipping,2),round(p_extra,2),coalesce(trim(p_note),''),p_actor,p_key)
    returning * into p;
  else
    select * into p from purchases where id=p_purchase for update;
    if not found then raise exception 'item_not_found'; end if;
    if p.status <> 'draft' then raise exception 'bad_status'; end if;
    update purchases set supplier_id=p_supplier, city_id=p_city, purchase_date=coalesce(p_date,purchase_date),
           shipping_cost=round(p_shipping,2), extra_cost=round(p_extra,2), note=coalesce(trim(p_note),'') where id=p.id returning * into p;
    delete from purchase_items where purchase_id=p.id;
  end if;
  insert into purchase_items(purchase_id,inventory_id,quantity,unit_price)
  select p.id,(e->>'inventory_id')::uuid,(e->>'quantity')::int,(e->>'unit_price')::numeric from jsonb_array_elements(p_items) e;
  return jsonb_build_object('id',p.id,'number',p.number,'duplicate',false);
end $$;

create or replace function purchase_cancel(p_actor bigint, p_purchase bigint, p_reason text) returns jsonb
language plpgsql security definer set search_path=public as $$
declare p purchases%rowtype;
begin
  perform _finance_owner(p_actor);
  select * into p from purchases where id=p_purchase for update;
  if not found then raise exception 'item_not_found'; end if;
  if p.status = 'cancelled' then return jsonb_build_object('id',p.id,'status','cancelled','duplicate',true); end if;
  if p.status <> 'draft' then raise exception 'bad_status'; end if;
  update purchases set status='cancelled' where id=p.id;
  perform _audit_c(p_actor,'purchase_cancel','purchase',p.id::text,null,jsonb_build_object('number',p.number,'reason',left(coalesce(p_reason,''),300)),p.city_id);
  return jsonb_build_object('id',p.id,'status','cancelled','duplicate',false);
end $$;

-- Проведение: поступление на склад, партии, (опционально) оплата со счёта.
create or replace function purchase_post(p_actor bigint, p_purchase bigint, p_account bigint, p_key text) returns jsonb
language plpgsql security definer set search_path=public as $$
declare p purchases%rowtype; it record; a cash_accounts%rowtype; items_sum numeric := 0; extras numeric; alloc numeric; alloc_left numeric;
        n int; k int := 0; line_val numeric; landed numeric; bid bigint; qb int; bal numeric; total numeric;
begin
  perform _finance_owner(p_actor);
  if p_key is null or length(p_key) < 8 then raise exception 'key_required'; end if;
  select * into p from purchases where id=p_purchase for update;
  if not found then raise exception 'item_not_found'; end if;
  if p.status = 'posted' and p.post_key = p_key then return jsonb_build_object('id',p.id,'status','posted','duplicate',true); end if;
  if p.status <> 'draft' then raise exception 'bad_status'; end if;
  select count(*), coalesce(sum(quantity*unit_price),0) into n, items_sum from purchase_items where purchase_id=p.id;
  if n = 0 then raise exception 'empty_order'; end if;
  extras := p.shipping_cost + p.extra_cost;
  total := round(items_sum,2) + extras;

  if p_account is not null then
    select * into a from cash_accounts where id=p_account for update;
    if not found then raise exception 'account_not_found'; end if;
    if not a.active then raise exception 'account_inactive'; end if;
    bal := _account_balance(a.id);
    if not a.allow_negative and bal < total then raise exception 'insufficient_funds'; end if;
  end if;

  perform 1 from inventory where id in (select inventory_id from purchase_items where purchase_id=p.id) order by id for update;

  alloc_left := extras;
  for it in select pi.*, i.quantity inv_qty, i.city_id icity from purchase_items pi join inventory i on i.id=pi.inventory_id
            where pi.purchase_id=p.id order by pi.id loop
    if it.icity <> p.city_id then raise exception 'city_mismatch'; end if;
    k := k + 1;
    line_val := it.quantity * it.unit_price;
    if k = n then alloc := alloc_left;                       -- остаток копейки уходит в последнюю позицию: Σ = extras точно
    elsif items_sum > 0 then alloc := round(extras * line_val / items_sum, 2);
    else alloc := round(extras * it.quantity / (select sum(quantity) from purchase_items where purchase_id=p.id), 2);
    end if;
    alloc_left := alloc_left - alloc;
    landed := round((line_val + alloc) / it.quantity, 6);
    update purchase_items set landed_unit_cost=landed where id=it.id;
    bid := _batch_add(it.inventory_id, it.quantity, landed, now(), 'purchase', it.id, null);
    insert into inventory_transactions(inventory_id,op,quantity,qty_before,qty_after,city_id,actor,reason)
    values(it.inventory_id,'receipt'::inv_op,it.quantity,it.inv_qty,it.inv_qty+it.quantity,p.city_id,p_actor,'Закупка '||p.number);
    update inventory set quantity=quantity+it.quantity where id=it.inventory_id;
  end loop;

  if p_account is not null then
    insert into cash_entries(account_id,amount,kind,purchase_id,reason,actor,idempotency_key)
    values(a.id,-total,'purchase',p.id,'Закупка '||p.number,p_actor,'pur:'||p_key);
  end if;
  update purchases set status='posted', items_total=round(items_sum,2), total_cost=total, account_id=p_account,
         posted_by=p_actor, posted_at=now(), post_key=p_key where id=p.id;
  perform _audit_c(p_actor,'purchase_post','purchase',p.id::text,null,jsonb_build_object('number',p.number,'total',total,'account',p_account),p.city_id);
  return jsonb_build_object('id',p.id,'status','posted','total_cost',total,'duplicate',false);
end $$;

-- Сторно проведённой закупки: возможно, только пока ни одна единица партий не продана и не перемещена.
create or replace function purchase_reverse(p_actor bigint, p_purchase bigint, p_reason text, p_key text) returns jsonb
language plpgsql security definer set search_path=public as $$
declare p purchases%rowtype; b record; rs text := trim(coalesce(p_reason,'')); ce cash_entries%rowtype; a cash_accounts%rowtype; inv inventory%rowtype;
begin
  perform _finance_owner(p_actor);
  if p_key is null or length(p_key) < 8 then raise exception 'key_required'; end if;
  if length(rs) < 5 or length(rs) > 300 then raise exception 'reason_required'; end if;
  select * into p from purchases where id=p_purchase for update;
  if not found then raise exception 'item_not_found'; end if;
  if p.status = 'reversed' then return jsonb_build_object('id',p.id,'status','reversed','duplicate',true); end if;
  if p.status <> 'posted' then raise exception 'bad_status'; end if;
  perform 1 from inventory where id in (select inventory_id from purchase_items where purchase_id=p.id) order by id for update;
  if exists(select 1 from stock_batches sb join purchase_items pi on pi.id=sb.purchase_item_id
            where pi.purchase_id=p.id and sb.qty_remaining <> sb.qty_initial) then raise exception 'batch_consumed'; end if;
  for b in select sb.id, sb.inventory_id, sb.qty_remaining, sb.unit_cost from stock_batches sb join purchase_items pi on pi.id=sb.purchase_item_id
           where pi.purchase_id=p.id order by sb.id loop
    select * into inv from inventory where id=b.inventory_id;
    if inv.quantity - inv.reserved_quantity < b.qty_remaining then raise exception 'insufficient_stock'; end if;
    update stock_batches set qty_remaining=0 where id=b.id;
    insert into batch_consumptions(batch_id,inventory_id,kind,quantity,unit_cost,actor) values(b.id,b.inventory_id,'purchase_reversal',b.qty_remaining,b.unit_cost,p_actor);
    insert into inventory_transactions(inventory_id,op,quantity,qty_before,qty_after,city_id,actor,reason)
    values(b.inventory_id,'adjust'::inv_op,b.qty_remaining,inv.quantity,inv.quantity-b.qty_remaining,inv.city_id,p_actor,'Сторно закупки '||p.number);
    update inventory set quantity=quantity-b.qty_remaining where id=b.inventory_id;
  end loop;
  if p.account_id is not null then
    select * into a from cash_accounts where id=p.account_id for update;
    select * into ce from cash_entries where purchase_id=p.id and kind='purchase' and reverses_id is null;
    if found then
      insert into cash_entries(account_id,amount,kind,purchase_id,reverses_id,reason,actor,idempotency_key)
      values(ce.account_id,-ce.amount,'purchase',p.id,ce.id,rs,p_actor,'purrev:'||p_key);
    end if;
  end if;
  update purchases set status='reversed', reversed_by=p_actor, reversed_at=now(), reverse_reason=rs where id=p.id;
  perform _audit_c(p_actor,'purchase_reverse','purchase',p.id::text,jsonb_build_object('status','posted'),jsonb_build_object('status','reversed','reason',rs),p.city_id);
  return jsonb_build_object('id',p.id,'status','reversed','duplicate',false);
end $$;

create or replace function purchases_list(p_actor bigint, p_status text, p_limit int default 100) returns jsonb
language plpgsql stable security definer set search_path=public as $$
begin
  perform _finance_owner(p_actor);
  return coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'number',p.number,'status',p.status,'purchase_date',p.purchase_date,
      'city_id',p.city_id,'supplier',s.name,'supplier_id',p.supplier_id,'shipping_cost',p.shipping_cost,'extra_cost',p.extra_cost,
      'items_total',coalesce(p.items_total,(select sum(quantity*unit_price) from purchase_items where purchase_id=p.id)),'total_cost',p.total_cost,
      'units',(select coalesce(sum(quantity),0) from purchase_items where purchase_id=p.id),'account_id',p.account_id,'posted_at',p.posted_at)
      order by p.id desc)
    from (select * from purchases where p_status is null or status=p_status order by id desc limit least(greatest(coalesce(p_limit,100),1),300)) p
    left join suppliers s on s.id=p.supplier_id), '[]'::jsonb);
end $$;

create or replace function purchase_get(p_actor bigint, p_purchase bigint) returns jsonb
language plpgsql stable security definer set search_path=public as $$
declare p purchases%rowtype;
begin
  perform _finance_owner(p_actor);
  select * into p from purchases where id=p_purchase;
  if not found then raise exception 'item_not_found'; end if;
  return jsonb_build_object('id',p.id,'number',p.number,'status',p.status,'purchase_date',p.purchase_date,'city_id',p.city_id,
    'supplier_id',p.supplier_id,'shipping_cost',p.shipping_cost,'extra_cost',p.extra_cost,'note',p.note,'items_total',p.items_total,
    'total_cost',p.total_cost,'account_id',p.account_id,'posted_at',p.posted_at,'reverse_reason',p.reverse_reason,
    'items',coalesce((select jsonb_agg(jsonb_build_object('id',pi.id,'inventory_id',pi.inventory_id,'product_name',pr.name,'variant_name',v.name,
        'quantity',pi.quantity,'unit_price',pi.unit_price,'landed_unit_cost',pi.landed_unit_cost) order by pi.id)
      from purchase_items pi join inventory i on i.id=pi.inventory_id join products pr on pr.id=i.product_id
      left join product_variants v on v.id=i.variant_id where pi.purchase_id=p.id),'[]'::jsonb));
end $$;

-- Партии (остатки по себестоимости). Только владелец.
create or replace function stock_batches_list(p_actor bigint, p_city text, p_only_open boolean default true) returns jsonb
language plpgsql stable security definer set search_path=public as $$
begin
  perform _finance_owner(p_actor);
  return coalesce((select jsonb_agg(jsonb_build_object('id',b.id,'city_id',b.city_id,'inventory_id',b.inventory_id,'product_name',pr.name,
      'variant_name',v.name,'source',b.source,'received_at',b.received_at,'qty_initial',b.qty_initial,'qty_remaining',b.qty_remaining,
      'unit_cost',b.unit_cost,'value',b.qty_remaining*coalesce(b.unit_cost,0)) order by b.city_id, pr.name, b.received_at, b.id)
    from stock_batches b join products pr on pr.id=b.product_id join inventory i on i.id=b.inventory_id left join product_variants v on v.id=i.variant_id
    where (p_city is null or b.city_id=p_city) and (not coalesce(p_only_open,true) or b.qty_remaining>0)), '[]'::jsonb);
end $$;

-- Диагностика: позиции, где остаток склада не равен сумме остатков партий.
create or replace function inventory_batch_check(p_actor bigint) returns jsonb
language plpgsql stable security definer set search_path=public as $$
begin
  perform _finance_owner(p_actor);
  return coalesce((select jsonb_agg(jsonb_build_object('inventory_id',i.id,'city_id',i.city_id,'quantity',i.quantity,'batches',coalesce(s.q,0)))
    from inventory i left join (select inventory_id, sum(qty_remaining)::int q from stock_batches group by inventory_id) s on s.inventory_id=i.id
    where i.quantity <> coalesce(s.q,0)), '[]'::jsonb);
end $$;

-- ----------------------------------------------------------------- Права
select _lockdown_public_tables();
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on all functions in schema public to service_role;

insert into schema_migrations(version) values('0022');
