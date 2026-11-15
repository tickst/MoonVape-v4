-- =============================================================================
-- MoonVape v4 · миграция 0020 · индивидуальные цены клиентов
-- Запускать ПОСЛЕ 0019. Один Run в SQL Editor. Перед запуском — резервная копия БД.
--
-- Приоритет цены (единый серверный расчёт _pricing_for):
--   1. индивидуальная цена клиента на товар (активная, в пределах срока действия);
--   2. иначе оптовая ступень товара (по общему количеству единиц заказа);
--   3. иначе розничная цена (цена варианта или товара).
-- Заказ от 50 единиц требует согласования только для позиций БЕЗ персональной цены.
--
-- Снимок в заказе: order_items.unit_price (применённая цена), price_source
--   ('retail'|'tier'|'personal'|'manual'), reference_price (цена без персональной),
--   personal_price_id. Старые заказы не пересчитываются при изменении персональной цены.
--
-- Исправление безопасности: pricing_preview и customer_edit_preview отдавали покупателю
-- unit_cost (себестоимость) каждой позиции. Теперь ответ покупателю очищается (_pricing_public).
-- =============================================================================

do $$ begin
  if exists(select 1 from schema_migrations where version='0020') then raise exception 'migration 0020 already applied'; end if;
  if not exists(select 1 from schema_migrations where version='0019') then raise exception 'run 0019 first'; end if;
end $$;

-- ----------------------------------------------------------------- Таблица
create table customer_prices(
  id bigserial primary key,
  user_id uuid not null references users(id) on delete cascade,
  product_id uuid not null references products(id),
  price numeric(10,2) not null check (price >= 0 and price <= 100000),
  note text not null default '' check (length(note) <= 500),
  valid_from timestamptz not null default now(),
  valid_until timestamptz,
  active boolean not null default true,
  created_by bigint not null,
  created_at timestamptz not null default now(),
  updated_by bigint not null,
  updated_at timestamptz not null default now(),
  unique (user_id, product_id),
  check (valid_until is null or valid_until > valid_from)
);
create index customer_prices_user_idx on customer_prices(user_id);
alter table customer_prices enable row level security;   -- без политик: только service_role

alter table order_items add column if not exists price_source text;
alter table order_items add column if not exists reference_price numeric(10,2);
alter table order_items add column if not exists personal_price_id bigint references customer_prices(id) on delete set null;
do $$ begin
  if not exists(select 1 from pg_constraint where conname='order_items_price_source_check') then
    alter table order_items add constraint order_items_price_source_check
      check (price_source is null or price_source in ('retail','tier','personal','manual'));
  end if;
end $$;
alter table orders add column if not exists has_personal_price boolean not null default false;

-- ----------------------------------------------------------------- Единый расчёт
-- Возвращает полный расчёт (включая себестоимость) — ТОЛЬКО для внутреннего использования.
create or replace function _pricing_for(p_city text, p_items jsonb, p_user uuid) returns jsonb
language plpgsql stable set search_path=public as $$
declare
  units int; t jsonb; tmin int; need_manual boolean := false; tot numeric := 0; retail_tot numeric := 0;
  r record; unit numeric; ref numeric; tp numeric; lt numeric; src text; lines jsonb := '[]'::jsonb;
  n_req int; n_exist int; n_city int; is_wh boolean; has_personal boolean := false;
