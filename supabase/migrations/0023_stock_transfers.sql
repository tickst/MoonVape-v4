-- =============================================================================
-- MoonVape v4 · миграция 0023 · перемещение товаров между городами (с «в пути»)
-- Запускать ПОСЛЕ 0022. Один Run в SQL Editor. Перед запуском — резервная копия БД.
--
-- Процесс: draft → in_transit (отправка) → received (получение) | cancelled.
--   Отправка: товар списывается со склада-отправителя по FIFO; «слои» себестоимости
--     (партия, количество, цена, дата поступления) запоминаются в stock_transfer_layers.
--   Получение: на складе-получателе создаются партии с ТЕМИ ЖЕ ценой и датой поступления.
--   Отмена в пути: слои возвращаются отправителю как новые партии с прежней ценой и датой.
-- Товар не создаётся и не исчезает: Σ(склады) + «в пути» постоянна, стоимость тоже.
-- Права: только владелец. admin_transfer_stock сохранён (создать+отправить+получить за один шаг).
-- =============================================================================

do $$ begin
  if exists(select 1 from schema_migrations where version='0023') then raise exception 'migration 0023 already applied'; end if;
  if not exists(select 1 from schema_migrations where version='0022') then raise exception 'run 0022 first'; end if;
end $$;

create sequence transfer_seq;
create table stock_transfers(
  id bigserial primary key,
  number text not null unique,
  from_city text not null references cities(id),
  to_city text not null references cities(id),
  status text not null default 'draft' check (status in ('draft','in_transit','received','cancelled')),
  note text not null default '' check (length(note) <= 500),
  created_by bigint not null, created_at timestamptz not null default now(),
  sent_by bigint, sent_at timestamptz, send_key text unique,
  received_by bigint, received_at timestamptz, receive_key text unique,
  cancelled_by bigint, cancelled_at timestamptz, cancel_reason text,
  idempotency_key text not null unique,
  check (from_city <> to_city)
);
create index stock_transfers_status_idx on stock_transfers(status, created_at desc);
alter table stock_transfers enable row level security;

create table stock_transfer_items(
  id bigserial primary key,
  transfer_id bigint not null references stock_transfers(id) on delete cascade,
  from_inventory_id uuid not null references inventory(id),
  to_inventory_id uuid not null references inventory(id),
  quantity int not null check (quantity > 0 and quantity <= 100000),
  unique (transfer_id, from_inventory_id)
);
alter table stock_transfer_items enable row level security;

create table stock_transfer_layers(
  id bigserial primary key,
  item_id bigint not null references stock_transfer_items(id),
  quantity int not null check (quantity > 0),
  unit_cost numeric(14,6),
  received_at timestamptz not null,
  source_batch_id bigint references stock_batches(id),
  dest_batch_id bigint references stock_batches(id),
  returned_batch_id bigint references stock_batches(id)
);
alter table stock_transfer_layers enable row level security;

alter table stock_batches add constraint stock_batches_transfer_item_fk foreign key (transfer_item_id) references stock_transfer_items(id);
alter table batch_consumptions add constraint batch_consumptions_transfer_item_fk foreign key (transfer_item_id) references stock_transfer_items(id);

