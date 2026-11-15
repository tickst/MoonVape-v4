-- =============================================================================
-- MoonVape v4 · миграция 0025 · CRM клиентов, единый журнал действий, низкие остатки
-- Запускать ПОСЛЕ 0024. Один Run в SQL Editor. Перед запуском — резервная копия БД.
--
-- CRM — только владелец (персональные цены не должны быть видны администраторам городов).
--   Определения показателей клиента:
--     orders_count  — заказы кроме отменённых;  issued_count — выданные (оплаченные);
--     spent         — Σ (paid_amount − refunded_amount) по выданным;
--     avg_check     — spent / issued_count;     last_order_at — дата последнего неотменённого заказа.
-- Единый журнал (activity_feed) — только чтение: объединяет audit_log, движение склада,
--   статусы заказов, правки заказов, финансовый журнал и движение денег по счетам.
-- =============================================================================

do $$ begin
  if exists(select 1 from schema_migrations where version='0025') then raise exception 'migration 0025 already applied'; end if;
  if not exists(select 1 from schema_migrations where version='0024') then raise exception 'run 0024 first'; end if;
end $$;

create index if not exists orders_user_idx on orders(user_id, created_at desc);

create or replace function crm_customers(p_actor bigint, p_q text, p_city text, p_active_days int, p_sort text, p_limit int, p_offset int)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare q text := nullif(trim(regexp_replace(coalesce(p_q,''), '[%_\\]', '', 'g')), '');
        lim int := least(greatest(coalesce(p_limit,50),1),5000); off int := greatest(coalesce(p_offset,0),0); res jsonb;
begin
  perform _finance_owner(p_actor);
  with base as (
    select u.id, u.telegram_id, u.username, u.first_name, u.last_name, u.city_id, u.created_at,
           count(o.id) filter (where o.status <> 'cancelled') orders_count,
           count(o.id) filter (where o.status = 'issued') issued_count,
           coalesce(sum(o.paid_amount - o.refunded_amount) filter (where o.status = 'issued'), 0) spent,
           max(o.created_at) filter (where o.status <> 'cancelled') last_order_at,
           (select count(*) from customer_prices cp where cp.user_id = u.id and cp.active) personal_prices
    from users u left join orders o on o.user_id = u.id
    where (p_city is null or u.city_id = p_city)
      and (q is null or u.telegram_id::text like q || '%' or coalesce(u.username,'') ilike '%' || q || '%'
           or (coalesce(u.first_name,'') || ' ' || coalesce(u.last_name,'')) ilike '%' || q || '%')
    group by u.id
  ), f as (
    select * from base where p_active_days is null or last_order_at >= now() - make_interval(days => p_active_days)
  ), ranked as (
    select f.*, row_number() over (order by
        case when p_sort = 'spent' then f.spent end desc nulls last,
        case when p_sort = 'orders' then f.orders_count end desc nulls last,
        f.last_order_at desc nulls last, f.created_at desc, f.id) rn
    from f
  )
  select jsonb_build_object(
    'total', (select count(*) from f),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'telegram_id',r.telegram_id,'username',r.username,'first_name',r.first_name,
              'last_name',r.last_name,'city_id',r.city_id,'created_at',r.created_at,'orders_count',r.orders_count,'issued_count',r.issued_count,
              'spent',round(r.spent,2),'avg_check',case when r.issued_count > 0 then round(r.spent / r.issued_count, 2) end,
              'last_order_at',r.last_order_at,'personal_prices',r.personal_prices) order by r.rn)
            from ranked r where r.rn > off and r.rn <= off + lim), '[]'::jsonb))
  into res;
  return res;
end $$;

create or replace function crm_customer(p_actor bigint, p_user uuid) returns jsonb
language plpgsql stable security definer set search_path=public as $$
declare u users%rowtype; st record;
begin
  perform _finance_owner(p_actor);
  select * into u from users where id = p_user;
  if not found then raise exception 'user_not_found'; end if;
  select count(*) filter (where status <> 'cancelled') orders_count, count(*) filter (where status = 'issued') issued_count,
         coalesce(sum(paid_amount - refunded_amount) filter (where status = 'issued'), 0) spent,
         max(created_at) filter (where status <> 'cancelled') last_order_at,
         max(paid_at) filter (where status = 'issued') last_issued_at
    into st from orders where user_id = p_user;
  return jsonb_build_object(
    'id',u.id,'telegram_id',u.telegram_id,'username',u.username,'first_name',u.first_name,'last_name',u.last_name,
    'city_id',u.city_id,'created_at',u.created_at,'bot_started',u.bot_started_at is not null,'marketing_consent',u.marketing_consent_at is not null,
    'orders_count',st.orders_count,'issued_count',st.issued_count,'spent',round(st.spent,2),
    'avg_check',case when st.issued_count > 0 then round(st.spent / st.issued_count, 2) end,
    'last_order_at',st.last_order_at,'last_issued_at',st.last_issued_at,
    'orders', coalesce((select jsonb_agg(jsonb_build_object('id',o.id,'number',o.number,'status',o.status,'city_id',o.city_id,'total',o.total,
              'paid_amount',o.paid_amount,'created_at',o.created_at,'paid_at',o.paid_at,'has_personal_price',o.has_personal_price,
              'items',(select coalesce(sum(quantity),0) from order_items where order_id = o.id)) order by o.created_at desc)
            from (select * from orders where user_id = p_user order by created_at desc limit 100) o), '[]'::jsonb),
    'prices', customer_prices_list(p_actor, p_user));
