-- =============================================================================
-- MoonVape v4 · миграция 0019 · безопасность, аудит, настройки, очередь уведомлений
-- Запускать ПОСЛЕ 0018. Один Run в SQL Editor. Перед запуском — резервная копия БД.
-- Ничего не удаляет. Исторические данные не меняются.
--
-- Что делает:
--   1. Закрывает анонимный доступ к products.cost_price (себестоимость читалась ключом anon).
--   2. Отзывает у anon/authenticated права на все таблицы, кроме публичного каталога.
--   3. audit_log: колонка city_id, индексы, защита от изменения и удаления записей.
--   4. app_settings: серверные настройки (рассылки выключены по умолчанию).
--   5. outbox: ключ дедупликации (повторная задача не отправит то же сообщение дважды),
--      новые виды сообщений (low_stock, system_alert).
--   6. Рассылки: выключены по умолчанию; получатели — только с явным согласием (opt-in).
--      Журнал рассылок и статистика доставки.
--   7. Изменение товаров, вариантов и категорий — через RPC с аудитом (раньше шло прямым PATCH).
--   8. Отметка проверки возраста при выдаче заказа (включается настройкой).
--
-- СТАТУС: не запускалась в среде разработки (нет PostgreSQL). См. docs/REPORT_v4.md.
-- =============================================================================

do $$ begin
  if exists(select 1 from schema_migrations where version='0019') then raise exception 'migration 0019 already applied'; end if;
  if not exists(select 1 from schema_migrations where version='0018') then raise exception 'run 0018 first'; end if;
end $$;

-- ----------------------------------------------------------------- 1–2. Привилегии
-- Любой, у кого есть публичный anon-ключ (он лежит во фронтенде), мог читать products.cost_price:
-- политика pub_read отдаёт все колонки активных строк. Приложение само в БД через anon не ходит,
-- поэтому оставляем только то, что нужно публичному каталогу.
create or replace function _lockdown_public_tables() returns void language plpgsql set search_path=public as $$
declare t record;
begin
  for t in select tablename from pg_tables where schemaname='public' loop
    execute format('revoke all on table public.%I from anon, authenticated', t.tablename);
  end loop;
  revoke all on all sequences in schema public from anon, authenticated;
  grant select on categories, product_variants, product_flavors, wholesale_prices, cities to anon, authenticated;
  -- products: без cost_price и служебных колонок
  grant select (id, category_id, name, description, price, image_path, wholesale_enabled, active, created_at, catalog_key)
    on products to anon, authenticated;
end $$;
select _lockdown_public_tables();

-- ----------------------------------------------------------------- 3. Журнал аудита
alter table audit_log add column if not exists city_id text;
create index if not exists audit_log_created_idx on audit_log(created_at desc);
create index if not exists audit_log_entity_idx on audit_log(entity, entity_id, created_at desc);

create or replace function _audit_guard() returns trigger language plpgsql set search_path=public as $$
begin raise exception 'audit_immutable'; end $$;
drop trigger if exists trg_audit_guard on audit_log;
create trigger trg_audit_guard before update or delete on audit_log for each row execute function _audit_guard();

-- Запись аудита с городом. Старый _audit (6 аргументов) остаётся.
create or replace function _audit_c(p_actor bigint, p_action text, p_entity text, p_entity_id text, p_old jsonb, p_new jsonb, p_city text)
returns void language sql set search_path=public as $$
  insert into audit_log(actor,action,entity,entity_id,old_value,new_value,city_id)
  values(coalesce(p_actor,0),p_action,p_entity,p_entity_id,p_old,p_new,p_city)
$$;

-- ----------------------------------------------------------------- 4. Настройки
create table if not exists app_settings(
  key text primary key,
  value jsonb not null,
  updated_by bigint,
  updated_at timestamptz not null default now()
);
alter table app_settings enable row level security;
-- broadcasts_enabled=false: рассылки по наличию заблокированы на уровне БД, пока владелец
--   (после юридической проверки) не включит их в «Настройки».
-- require_age_check_on_issue=false: если true — выдать заказ можно только после отметки
--   «возраст проверен по документу» (order_mark_age_checked).
insert into app_settings(key,value) values
  ('broadcasts_enabled','false'::jsonb),
  ('low_stock_threshold','2'::jsonb),
  ('require_age_check_on_issue','false'::jsonb)