begin
  if p_city is null then raise exception 'city_required'; end if;
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'empty_order'; end if;
  if exists(select 1 from jsonb_array_elements(p_items) e where (e->>'quantity') is null or (e->>'quantity')::int<=0 or (e->>'quantity')::int>1000)
    then raise exception 'bad_quantity'; end if;
  select coalesce(sum((e->>'quantity')::int),0) into units from jsonb_array_elements(p_items) e;
  select count(distinct (e->>'inventory_id')::uuid) into n_req from jsonb_array_elements(p_items) e;
  select count(*) into n_exist from inventory i join products pr on pr.id=i.product_id and pr.active
    where i.id in (select (e->>'inventory_id')::uuid from jsonb_array_elements(p_items) e);
  if n_exist<>n_req then raise exception 'item_not_found'; end if;
  select count(*) into n_city from inventory where city_id=p_city and id in (select (e->>'inventory_id')::uuid from jsonb_array_elements(p_items) e);
  if n_city<>n_req then raise exception 'city_mismatch'; end if;

  t := _tier_of(units);
  tmin := (t->>'min')::int;
  is_wh := tmin>=3;

  for r in
    select x.iid, x.q, i.product_id, pr.name pname, v.name vname, coalesce(v.price,pr.price) retail, pr.cost_price cost,
           cp.id cp_id, cp.price cp_price
    from (select (e->>'inventory_id')::uuid iid, sum((e->>'quantity')::int)::int q from jsonb_array_elements(p_items) e group by 1) x
    join inventory i on i.id=x.iid
    join products pr on pr.id=i.product_id
    left join product_variants v on v.id=i.variant_id
    left join customer_prices cp on p_user is not null and cp.user_id=p_user and cp.product_id=i.product_id
         and cp.active and cp.valid_from<=now() and (cp.valid_until is null or cp.valid_until>now())
    order by x.iid
  loop
    if r.retail is null then raise exception 'price_missing'; end if;
    -- Цена без персональной: розница, ступень или NULL (50+ — по согласованию).
    ref := null;
    if tmin=1 then ref := r.retail;
    elsif tmin<50 then
      select w.price into tp from wholesale_tiers w where w.product_id=r.product_id and w.tier_min=tmin;
      if tp is null and r.cp_id is null then raise exception 'tier_price_missing'; end if;
      ref := tp;
    end if;
    if r.cp_id is not null then
      unit := r.cp_price; src := 'personal'; has_personal := true;
    elsif ref is not null then
      unit := ref; src := case when tmin=1 then 'retail' else 'tier' end;
    else
      unit := null; src := null; need_manual := true;
    end if;
    if unit is not null then lt := unit*r.q; tot := tot+lt; else lt := null; end if;
    retail_tot := retail_tot + r.retail*r.q;
    lines := lines || jsonb_build_object('inventory_id',r.iid,'product_id',r.product_id,'product_name',r.pname,'variant_name',r.vname,
      'quantity',r.q,'retail_price',r.retail,'unit_price',unit,'line_total',lt,'unit_cost',r.cost,
      'is_wholesale',(is_wh and src is distinct from 'personal'),'price_source',src,'reference_price',ref,
      'personal_price_id',r.cp_id,'below_cost',(unit is not null and r.cost is not null and unit<r.cost));
  end loop;

  return jsonb_build_object('city',p_city,'total_units',units,'tier_min',tmin,'tier_label',t->>'label',
    'approval_required',need_manual,'total',case when need_manual then null else tot end,
    'retail_total',retail_tot,'discount',case when need_manual then null else retail_tot-tot end,
    'has_personal_price',has_personal,'lines',lines);
end $$;

-- Старая сигнатура сохраняется (без персональных цен) — для совместимости.
create or replace function _pricing(p_city text, p_items jsonb) returns jsonb
language sql stable set search_path=public as $$ select _pricing_for(p_city, p_items, null::uuid) $$;

-- Ответ для покупателя: без себестоимости и служебных полей.
create or replace function _pricing_public(p jsonb) returns jsonb
language sql immutable set search_path=public as $$
  select jsonb_set(p, '{lines}', coalesce((select jsonb_agg(l - 'unit_cost' - 'personal_price_id' - 'below_cost')
                                           from jsonb_array_elements(p->'lines') l), '[]'::jsonb))
$$;

drop function if exists pricing_preview(text, jsonb);
create or replace function pricing_preview(p_city text, p_items jsonb, p_user uuid) returns jsonb
language sql stable set search_path=public as $$ select _pricing_public(_pricing_for(p_city, p_items, p_user)) $$;
-- Старая сигнатура (без пользователя) тоже очищается от себестоимости — на время перехода backend.
create or replace function pricing_preview(p_city text, p_items jsonb) returns jsonb
language sql stable set search_path=public as $$ select _pricing_public(_pricing_for(p_city, p_items, null::uuid)) $$;

create or replace function _insert_lines(p_order uuid, p_lines jsonb, p_tier text) returns void
language sql as $$
insert into order_items(order_id,product_id,inventory_id,product_name,variant_name,flavor_name,quantity,unit_price,base_price,
                        is_wholesale,tier_label,unit_cost,price_source,reference_price,personal_price_id)
