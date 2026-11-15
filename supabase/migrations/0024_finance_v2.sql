-- =============================================================================
-- MoonVape v4 · миграция 0024 · финансовая аналитика v2
-- Запускать ПОСЛЕ 0023. Один Run в SQL Editor. Перед запуском — резервная копия БД.
--
-- Изменения отчётов (определения выручки не меняются):
--   * Себестоимость строки = FIFO (order_items.cogs_total), для старых заказов — снимок unit_cost × qty.
--   * Разбивка по городам (by_city): выручка, себестоимость, валовая и чистая прибыль, маржа, режим города.
--     Расходы «по всей сети» (city_id = NULL) показываются отдельной строкой unallocated_expenses.
--   * Взаиморасчёты учитывают режим города (owner_operated → долга нет).
--   * Остатки по себестоимости — из партий (+ товар «в пути»), не из текущей cost_price.
--   * Состояние денежных счетов (балансы) — отдельным блоком; переводы между счетами в прибыль не входят.
--   * Прибыльность товаров: остаток на складе и его стоимость; товары без продаж и с низкой маржой
--     определяются на клиенте по этим данным.
-- Возвраты: после 0005 возвратов выданных заказов в системе нет; отмена оплаченного заказа
--   (refunded_amount) в выручку не попадает, т. к. выручка считается только по status='issued'.
-- =============================================================================

do $$ begin
  if exists(select 1 from schema_migrations where version='0024') then raise exception 'migration 0024 already applied'; end if;
  if not exists(select 1 from schema_migrations where version='0023') then raise exception 'run 0023 first'; end if;
end $$;

create or replace function _fin_metrics(p_city text, p_from timestamptz, p_to timestamptz, p_category int, p_product uuid)
returns jsonb language sql stable set search_path=public as $$
with lines as (
  select o.id order_id, oi.quantity qty, oi.unit_price*oi.quantity rev,
         coalesce(oi.cogs_total, coalesce(oi.unit_cost,0)*oi.quantity) cost,
         case when oi.cogs_total is not null then oi.cogs_incomplete else (oi.unit_cost is null) end miss
  from order_items oi
  join orders o on o.id = oi.order_id
  join products pr on pr.id = oi.product_id
  where o.status = 'issued' and o.paid_at >= p_from and o.paid_at < p_to
    and (p_city is null or o.city_id = p_city)
    and (p_category is null or pr.category_id = p_category)
    and (p_product is null or oi.product_id = p_product)
),
agg as (
  select coalesce(sum(rev),0) revenue, coalesce(sum(cost),0) cogs, count(*) filter (where miss) miss_lines,
         coalesce(sum(qty),0) units, count(distinct order_id) orders
  from lines
),
ex as (
  select coalesce(sum(case when reverses_id is null then amount else -amount end),0) expenses
  from finance_entries
  where op_type = 'expense' and occurred_at >= p_from and occurred_at < p_to and (p_city is null or city_id = p_city)
)
select jsonb_build_object(
  'revenue',      round(agg.revenue,2),
  'orders',       agg.orders,
  'units',        agg.units,
  'avg_check',    case when agg.orders > 0 then round(agg.revenue / agg.orders, 2) end,
  'cogs',         round(agg.cogs,2),
  'cogs_missing_lines', agg.miss_lines,
  'gross_profit', round(agg.revenue - agg.cogs, 2),
  'margin_pct',   case when agg.revenue > 0 then round((agg.revenue - agg.cogs) / agg.revenue * 100, 1) end,
  'expenses',     case when p_category is null and p_product is null then round(ex.expenses,2) end,
  'net_profit',   case when p_category is null and p_product is null then round(agg.revenue - agg.cogs - ex.expenses,2) end
)
from agg, ex
$$;