-- Создание/правка черновика. p_items: [{inventory_id (склад-отправитель), quantity}].
create or replace function transfer_save(p_actor bigint, p_transfer bigint, p_from text, p_to text, p_note text, p_items jsonb, p_key text) returns jsonb
language plpgsql security definer set search_path=public as $$
declare t stock_transfers%rowtype; it jsonb; f inventory%rowtype; d bigint;
begin
  perform _finance_owner(p_actor);
  if p_key is null or length(p_key) < 8 then raise exception 'key_required'; end if;
  if p_transfer is null then
    select * into t from stock_transfers where idempotency_key=p_key;
    if found then return jsonb_build_object('id',t.id,'number',t.number,'duplicate',true); end if;
  end if;
  if p_from is null or p_to is null or p_from = p_to then raise exception 'bad_transfer'; end if;
  if not exists(select 1 from cities where id=p_from) or not exists(select 1 from cities where id=p_to) then raise exception 'bad_city'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 200 then raise exception 'empty_order'; end if;
  if (select count(*) from jsonb_array_elements(p_items) e) <> (select count(distinct e->>'inventory_id') from jsonb_array_elements(p_items) e) then
    raise exception 'duplicate_item';
  end if;
  for it in select e from jsonb_array_elements(p_items) e loop
    if (it->>'quantity') is null or (it->>'quantity')::int <= 0 then raise exception 'bad_quantity'; end if;
    select * into f from inventory where id=(it->>'inventory_id')::uuid;
    if not found then raise exception 'item_not_found'; end if;
    if f.city_id <> p_from then raise exception 'city_mismatch'; end if;
    select id into d from inventory where product_id=f.product_id and variant_id is not distinct from f.variant_id and city_id=p_to;
    if d is null then raise exception 'dest_inventory_missing'; end if;
  end loop;

  if p_transfer is null then
    insert into stock_transfers(number,from_city,to_city,note,created_by,idempotency_key)
    values('TR-'||to_char(now() at time zone 'Europe/Berlin','YYYYMMDD')||'-'||lpad(nextval('transfer_seq')::text,4,'0'),
           p_from,p_to,coalesce(trim(p_note),''),p_actor,p_key) returning * into t;
  else
    select * into t from stock_transfers where id=p_transfer for update;
    if not found then raise exception 'item_not_found'; end if;
    if t.status <> 'draft' then raise exception 'bad_status'; end if;
    update stock_transfers set from_city=p_from, to_city=p_to, note=coalesce(trim(p_note),'') where id=t.id returning * into t;
    delete from stock_transfer_items where transfer_id=t.id;
  end if;
  insert into stock_transfer_items(transfer_id,from_inventory_id,to_inventory_id,quantity)
  select t.id, f2.id, (select id from inventory where product_id=f2.product_id and variant_id is not distinct from f2.variant_id and city_id=p_to),
         (e->>'quantity')::int
  from jsonb_array_elements(p_items) e join inventory f2 on f2.id=(e->>'inventory_id')::uuid;
  return jsonb_build_object('id',t.id,'number',t.number,'duplicate',false);
end $$;

-- Отправка: товар уходит со склада, слои себестоимости запоминаются.
create or replace function transfer_send(p_actor bigint, p_transfer bigint, p_key text) returns jsonb
language plpgsql security definer set search_path=public as $$
declare t stock_transfers%rowtype; it record; fc jsonb; part jsonb; inv inventory%rowtype; n int;
begin
  perform _finance_owner(p_actor);
  if p_key is null or length(p_key) < 8 then raise exception 'key_required'; end if;
  select * into t from stock_transfers where id=p_transfer for update;
  if not found then raise exception 'item_not_found'; end if;
  if t.status = 'in_transit' and t.send_key = p_key then return jsonb_build_object('id',t.id,'status','in_transit','duplicate',true); end if;
  if t.status <> 'draft' then raise exception 'bad_status'; end if;
  select count(*) into n from stock_transfer_items where transfer_id=t.id;
  if n = 0 then raise exception 'empty_order'; end if;
  perform 1 from inventory where id in (select from_inventory_id from stock_transfer_items where transfer_id=t.id) order by id for update;
  for it in select * from stock_transfer_items where transfer_id=t.id order by from_inventory_id loop
    select * into inv from inventory where id=it.from_inventory_id;
    if inv.quantity - inv.reserved_quantity < it.quantity then raise exception 'insufficient_stock'; end if;
    fc := _fifo_consume(it.from_inventory_id, it.quantity, 'transfer', null, null, it.id, p_actor);
    for part in select x from jsonb_array_elements(fc->'parts') x loop
      insert into stock_transfer_layers(item_id,quantity,unit_cost,received_at,source_batch_id)
      values(it.id,(part->>'qty')::int,(part->>'unit_cost')::numeric,(part->>'received_at')::timestamptz,(part->>'batch_id')::bigint);
    end loop;
    insert into inventory_transactions(inventory_id,op,quantity,qty_before,qty_after,city_id,actor,reason)
    values(inv.id,'transfer'::inv_op,it.quantity,inv.quantity,inv.quantity-it.quantity,inv.city_id,p_actor,'Отправка '||t.number||' в '||t.to_city);
    update inventory set quantity=quantity-it.quantity where id=inv.id;
  end loop;
  update stock_transfers set status='in_transit', sent_by=p_actor, sent_at=now(), send_key=p_key where id=t.id;
  perform _audit_c(p_actor,'transfer_send','stock_transfer',t.id::text,null,jsonb_build_object('number',t.number,'from',t.from_city,'to',t.to_city),t.from_city);
  return jsonb_build_object('id',t.id,'status','in_transit','duplicate',false);
end $$;