end $$;

-- Запись событий, которые происходят в backend (экспорт клиентов, неудачные операции). Только из белого списка.
create or replace function audit_event(p_actor bigint, p_action text, p_entity text, p_entity_id text, p_detail jsonb) returns void
language plpgsql security definer set search_path=public as $$
begin
  perform _assert_role(p_actor, null);
  if p_action not in ('customers_export','finance_failed','notify_failed') then raise exception 'bad_action'; end if;
  perform _audit(p_actor, p_action, coalesce(p_entity,'system'), p_entity_id, null, p_detail);
end $$;

-- Позиции, у которых после выдачи заказа свободный остаток упал до порога (настройка low_stock_threshold).
create or replace function low_stock_for_order(p_order uuid) returns jsonb
language sql stable security definer set search_path=public as $$
  select coalesce(jsonb_agg(jsonb_build_object('inventory_id',i.id,'city_id',i.city_id,'product_name',pr.name,'variant_name',v.name,
           'available',i.quantity - i.reserved_quantity,'threshold',_setting_int('low_stock_threshold',2))), '[]'::jsonb)
  from inventory i join products pr on pr.id = i.product_id left join product_variants v on v.id = i.variant_id
  where i.id in (select inventory_id from order_items where order_id = p_order)
    and i.quantity - i.reserved_quantity <= _setting_int('low_stock_threshold',2)
$$;

-- Единый журнал действий. p_source: audit | stock | order | finance | cash | null (все).
create or replace function activity_feed(p_actor bigint, p_date_from date, p_date_to date, p_source text, p_city text, p_limit int default 200)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare wf timestamptz; wt timestamptz; lim int := least(greatest(coalesce(p_limit,200),1),500); res jsonb;
begin
  perform _finance_owner(p_actor);
  select w.win_from, w.win_to into wf, wt from _fin_window(p_date_from, p_date_to) w;
  select coalesce(jsonb_agg(s.x order by s.ts desc, s.k desc), '[]'::jsonb) into res from (
    select ts, k, x from (
      select a.created_at ts, a.id k, jsonb_build_object('ts',a.created_at,'source','audit','actor',a.actor::text,'action',a.action,'entity',a.entity,
             'entity_id',a.entity_id,'city_id',a.city_id,'detail',jsonb_build_object('old',a.old_value,'new',a.new_value)) x
      from audit_log a where (p_source is null or p_source = 'audit') and a.created_at >= wf and a.created_at < wt and (p_city is null or a.city_id = p_city)
      union all
      select t.created_at, t.id, jsonb_build_object('ts',t.created_at,'source','stock','actor',t.actor::text,'action',t.op::text,'entity','inventory',
             'entity_id',t.inventory_id::text,'city_id',t.city_id,'detail',jsonb_build_object('qty',t.quantity,'before',t.qty_before,'after',t.qty_after,'reason',t.reason))
      from inventory_transactions t where (p_source is null or p_source = 'stock') and t.actor is not null
        and t.created_at >= wf and t.created_at < wt and (p_city is null or t.city_id = p_city)
      union all
      select h.created_at, h.id, jsonb_build_object('ts',h.created_at,'source','order','actor',h.actor,'action','status_'||h.new_status::text,'entity','order',
             'entity_id',h.order_id::text,'city_id',o.city_id,'detail',jsonb_build_object('from',h.old_status,'to',h.new_status,'number',o.number))
      from order_status_history h join orders o on o.id = h.order_id
      where (p_source is null or p_source = 'order') and h.created_at >= wf and h.created_at < wt and (p_city is null or o.city_id = p_city)
      union all
      select e.created_at, e.id, jsonb_build_object('ts',e.created_at,'source','order','actor',e.actor::text,'action','edit_'||e.kind,'entity','order',
             'entity_id',e.order_id::text,'city_id',o.city_id,'detail',jsonb_build_object('old_total',e.old_total,'new_total',e.new_total,'number',o.number))
      from order_edits e join orders o on o.id = e.order_id
      where (p_source is null or p_source = 'order') and e.created_at >= wf and e.created_at < wt and (p_city is null or o.city_id = p_city)
      union all
      select f.occurred_at, f.id, jsonb_build_object('ts',f.occurred_at,'source','finance','actor',f.actor::text,
             'action',case when f.reverses_id is null then f.op_type else f.op_type||'_reversal' end,'entity','finance_entry','entity_id',f.id::text,
             'city_id',f.city_id,'detail',jsonb_build_object('amount',f.amount,'category',f.category,'description',f.description,'reason',f.reason))
      from finance_entries f where (p_source is null or p_source = 'finance') and f.occurred_at >= wf and f.occurred_at < wt and (p_city is null or f.city_id = p_city)
      union all
      select c.occurred_at, c.id, jsonb_build_object('ts',c.occurred_at,'source','cash','actor',c.actor::text,
             'action',case when c.reverses_id is null then c.kind else c.kind||'_reversal' end,'entity','cash_account','entity_id',c.account_id::text,
             'city_id',ca.city_id,'detail',jsonb_build_object('amount',c.amount,'account',ca.name,'reason',c.reason))
      from cash_entries c join cash_accounts ca on ca.id = c.account_id
      where (p_source is null or p_source = 'cash') and c.occurred_at >= wf and c.occurred_at < wt and (p_city is null or ca.city_id = p_city)
    ) u order by ts desc, k desc limit lim) s;
  return res;
end $$;

select _lockdown_public_tables();
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on all functions in schema public to service_role;

insert into schema_migrations(version) values('0025');