create or replace function finance_summary(p_actor bigint, p_city text, p_date_from date, p_date_to date,
                                           p_category int default null, p_product uuid default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare wf timestamptz; wt timestamptz; pf timestamptz; series jsonb; settle jsonb; unpaid jsonb; stock numeric; stock_unknown int;
        cash jsonb; by_city jsonb; accounts jsonb; transit jsonb; unalloc numeric;
        filtered boolean := (p_category is not null or p_product is not null);
begin
  perform _finance_owner(p_actor);
  if p_city is not null and not exists(select 1 from cities where id=p_city) then raise exception 'bad_city'; end if;
  select w.win_from, w.win_to into wf, wt from _fin_window(p_date_from, p_date_to) w;
  pf := wf - (wt - wf);

  select coalesce(jsonb_agg(jsonb_build_object('day', to_char(s.sales_day,'YYYY-MM-DD'), 'revenue', s.revenue,
         'gross_profit', s.gp, 'orders', s.n) order by s.sales_day), '[]'::jsonb)
into series
from (
  select (o.paid_at at time zone 'Europe/Berlin')::date AS sales_day,
           round(sum(oi.unit_price*oi.quantity),2) revenue,
           round(sum(oi.unit_price*oi.quantity - coalesce(oi.cogs_total, coalesce(oi.unit_cost,0)*oi.quantity)),2) gp,
           count(distinct o.id) n
    from order_items oi
    join orders o on o.id = oi.order_id
    join products pr on pr.id = oi.product_id
    where o.status='issued' and o.paid_at >= wf and o.paid_at < wt
      and (p_city is null or o.city_id = p_city)
      and (p_category is null or pr.category_id = p_category)
      and (p_product is null or oi.product_id = p_product)
    group by 1
  ) s;

  -- Взаиморасчёты: режим города определяет, есть ли задолженность (текущий остаток, не за период).
  select coalesce(jsonb_agg(jsonb_build_object('city_id', c.id, 'city', c.name, 'mode', x.s->>'mode',
           'transfer_required', (x.s->>'transfer_required')::boolean, 'message', x.s->>'message',
           'collected', x.s->>'collected', 'transferred', x.s->>'transferred', 'owed', x.s->>'owed',
           'cash_balance', x.s->>'cash_balance') order by c.sort), '[]'::jsonb)
  into settle
  from cities c cross join lateral (select _settlement(c.id) s) x
  where c.active and (p_city is null or c.id = p_city);

  select jsonb_build_object('orders', count(*), 'amount', round(coalesce(sum(o.total),0),2)) into unpaid
  from orders o
  where o.status in ('new','prepared') and o.paid_at is null and (p_city is null or o.city_id = p_city);

  -- Остатки по себестоимости: из партий.
  select coalesce(sum(b.qty_remaining * coalesce(b.unit_cost,0)),0), coalesce(sum(b.qty_remaining) filter (where b.unit_cost is null),0)::int
  into stock, stock_unknown
  from stock_batches b join products pr on pr.id = b.product_id
  where b.qty_remaining > 0 and (p_city is null or b.city_id = p_city)
    and (p_category is null or pr.category_id = p_category) and (p_product is null or pr.id = p_product);

  if p_city is null and not filtered then
    select jsonb_build_object('units', coalesce(sum(l.quantity),0), 'value', round(coalesce(sum(l.quantity*coalesce(l.unit_cost,0)),0),2)) into transit
    from stock_transfer_layers l join stock_transfer_items i on i.id=l.item_id join stock_transfers t on t.id=i.transfer_id where t.status='in_transit';
  else transit := null; end if;

  if filtered then cash := null; by_city := null; accounts := null; unalloc := null;
  else
    select jsonb_build_object(
      'cash_in',  round(coalesce(sum(case when reverses_id is null then amount else -amount end) filter (where op_type='cash_in'),0),2),
      'cash_out', round(coalesce(sum(case when reverses_id is null then amount else -amount end) filter (where op_type='cash_out'),0),2))
    into cash
    from finance_entries
    where occurred_at >= wf and occurred_at < wt and (p_city is null or city_id = p_city);

    select coalesce(jsonb_agg(jsonb_build_object('city_id', c.id, 'city', c.name, 'mode', c.finance_mode,
             'metrics', _fin_metrics(c.id, wf, wt, null, null)) order by c.sort), '[]'::jsonb)
    into by_city from cities c where c.active and (p_city is null or c.id = p_city);

    select coalesce(sum(case when reverses_id is null then amount else -amount end),0) into unalloc
    from finance_entries where op_type='expense' and city_id is null and occurred_at >= wf and occurred_at < wt;
    if p_city is not null then unalloc := null; end if;

    select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'name',a.name,'kind',a.kind,'city_id',a.city_id,'balance',_account_balance(a.id),
             'closed',a.closed_at is not null) order by (a.closed_at is not null), a.kind, a.id), '[]'::jsonb)
    into accounts from cash_accounts a where a.active and (p_city is null or a.city_id = p_city or a.city_id is null);
  end if;

  return jsonb_build_object(
    'period',   jsonb_build_object('from', wf, 'to', wt, 'days', (p_date_to - p_date_from) + 1),
    'previous', jsonb_build_object('from', pf, 'to', wf),
    'current',  _fin_metrics(p_city, wf, wt, p_category, p_product),
    'previous_metrics', _fin_metrics(p_city, pf, wf, p_category, p_product),
    'series',   series,
    'by_city',  by_city,
    'unallocated_expenses', case when unalloc is null then null else round(unalloc,2) end,
    'settlement', settle,
    'unpaid_open', unpaid,
    'stock_cost', round(stock,2),
    'stock_unknown_cost_units', stock_unknown,
    'in_transit', transit,
    'accounts', accounts,
    'cash',     cash,
    'filtered', filtered
  );