-- Получение: на складе-получателе появляются партии с прежней ценой и датой поступления.
create or replace function transfer_receive(p_actor bigint, p_transfer bigint, p_key text) returns jsonb
language plpgsql security definer set search_path=public as $$
declare t stock_transfers%rowtype; it record; l record; inv inventory%rowtype; bid bigint;
begin
  perform _finance_owner(p_actor);
  if p_key is null or length(p_key) < 8 then raise exception 'key_required'; end if;
  select * into t from stock_transfers where id=p_transfer for update;
  if not found then raise exception 'item_not_found'; end if;
  if t.status = 'received' and t.receive_key = p_key then return jsonb_build_object('id',t.id,'status','received','duplicate',true); end if;
  if t.status <> 'in_transit' then raise exception 'bad_status'; end if;
  perform 1 from inventory where id in (select to_inventory_id from stock_transfer_items where transfer_id=t.id) order by id for update;
  for it in select * from stock_transfer_items where transfer_id=t.id order by to_inventory_id loop
    select * into inv from inventory where id=it.to_inventory_id;
    for l in select * from stock_transfer_layers where item_id=it.id order by id loop
      bid := _batch_add(it.to_inventory_id, l.quantity, l.unit_cost, l.received_at, 'transfer', null, it.id);
      update stock_transfer_layers set dest_batch_id=bid where id=l.id;
    end loop;
    insert into inventory_transactions(inventory_id,op,quantity,qty_before,qty_after,city_id,actor,reason)
    values(inv.id,'transfer'::inv_op,it.quantity,inv.quantity,inv.quantity+it.quantity,inv.city_id,p_actor,'Получение '||t.number||' из '||t.from_city);
    update inventory set quantity=quantity+it.quantity where id=inv.id;
  end loop;
  update stock_transfers set status='received', received_by=p_actor, received_at=now(), receive_key=p_key where id=t.id;
  perform _audit_c(p_actor,'transfer_receive','stock_transfer',t.id::text,null,jsonb_build_object('number',t.number,'from',t.from_city,'to',t.to_city),t.to_city);
  return jsonb_build_object('id',t.id,'status','received','duplicate',false);
end $$;

-- Отмена: черновик — просто закрывается; «в пути» — товар возвращается отправителю с прежней себестоимостью.
create or replace function transfer_cancel(p_actor bigint, p_transfer bigint, p_reason text) returns jsonb
language plpgsql security definer set search_path=public as $$
declare t stock_transfers%rowtype; it record; l record; inv inventory%rowtype; bid bigint; rs text := trim(coalesce(p_reason,''));
begin
  perform _finance_owner(p_actor);
  if length(rs) < 5 or length(rs) > 300 then raise exception 'reason_required'; end if;
  select * into t from stock_transfers where id=p_transfer for update;
  if not found then raise exception 'item_not_found'; end if;
  if t.status = 'cancelled' then return jsonb_build_object('id',t.id,'status','cancelled','duplicate',true); end if;
  if t.status not in ('draft','in_transit') then raise exception 'bad_status'; end if;
  if t.status = 'in_transit' then
    perform 1 from inventory where id in (select from_inventory_id from stock_transfer_items where transfer_id=t.id) order by id for update;
    for it in select * from stock_transfer_items where transfer_id=t.id order by from_inventory_id loop
      select * into inv from inventory where id=it.from_inventory_id;
      for l in select * from stock_transfer_layers where item_id=it.id order by id loop
        bid := _batch_add(it.from_inventory_id, l.quantity, l.unit_cost, l.received_at, 'transfer', null, it.id);
        update stock_transfer_layers set returned_batch_id=bid where id=l.id;
      end loop;
      insert into inventory_transactions(inventory_id,op,quantity,qty_before,qty_after,city_id,actor,reason)
      values(inv.id,'transfer'::inv_op,it.quantity,inv.quantity,inv.quantity+it.quantity,inv.city_id,p_actor,'Отмена перемещения '||t.number||' (возврат)');
      update inventory set quantity=quantity+it.quantity where id=inv.id;
    end loop;
  end if;
  update stock_transfers set status='cancelled', cancelled_by=p_actor, cancelled_at=now(), cancel_reason=rs where id=t.id;
  perform _audit_c(p_actor,'transfer_cancel','stock_transfer',t.id::text,jsonb_build_object('status',t.status),jsonb_build_object('status','cancelled','reason',rs),t.from_city);
  return jsonb_build_object('id',t.id,'status','cancelled','duplicate',false);
end $$;