select p_order, (x->>'product_id')::uuid, (x->>'inventory_id')::uuid, x->>'product_name', x->>'variant_name', null,
       (x->>'quantity')::int, coalesce((x->>'unit_price')::numeric,0), (x->>'retail_price')::numeric,
       (x->>'is_wholesale')::boolean, p_tier, (x->>'unit_cost')::numeric,
       x->>'price_source', (x->>'reference_price')::numeric, (x->>'personal_price_id')::bigint
from jsonb_array_elements(p_lines) x
$$;

-- ----------------------------------------------------------------- Оформление заказа
create or replace function create_order(p_user uuid, p_city text, p_items jsonb, p_contact text, p_comment text, p_key text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare o orders; tg bigint; uc text; pr jsonb; l jsonb;
begin
  select * into o from orders where idempotency_key=p_key;
  if found then return jsonb_build_object('id',o.id,'number',o.number,'duplicate',true); end if;
  select telegram_id, city_id into tg, uc from users where id=p_user;
  if tg is null then raise exception 'user_not_found'; end if;
  if uc is null or p_city is distinct from uc then raise exception 'city_mismatch'; end if;

  pr := _pricing_for(p_city, p_items, p_user);
  perform 1 from inventory where id in (select (x->>'inventory_id')::uuid from jsonb_array_elements(pr->'lines') x) order by id for update;
  for l in select x from jsonb_array_elements(pr->'lines') x loop
    if (select quantity-reserved_quantity from inventory where id=(l->>'inventory_id')::uuid) < (l->>'quantity')::int then
      raise exception 'insufficient_stock';
    end if;
  end loop;

  loop
    begin
      insert into orders(number,user_id,telegram_id,city_id,contact,address,delivery_service,comment,idempotency_key,
                         total,total_units,tier_label,approval_required,has_personal_price)
      values('MOON-'||to_char(now() at time zone 'utc','YYYYMMDD')||'-'||lpad((floor(random()*10000))::int::text,4,'0'),
             p_user,tg,p_city,p_contact,'','',coalesce(p_comment,''),p_key,
             coalesce((pr->>'total')::numeric,0),(pr->>'total_units')::int,pr->>'tier_label',(pr->>'approval_required')::boolean,
             (pr->>'has_personal_price')::boolean)
      returning * into o;
      exit;
    exception when unique_violation then
      select * into o from orders where idempotency_key=p_key;
      if found then return jsonb_build_object('id',o.id,'number',o.number,'duplicate',true); end if;
    end;
  end loop;

  perform _insert_lines(o.id, pr->'lines', pr->>'tier_label');
  for l in select x from jsonb_array_elements(pr->'lines') x loop
    insert into inventory_transactions(inventory_id,order_id,op,quantity,qty_before,qty_after,city_id,reason)
    select i.id,o.id,'reserve'::inv_op,(l->>'quantity')::int,i.quantity,i.quantity,i.city_id,'Резерв под заказ '||o.number
    from inventory i where i.id=(l->>'inventory_id')::uuid;
    update inventory set reserved_quantity=reserved_quantity+(l->>'quantity')::int where id=(l->>'inventory_id')::uuid;
  end loop;

  delete from cart_items where cart_id in (select id from carts where user_id=p_user)
    and inventory_id in (select id from inventory where city_id=p_city);
  insert into order_status_history(order_id,old_status,new_status,actor) values(o.id,null,'new','customer');
  return jsonb_build_object('id',o.id,'number',o.number,'duplicate',false,'total',o.total,
    'total_units',o.total_units,'tier_label',o.tier_label,'approval_required',o.approval_required);
end $$;

-- ----------------------------------------------------------------- Редактирование заказа покупателем
create or replace function customer_edit_preview(p_user uuid, p_order uuid, p_items jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare o orders;
begin
  o := _edit_guard(p_user, p_order, false);
  return _pricing_public(_pricing_for(o.city_id, p_items, p_user));
end $$;

-- Редактирование — новое событие расчёта: заказ пересчитывается по ценам на момент правки
-- (так же, как и ступень). Уже оформленный заказ без правки покупателя никогда не пересчитывается.
create or replace function customer_edit_order(p_user uuid, p_order uuid, p_items jsonb, p_key text) returns jsonb
language plpgsql security definer set search_path=public as $$
declare o orders; pr jsonb; tg bigint; old_items jsonb; new_tot numeric; dup order_edits%rowtype;
        cq int; cr int; d int; rr record;
begin
  select * into dup from order_edits where idempotency_key=p_key;
  if found then return jsonb_build_object('duplicate',true,'id',dup.order_id); end if;
  o := _edit_guard(p_user, p_order, true);
  pr := _pricing_for(o.city_id, p_items, p_user);

  perform 1 from inventory where id in (
    select (x->>'inventory_id')::uuid from jsonb_array_elements(pr->'lines') x
    union select inventory_id from order_items where order_id=p_order) order by id for update;

  for rr in
    select coalesce(n.iid,oq.iid) iid, coalesce(n.q,0)-coalesce(oq.q,0) delta
    from (select (x->>'inventory_id')::uuid iid, (x->>'quantity')::int q from jsonb_array_elements(pr->'lines') x) n
    full join (select inventory_id iid, sum(quantity)::int q from order_items where order_id=p_order group by inventory_id) oq on oq.iid=n.iid
    order by 1
  loop
    d := rr.delta;
    if d=0 then continue; end if;
    select quantity, reserved_quantity into cq, cr from inventory where id=rr.iid;
    if d>0 and (cq-cr) < d then raise exception 'insufficient_stock'; end if;
    if d>0 then
      insert into inventory_transactions(inventory_id,order_id,op,quantity,qty_before,qty_after,city_id,actor,reason)
      values(rr.iid,p_order,'reserve'::inv_op,d,cq,cq,(select city_id from inventory where id=rr.iid),null,'Изменение заказа '||o.number);
    else
      insert into inventory_transactions(inventory_id,order_id,op,quantity,qty_before,qty_after,city_id,actor,reason)
      values(rr.iid,p_order,'release'::inv_op,-d,cq,cq,(select city_id from inventory where id=rr.iid),null,'Изменение заказа '||o.number);
    end if;
    update inventory set reserved_quantity=reserved_quantity+d where id=rr.iid;
  end loop;

  select coalesce(jsonb_agg(jsonb_build_object('inventory_id',inventory_id,'quantity',quantity,'unit_price',unit_price,
           'product_name',product_name,'variant_name',variant_name,'tier_label',tier_label,'price_source',price_source) order by product_name),'[]'::jsonb)
  into old_items from order_items where order_id=p_order;
  select telegram_id into tg from users where id=p_user;

  delete from order_items where order_id=p_order;
  perform _insert_lines(p_order, pr->'lines', pr->>'tier_label');
  new_tot := coalesce((pr->>'total')::numeric,0);
  update orders set total=new_tot, total_units=(pr->>'total_units')::int, tier_label=pr->>'tier_label',
                    approval_required=(pr->>'approval_required')::boolean, has_personal_price=(pr->>'has_personal_price')::boolean,
                    updated_at=now()
  where id=p_order;
  insert into order_edits(order_id,actor,kind,idempotency_key,old_items,new_items,old_total,new_total,old_tier,new_tier,paid_amount)
  values(p_order,tg,'customer_edit',p_key,old_items,
         (select coalesce(jsonb_agg(l - 'unit_cost' - 'below_cost'),'[]'::jsonb) from jsonb_array_elements(pr->'lines') l),
         o.total,new_tot,o.tier_label,pr->>'tier_label',o.paid_amount);

  return jsonb_build_object('id',p_order,'number',o.number,'duplicate',false,'total',new_tot,
    'total_units',(pr->>'total_units')::int,'tier_label',pr->>'tier_label','approval_required',(pr->>'approval_required')::boolean,
    'paid_amount',o.paid_amount,
    'balance', case when o.paid_at is null then null else new_tot-o.paid_amount end);
end $$;

-- Согласование 50+: владелец задаёт цену каждой позиции. Источник цены фиксируется.
create or replace function approve_order_prices(p_order uuid, p_actor bigint, p_prices jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare o orders; x jsonb; new_tot numeric; n_items int; n_distinct int;
begin
  perform _assert_role(p_actor, null);
  select * into o from orders where id=p_order for update;
  if not found then raise exception 'order_not_found'; end if;
  if not o.approval_required then raise exception 'not_approval_order'; end if;
  if o.status not in ('new','confirmed','prepared') then raise exception 'bad_status'; end if;
  if jsonb_typeof(p_prices)<>'array' then raise exception 'bad_prices'; end if;
  select count(*) into n_items from order_items where order_id=p_order;
  select count(distinct (e->>'order_item_id')) into n_distinct from jsonb_array_elements(p_prices) e;
  if n_distinct<>n_items or jsonb_array_length(p_prices)<>n_items then raise exception 'prices_incomplete'; end if;
  for x in select e from jsonb_array_elements(p_prices) e loop
    if (x->>'unit_price') is null or (x->>'unit_price')::numeric<0 then raise exception 'bad_price'; end if;
    update order_items set
        price_source = case when price_source='personal' and unit_price=(x->>'unit_price')::numeric then 'personal' else 'manual' end,
        unit_price=(x->>'unit_price')::numeric
      where id=(x->>'order_item_id')::uuid and order_id=p_order;
    if not found then raise exception 'item_not_found'; end if;
  end loop;
  select coalesce(sum(unit_price*quantity),0) into new_tot from order_items where order_id=p_order;
  update orders set total=new_tot, approval_required=false, updated_at=now(),
         has_personal_price=exists(select 1 from order_items where order_id=p_order and price_source='personal')
   where id=p_order;
  insert into order_edits(order_id,actor,kind,new_items,old_total,new_total,old_tier,new_tier,paid_amount)
  select p_order,p_actor,'approval',coalesce(jsonb_agg(jsonb_build_object('order_item_id',id,'unit_price',unit_price,'quantity',quantity) order by id),'[]'::jsonb),
         o.total,new_tot,o.tier_label,o.tier_label,o.paid_amount
  from order_items where order_id=p_order;
  perform _audit_c(p_actor,'order_approve_prices','order',p_order::text,jsonb_build_object('total',o.total),jsonb_build_object('total',new_tot),o.city_id);
  return jsonb_build_object('id',p_order,'total',new_tot,'approval_required',false);
end $$;

-- ----------------------------------------------------------------- Управление персональными ценами (только владелец)
create or replace function _cp_status(a boolean, vf timestamptz, vu timestamptz) returns text
language sql stable as $$
  select case when not a then 'disabled' when vf > now() then 'scheduled' when vu is not null and vu <= now() then 'expired' else 'active' end
$$;

-- Создание или изменение. Если ничего не изменилось — аудит не пишется (повтор безопасен).
create or replace function customer_price_set(p_actor bigint, p_user uuid, p_product uuid, p_price numeric, p_note text,
                                              p_valid_from timestamptz, p_valid_until timestamptz) returns jsonb
language plpgsql security definer set search_path=public as $$
declare o customer_prices%rowtype; n customer_prices%rowtype; pr products%rowtype; tg bigint; vf timestamptz; created boolean := false;
begin
  perform _assert_role(p_actor, null);
  select telegram_id into tg from users where id=p_user;
  if tg is null then raise exception 'user_not_found'; end if;
  select * into pr from products where id=p_product;
  if not found then raise exception 'item_not_found'; end if;
  if p_price is null or p_price < 0 or p_price > 100000 then raise exception 'bad_price'; end if;
  if length(coalesce(p_note,'')) > 500 then raise exception 'bad_text'; end if;
  perform pg_advisory_xact_lock(hashtext('cprice:'||p_user::text||':'||p_product::text));
  select * into o from customer_prices where user_id=p_user and product_id=p_product for update;
  if not found then
    vf := coalesce(p_valid_from, now());
    if p_valid_until is not null and p_valid_until <= vf then raise exception 'bad_period'; end if;
    insert into customer_prices(user_id,product_id,price,note,valid_from,valid_until,created_by,updated_by)
    values(p_user,p_product,round(p_price,2),coalesce(trim(p_note),''),vf,p_valid_until,p_actor,p_actor) returning * into n;
    created := true;
    perform _audit(p_actor,'customer_price_create','customer_price',p_user::text||':'||p_product::text,null,
      jsonb_build_object('customer_telegram_id',tg,'product',pr.name,'price',n.price,'note',n.note,'valid_until',n.valid_until));
  else
    vf := coalesce(p_valid_from, o.valid_from);
    if p_valid_until is not null and p_valid_until <= vf then raise exception 'bad_period'; end if;
    update customer_prices set price=round(p_price,2), note=coalesce(trim(p_note),''), valid_from=vf, valid_until=p_valid_until,
           updated_by=p_actor, updated_at=now() where id=o.id returning * into n;
    if o.price is distinct from n.price or o.note is distinct from n.note or o.valid_from is distinct from n.valid_from
       or o.valid_until is distinct from n.valid_until then
      perform _audit(p_actor,'customer_price_update','customer_price',p_user::text||':'||p_product::text,
        jsonb_build_object('customer_telegram_id',tg,'product',pr.name,'price',o.price,'note',o.note,'valid_until',o.valid_until),
        jsonb_build_object('customer_telegram_id',tg,'product',pr.name,'price',n.price,'note',n.note,'valid_until',n.valid_until));
    end if;
  end if;
  return jsonb_build_object('id',n.id,'created',created,'price',n.price,'status',_cp_status(n.active,n.valid_from,n.valid_until),
    'below_cost', (pr.cost_price is not null and n.price < pr.cost_price), 'cost_price', pr.cost_price, 'standard_price', pr.price);
end $$;

create or replace function customer_price_set_active(p_actor bigint, p_id bigint, p_active boolean) returns jsonb
language plpgsql security definer set search_path=public as $$
declare o customer_prices%rowtype; pr products%rowtype;
begin
  perform _assert_role(p_actor, null);
  if p_active is null then raise exception 'bad_value'; end if;
  select * into o from customer_prices where id=p_id for update;
  if not found then raise exception 'item_not_found'; end if;
  select * into pr from products where id=o.product_id;
  if o.active is distinct from p_active then
    update customer_prices set active=p_active, updated_by=p_actor, updated_at=now() where id=p_id;
    perform _audit(p_actor,'customer_price_toggle','customer_price',o.user_id::text||':'||o.product_id::text,
      jsonb_build_object('product',pr.name,'active',o.active), jsonb_build_object('product',pr.name,'active',p_active));
  end if;
  return jsonb_build_object('id',p_id,'active',p_active);
end $$;

create or replace function customer_price_delete(p_actor bigint, p_id bigint) returns jsonb
language plpgsql security definer set search_path=public as $$
declare o customer_prices%rowtype; pr products%rowtype; tg bigint;
begin
  perform _assert_role(p_actor, null);
  select * into o from customer_prices where id=p_id for update;
  if not found then raise exception 'item_not_found'; end if;
  select * into pr from products where id=o.product_id;
  select telegram_id into tg from users where id=o.user_id;
  -- Заказы хранят применённую цену сами; personal_price_id в них обнуляется (on delete set null).
  delete from customer_prices where id=p_id;
  perform _audit(p_actor,'customer_price_delete','customer_price',o.user_id::text||':'||o.product_id::text,
    jsonb_build_object('customer_telegram_id',tg,'product',pr.name,'price',o.price,'note',o.note,'valid_until',o.valid_until,'active',o.active), null);
  return jsonb_build_object('id',p_id,'deleted',true);
end $$;

create or replace function customer_prices_list(p_actor bigint, p_user uuid) returns jsonb
language plpgsql stable security definer set search_path=public as $$
begin
  perform _assert_role(p_actor, null);
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id',cp.id,'product_id',cp.product_id,'product_name',pr.name,'price',cp.price,'note',cp.note,
      'valid_from',cp.valid_from,'valid_until',cp.valid_until,'active',cp.active,
      'status',_cp_status(cp.active,cp.valid_from,cp.valid_until),
      'standard_price',pr.price,'cost_price',pr.cost_price,'below_cost',(pr.cost_price is not null and cp.price<pr.cost_price),
      'updated_at',cp.updated_at,'updated_by',cp.updated_by) order by pr.name)
    from customer_prices cp join products pr on pr.id=cp.product_id where cp.user_id=p_user), '[]'::jsonb);
end $$;

-- ----------------------------------------------------------------- Права
select _lockdown_public_tables();
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on all functions in schema public to service_role;

insert into schema_migrations(version) values('0020');