end $$;

create or replace function finance_products(p_actor bigint, p_city text, p_date_from date, p_date_to date, p_category int default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare wf timestamptz; wt timestamptz; res jsonb;
begin
  perform _finance_owner(p_actor);
  if p_city is not null and not exists(select 1 from cities where id=p_city) then raise exception 'bad_city'; end if;
  select w.win_from, w.win_to into wf, wt from _fin_window(p_date_from, p_date_to) w;
  select coalesce(jsonb_agg(to_jsonb(r) order by r.revenue desc, r.name), '[]'::jsonb) into res
  from (
    select pr.id product_id, pr.name, pr.category_id, pr.active,
           coalesce(s.units,0) units, coalesce(s.orders,0) orders,
           round(coalesce(s.revenue,0),2) revenue,
           round(coalesce(s.cogs,0),2) cogs,
           round(coalesce(s.revenue,0) - coalesce(s.cogs,0),2) gross_profit,
           case when coalesce(s.revenue,0) > 0 then round((s.revenue - s.cogs) / s.revenue * 100, 1) end margin_pct,
           coalesce(s.missing,0) cogs_missing_lines,
           coalesce(st.units,0) stock_units, round(coalesce(st.value,0),2) stock_value
    from products pr
    left join (
      select oi.product_id, sum(oi.quantity) units, count(distinct o.id) orders,
             sum(oi.unit_price*oi.quantity) revenue, sum(coalesce(oi.cogs_total, coalesce(oi.unit_cost,0)*oi.quantity)) cogs,
             count(*) filter (where case when oi.cogs_total is not null then oi.cogs_incomplete else oi.unit_cost is null end) missing
      from order_items oi join orders o on o.id = oi.order_id
      where o.status='issued' and o.paid_at >= wf and o.paid_at < wt and (p_city is null or o.city_id = p_city)
      group by oi.product_id
    ) s on s.product_id = pr.id
    left join (
      select product_id, sum(qty_remaining)::int units, sum(qty_remaining*coalesce(unit_cost,0)) value
      from stock_batches where qty_remaining > 0 and (p_city is null or city_id = p_city) group by product_id
    ) st on st.product_id = pr.id
    where (pr.active or s.product_id is not null)
      and (p_category is null or pr.category_id = p_category)
  ) r;
  return res;
end $$;

create or replace function finance_entries_list(p_actor bigint, p_city text, p_date_from date, p_date_to date, p_limit int default 200)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare wf timestamptz; wt timestamptz; res jsonb;
begin
  perform _finance_owner(p_actor);
  select w.win_from, w.win_to into wf, wt from _fin_window(p_date_from, p_date_to) w;
  select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'op_type',e.op_type,'amount',e.amount,'occurred_at',e.occurred_at,
           'city_id',e.city_id,'category',e.category,'description',e.description,'reason',e.reason,'status',e.status,
           'reverses_id',e.reverses_id,'actor',e.actor,'account_id',e.account_id,'account',a.name) order by e.occurred_at desc, e.id desc), '[]'::jsonb)
  into res
  from (select * from finance_entries
        where occurred_at >= wf and occurred_at < wt and (p_city is null or city_id = p_city)
        order by occurred_at desc, id desc
        limit least(greatest(coalesce(p_limit,200),1),500)) e
  left join cash_accounts a on a.id = e.account_id;
  return res;
end $$;

select _lockdown_public_tables();
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on all functions in schema public to service_role;

insert into schema_migrations(version) values('0024');