-- Прежний интерфейс «переместить сразу»: создание + отправка + получение в одной транзакции.
create or replace function admin_transfer_stock(p_actor bigint, p_from uuid, p_to uuid, p_qty int, p_reason text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare f inventory; t inventory; r jsonb; tid bigint; k text := gen_random_uuid()::text;
begin
  perform _finance_owner(p_actor);
  if p_qty is null or p_qty<=0 or p_from=p_to then raise exception 'bad_quantity'; end if;
  select * into f from inventory where id=p_from;
  select * into t from inventory where id=p_to;
  if f.id is null or t.id is null then raise exception 'item_not_found'; end if;
  if f.product_id<>t.product_id or f.variant_id is distinct from t.variant_id or f.city_id=t.city_id then raise exception 'bad_transfer'; end if;
  r := transfer_save(p_actor, null, f.city_id, t.city_id, coalesce(nullif(trim(coalesce(p_reason,'')),''),''), jsonb_build_array(jsonb_build_object('inventory_id',p_from,'quantity',p_qty)), k);
  tid := (r->>'id')::bigint;
  perform transfer_send(p_actor, tid, k||':s');
  perform transfer_receive(p_actor, tid, k||':r');
  return jsonb_build_object('from',p_from,'to',p_to,'qty',p_qty,'transfer_id',tid);
end $$;

create or replace function transfers_list(p_actor bigint, p_status text, p_limit int default 100) returns jsonb
language plpgsql stable security definer set search_path=public as $$
begin
  perform _finance_owner(p_actor);
  return coalesce((select jsonb_agg(jsonb_build_object('id',t.id,'number',t.number,'status',t.status,'from_city',t.from_city,'to_city',t.to_city,
      'note',t.note,'created_at',t.created_at,'sent_at',t.sent_at,'received_at',t.received_at,
      'units',(select coalesce(sum(quantity),0) from stock_transfer_items where transfer_id=t.id),
      'value',(select coalesce(sum(l.quantity*coalesce(l.unit_cost,0)),0) from stock_transfer_layers l join stock_transfer_items i on i.id=l.item_id where i.transfer_id=t.id))
      order by t.id desc)
    from (select * from stock_transfers where p_status is null or status=p_status order by id desc limit least(greatest(coalesce(p_limit,100),1),300)) t), '[]'::jsonb);
end $$;

create or replace function transfer_get(p_actor bigint, p_transfer bigint) returns jsonb
language plpgsql stable security definer set search_path=public as $$
declare t stock_transfers%rowtype;
begin
  perform _finance_owner(p_actor);
  select * into t from stock_transfers where id=p_transfer;
  if not found then raise exception 'item_not_found'; end if;
  return jsonb_build_object('id',t.id,'number',t.number,'status',t.status,'from_city',t.from_city,'to_city',t.to_city,'note',t.note,
    'created_at',t.created_at,'sent_at',t.sent_at,'received_at',t.received_at,'cancel_reason',t.cancel_reason,
    'items',coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'from_inventory_id',i.from_inventory_id,'product_name',pr.name,'variant_name',v.name,
        'quantity',i.quantity,'cost',(select coalesce(sum(l.quantity*coalesce(l.unit_cost,0)),0) from stock_transfer_layers l where l.item_id=i.id)) order by i.id)
      from stock_transfer_items i join inventory inv on inv.id=i.from_inventory_id join products pr on pr.id=inv.product_id
      left join product_variants v on v.id=inv.variant_id where i.transfer_id=t.id),'[]'::jsonb));
end $$;

-- Остатки по себестоимости: склады городов + «в пути».
create or replace function inventory_valuation(p_actor bigint) returns jsonb
language plpgsql stable security definer set search_path=public as $$
declare transit_units int; transit_value numeric;
begin
  perform _finance_owner(p_actor);
  select coalesce(sum(l.quantity),0), coalesce(sum(l.quantity*coalesce(l.unit_cost,0)),0) into transit_units, transit_value
  from stock_transfer_layers l join stock_transfer_items i on i.id=l.item_id join stock_transfers t on t.id=i.transfer_id where t.status='in_transit';
  return jsonb_build_object(
    'by_city', coalesce((select jsonb_agg(jsonb_build_object('city_id',c.id,'name',c.name,'units',coalesce(s.u,0),'value',coalesce(s.v,0),'unknown_cost_units',coalesce(s.m,0)) order by c.sort,c.id)
       from cities c left join (select city_id, sum(qty_remaining)::int u, sum(qty_remaining*coalesce(unit_cost,0)) v,
                                       sum(qty_remaining) filter (where unit_cost is null)::int m
                                from stock_batches where qty_remaining>0 group by city_id) s on s.city_id=c.id),'[]'::jsonb),
    'in_transit', jsonb_build_object('units',transit_units,'value',transit_value),
    'total_value', coalesce((select sum(qty_remaining*coalesce(unit_cost,0)) from stock_batches where qty_remaining>0),0) + transit_value,
    'total_units', coalesce((select sum(qty_remaining) from stock_batches where qty_remaining>0),0) + transit_units);
end $$;

select _lockdown_public_tables();
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on all functions in schema public to service_role;

insert into schema_migrations(version) values('0023');