on conflict (key) do nothing;

create or replace function _setting_bool(p_key text) returns boolean language sql stable set search_path=public as $$
  select coalesce((select value = 'true'::jsonb from app_settings where key=p_key), false)
$$;
create or replace function _setting_int(p_key text, p_default int) returns int language sql stable set search_path=public as $$
  select coalesce((select (value #>> '{}')::int from app_settings where key=p_key), p_default)
$$;

create or replace function admin_settings_get(p_actor bigint) returns jsonb
language plpgsql stable security definer set search_path=public as $$
begin
  perform _assert_role(p_actor, null);
  return coalesce((select jsonb_object_agg(key, value) from app_settings), '{}'::jsonb);
end $$;

create or replace function admin_set_setting(p_actor bigint, p_key text, p_value jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare old_v jsonb;
begin
  perform _assert_role(p_actor, null);
  if p_key in ('broadcasts_enabled','require_age_check_on_issue') then
    if jsonb_typeof(p_value) <> 'boolean' then raise exception 'bad_value'; end if;
  elsif p_key = 'low_stock_threshold' then
    if jsonb_typeof(p_value) <> 'number' or (p_value #>> '{}')::numeric not between 0 and 50
       or (p_value #>> '{}')::numeric <> trunc((p_value #>> '{}')::numeric) then raise exception 'bad_value'; end if;
  else raise exception 'bad_setting'; end if;
  select value into old_v from app_settings where key=p_key for update;
  insert into app_settings(key,value,updated_by,updated_at) values(p_key,p_value,p_actor,now())
  on conflict (key) do update set value=excluded.value, updated_by=excluded.updated_by, updated_at=now();
  if old_v is distinct from p_value then
    perform _audit(p_actor,'setting_change','setting',p_key,to_jsonb(old_v),p_value);
  end if;
  return jsonb_build_object('key',p_key,'value',p_value);
end $$;

-- ----------------------------------------------------------------- 5. Очередь уведомлений
alter table outbox add column if not exists dedupe_key text;
do $$ begin
  if not exists(select 1 from pg_constraint where conrelid='public.outbox'::regclass and conname='outbox_dedupe_uq') then
    alter table outbox add constraint outbox_dedupe_uq unique (dedupe_key);   -- NULL-ключи не конфликтуют
  end if;
end $$;
do $$ declare c record; begin
  for c in select conname from pg_constraint
           where conrelid='public.outbox'::regclass and contype='c' and pg_get_constraintdef(oid) like '%order_admin%' loop
    execute format('alter table outbox drop constraint %I', c.conname);
  end loop;
end $$;
alter table outbox add constraint outbox_kind_check
  check (kind in ('order_admin','order_customer','broadcast','low_stock','system_alert'));
create index if not exists outbox_created_idx on outbox(created_at desc);

-- ----------------------------------------------------------------- 6. Рассылки
-- Явное согласие на оповещения о наличии. Пока NULL — рассылка пользователю не уходит.
-- notify_stock по умолчанию true и согласием не считается: пользователь его никогда не давал.
alter table users add column if not exists marketing_consent_at timestamptz;

create or replace function create_broadcast(p_actor bigint, p_city text, p_text text, p_product_ids uuid[], p_key text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare b broadcasts%rowtype; n int;
begin
  perform _assert_role(p_actor, p_city);
  select * into b from broadcasts where idempotency_key=p_key;
  if found then return jsonb_build_object('id',b.id,'recipients',b.recipients,'duplicate',true); end if;
  if not _setting_bool('broadcasts_enabled') then raise exception 'broadcasts_disabled'; end if;
  if nullif(trim(coalesce(p_text,'')),'') is null then raise exception 'empty_text'; end if;
  perform pg_advisory_xact_lock(hashtext('broadcast:'||p_city));
  if exists(select 1 from broadcasts where city_id=p_city and created_at > now()-interval '10 minutes') then
    raise exception 'broadcast_cooldown';
  end if;
  insert into broadcasts(city_id,text,product_ids,created_by,idempotency_key)
  values(p_city,p_text,coalesce(p_product_ids,'{}'),p_actor,p_key) returning * into b;
  insert into outbox(chat_id,kind,text,broadcast_id,dedupe_key)
  select u.telegram_id,'broadcast',p_text,b.id,'broadcast:'||b.id||':'||u.telegram_id from users u
  where u.city_id=p_city and u.bot_started_at is not null and u.notify_stock and not u.bot_blocked
    and u.marketing_consent_at is not null;
  get diagnostics n = row_count;
  update broadcasts set recipients=n where id=b.id;
  perform _audit_c(p_actor,'broadcast_create','broadcast',b.id::text,null,jsonb_build_object('recipients',n,'city',p_city),p_city);
  return jsonb_build_object('id',b.id,'recipients',n,'duplicate',false);
end $$;

-- Журнал рассылок со статистикой доставки (p_city = null → все города, только владелец).
create or replace function broadcast_list(p_actor bigint, p_city text, p_limit int default 50) returns jsonb
language plpgsql stable security definer set search_path=public as $$
begin
  perform _assert_role(p_actor, p_city);
  return coalesce((select jsonb_agg(x order by x->>'created_at' desc) from (
    select jsonb_build_object('id',b.id,'city_id',b.city_id,'created_at',b.created_at,'created_by',b.created_by,
             'recipients',b.recipients,'preview',left(b.text,160),
             'sent',count(o.id) filter (where o.status='sent'),
             'failed',count(o.id) filter (where o.status='failed'),
             'pending',count(o.id) filter (where o.status='pending')) x
    from broadcasts b left join outbox o on o.broadcast_id=b.id
    where p_city is null or b.city_id=p_city
    group by b.id order by b.created_at desc limit least(greatest(coalesce(p_limit,50),1),200)) s), '[]'::jsonb);
end $$;

-- Состояние очереди и последние ошибки отправки (только владелец).
create or replace function outbox_stats(p_actor bigint, p_days int default 7) returns jsonb
language plpgsql stable security definer set search_path=public as $$
declare since timestamptz := now() - make_interval(days => least(greatest(coalesce(p_days,7),1),90));
begin
  perform _assert_role(p_actor, null);
  return jsonb_build_object(
    'since', since,
    'by_kind', coalesce((select jsonb_agg(jsonb_build_object('kind',kind,'status',status,'n',n) order by kind,status) from (
        select kind,status,count(*) n from outbox where created_at>=since group by kind,status) s),'[]'::jsonb),
    'overdue_pending', (select count(*) from outbox where status='pending' and next_attempt_at < now() - interval '10 minutes'),
    'failed_recent', coalesce((select jsonb_agg(jsonb_build_object('id',id,'kind',kind,'attempts',attempts,'last_error',last_error,'created_at',created_at) order by id desc) from (
        select * from outbox where status='failed' and created_at>=since order by id desc limit 50) f),'[]'::jsonb));
end $$;

-- ----------------------------------------------------------------- 7. Изменения каталога с аудитом
create or replace function admin_update_product_fields(p_actor bigint, p_product uuid, p_patch jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare o products%rowtype; n products%rowtype; old_j jsonb; new_j jsonb;
begin
  perform _assert_role(p_actor, null);
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then raise exception 'bad_patch'; end if;
  select * into o from products where id=p_product for update;
  if not found then raise exception 'item_not_found'; end if;
  if p_patch ? 'name' and nullif(trim(coalesce(p_patch->>'name','')),'') is null then raise exception 'bad_name'; end if;
  if p_patch ? 'category_id' and not exists(select 1 from categories where id=(p_patch->>'category_id')::int) then raise exception 'bad_category'; end if;
  update products set
    name        = case when p_patch ? 'name' then trim(p_patch->>'name') else name end,
    description = case when p_patch ? 'description' then coalesce(p_patch->>'description','') else description end,
    category_id = case when p_patch ? 'category_id' then (p_patch->>'category_id')::int else category_id end,
    active      = case when p_patch ? 'active' then (p_patch->>'active')::boolean else active end,
    image_path  = case when p_patch ? 'image_path' then nullif(p_patch->>'image_path','') else image_path end
  where id=p_product returning * into n;
  old_j := jsonb_build_object('name',o.name,'description',o.description,'category_id',o.category_id,'active',o.active,'image_path',o.image_path);
  new_j := jsonb_build_object('name',n.name,'description',n.description,'category_id',n.category_id,'active',n.active,'image_path',n.image_path);
  if old_j is distinct from new_j then perform _audit(p_actor,'product_update','product',p_product::text,old_j,new_j); end if;
  return new_j || jsonb_build_object('id',n.id);
end $$;

create or replace function admin_update_variant_fields(p_actor bigint, p_variant uuid, p_patch jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare o product_variants%rowtype; n product_variants%rowtype; new_price numeric;
begin
  perform _assert_role(p_actor, null);
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then raise exception 'bad_patch'; end if;
  select * into o from product_variants where id=p_variant for update;
  if not found then raise exception 'item_not_found'; end if;
  if p_patch ? 'name' and nullif(trim(coalesce(p_patch->>'name','')),'') is null then raise exception 'bad_name'; end if;
  if p_patch ? 'price' then
    new_price := nullif(p_patch->>'price','')::numeric;
    if new_price is not null and (new_price < 0 or new_price > 100000) then raise exception 'bad_price'; end if;
  end if;
  update product_variants set
    name  = case when p_patch ? 'name' then trim(p_patch->>'name') else name end,
    price = case when p_patch ? 'price' then new_price else price end
  where id=p_variant returning * into n;
  if o.price is distinct from n.price then
    perform _audit(p_actor,'variant_price','variant',p_variant::text,jsonb_build_object('price',o.price),jsonb_build_object('price',n.price));
  end if;
  if o.name is distinct from n.name then
    perform _audit(p_actor,'variant_rename','variant',p_variant::text,jsonb_build_object('name',o.name),jsonb_build_object('name',n.name));
  end if;
  return jsonb_build_object('id',n.id,'name',n.name,'price',n.price);
end $$;

create or replace function admin_category_save(p_actor bigint, p_id int, p_name text, p_sort int) returns jsonb
language plpgsql security definer set search_path=public as $$
declare o categories%rowtype; n categories%rowtype;
begin
  perform _assert_role(p_actor, null);
  if p_id is null then
    if nullif(trim(coalesce(p_name,'')),'') is null then raise exception 'bad_name'; end if;
    insert into categories(name,sort) values(trim(p_name),coalesce(p_sort,0)) returning * into n;
    perform _audit(p_actor,'category_create','category',n.id::text,null,jsonb_build_object('name',n.name,'sort',n.sort));
  else
    select * into o from categories where id=p_id for update;
    if not found then raise exception 'item_not_found'; end if;
    if p_name is not null and nullif(trim(p_name),'') is null then raise exception 'bad_name'; end if;
    update categories set name=coalesce(nullif(trim(p_name),''),name), sort=coalesce(p_sort,sort) where id=p_id returning * into n;
    if o.name is distinct from n.name or o.sort is distinct from n.sort then
      perform _audit(p_actor,'category_update','category',p_id::text,jsonb_build_object('name',o.name,'sort',o.sort),jsonb_build_object('name',n.name,'sort',n.sort));
    end if;
  end if;
  return jsonb_build_object('id',n.id,'name',n.name,'sort',n.sort);
end $$;

-- ----------------------------------------------------------------- 8. Проверка возраста при выдаче
alter table orders add column if not exists age_verified_at timestamptz;
alter table orders add column if not exists age_verified_by bigint;

create or replace function order_mark_age_checked(p_actor bigint, p_order uuid) returns jsonb
language plpgsql security definer set search_path=public as $$
declare o orders;
begin
  select * into o from orders where id=p_order for update;
  if not found then raise exception 'order_not_found'; end if;
  perform _assert_role(p_actor, o.city_id);
  if o.status not in ('new','prepared') then raise exception 'bad_status'; end if;
  if o.age_verified_at is not null then return jsonb_build_object('id',p_order,'duplicate',true); end if;
  update orders set age_verified_at=now(), age_verified_by=p_actor, updated_at=now() where id=p_order;
  perform _audit_c(p_actor,'order_age_checked','order',p_order::text,null,jsonb_build_object('number',o.number),o.city_id);
  return jsonb_build_object('id',p_order,'duplicate',false);
end $$;

-- ----------------------------------------------------------------- Права: только backend (service_role)
select _lockdown_public_tables();
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on all functions in schema public to service_role;

insert into schema_migrations(version) values('0019');
