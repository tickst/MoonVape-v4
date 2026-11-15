-- =============================================================================
-- MoonVape v4 · автотесты миграций 0019–0025
-- Запускать ТОЛЬКО на ТЕСТОВОЙ базе, после применения 0019–0025. Всё откатывается (rollback в конце).
-- Фикстуры создаются тестом (своя категория, товары, клиенты, администраторы) — каталог не нужен.
-- В конце должно появиться сообщение: ALL V6 TESTS PASSED.
-- Любая упавшая проверка прерывает тест с понятным текстом; ничего не сохраняется.
--
-- СТАТУС: ЭТОТ ФАЙЛ НЕ ЗАПУСКАЛСЯ. В среде разработки нет PostgreSQL, поэтому SQL-тесты и сами миграции
-- ни разу не выполнялись. Первый запуск на тестовой базе — обязательный шаг перед продакшеном (docs/DEPLOY_v4.md).
--
-- Что покрыто (номера = разделы ниже):
--  1 фикстуры · 2 закупки и стоимость партий · 3 персональные цены · 4 FIFO, отмена, двойная выдача
--  5 перемещения и стоимость запасов · 6 München/Hannover и взаиморасчёты · 7 счета, сторно, неизменяемость
--  8 безопасность, рассылки, аудит, проверка возраста · 9 смена режима города
-- Параллельность проверяется вручную в двух сессиях — см. docs/TESTING_v4.md (раздел «Параллельность»).
-- =============================================================================

begin;

create function pg_temp.fails(q text, pat text default null) returns boolean language plpgsql as $$
begin execute q; return false;
exception when others then return pat is null or sqlerrm like '%' || pat || '%';
end $$;

do $$
declare
  owner bigint := 990000001; hadm bigint := 990000002;
  today date := (now() at time zone 'Europe/Berlin')::date;
  cat int; px uuid; py uuid; ixh uuid; ixm uuid; iyh uuid;
  uA uuid; uB uuid; uC uuid;
  bank bigint; hcash bigint; mcash bigint;
  r jsonb; pv jsonb; s0 jsonb; s1 jsonb; s2 jsonb;
  pid1 bigint; pid2 bigint; pid3 bigint; tid bigint; tid2 bigint;
  oA uuid; oB uuid; oC uuid; oM uuid; oH uuid; oAge uuid;
  b0 numeric; b1 numeric; h0 numeric; h1 numeric; v0 numeric; v1 numeric; m0 numeric; d0 numeric;
  n1 int; n2 int; ent bigint; tuid uuid; bid bigint; cnt int;
  items jsonb;
begin
  -- ================================================================= 1. Фикстуры
  insert into admins(telegram_id, role) values (owner, 'owner')
    on conflict (telegram_id) do update set role = 'owner', city_id = null, is_active = true;
  insert into admins(telegram_id, role, city_id) values (hadm, 'city_admin', 'hannover')
    on conflict (telegram_id) do update set role = 'city_admin', city_id = 'hannover', is_active = true;

  insert into categories(name, sort) values ('T6 ' || gen_random_uuid()::text, 99) returning id into cat;
  insert into products(category_id, name, price, cost_price, wholesale_enabled) values (cat, 'T6 X', 10, 6, true) returning id into px;
  insert into products(category_id, name, price, cost_price, wholesale_enabled) values (cat, 'T6 Y', 20, 12, true) returning id into py;
  insert into wholesale_tiers(product_id, tier_min, tier_max, price) values (px, 3, 4, 8), (px, 9, 20, 7.5), (py, 3, 4, 17);
  insert into inventory(product_id, variant_id, flavor_id, city_id, quantity, reserved_quantity) values (px, null, null, 'hannover', 0, 0) returning id into ixh;
  insert into inventory(product_id, variant_id, flavor_id, city_id, quantity, reserved_quantity) values (px, null, null, 'muenchen', 0, 0) returning id into ixm;
  insert into inventory(product_id, variant_id, flavor_id, city_id, quantity, reserved_quantity) values (py, null, null, 'hannover', 0, 0) returning id into iyh;
  insert into users(telegram_id, first_name, city_id) values (990000011, 'T6 A', 'hannover') returning id into uA;
  insert into users(telegram_id, first_name, city_id) values (990000012, 'T6 B', 'hannover') returning id into uB;
  insert into users(telegram_id, first_name, city_id, bot_started_at, notify_stock, bot_blocked, marketing_consent_at)
    values (990000013, 'T6 C', 'hannover', now(), true, false, now()) returning id into uC;

  select id into bank from cash_accounts where kind = 'owner_bank' and active order by id limit 1;
  select id into hcash from cash_accounts where kind = 'city_cash' and city_id = 'hannover' and closed_at is null;
  select id into mcash from cash_accounts where kind = 'city_cash' and city_id = 'muenchen' and closed_at is null;
  assert bank is not null and hcash is not null and mcash is not null, 'accounts from migration 0021 must exist';
  assert (select finance_mode from cities where id = 'muenchen') = 'owner_operated', 'München must be owner_operated';
  assert (select finance_mode from cities where id = 'hannover') = 'city_managed', 'Hannover must be city_managed';

  s0 := finance_summary(owner, 'hannover', today, today, null, null);          -- базовый отчёт Hannover за сегодня

  -- ================================================================= 2. Закупки, полная себестоимость партии
  b0 := _account_balance(bank);
  r := finance_post_entry(owner, 'cash_in', 1000, null, '', 'T6 deposit', 't6-dep-' || gen_random_uuid()::text, bank);
  assert _account_balance(bank) = b0 + 1000, 'deposit increases balance';
  assert pg_temp.fails(format($q$select finance_post_entry(%s,'cash_in',5,null,'','x','t6-noacc-%s',null)$q$, owner, gen_random_uuid()), 'account_required'),
         'cash_in without account must be rejected';

  items := jsonb_build_array(jsonb_build_object('inventory_id', ixh, 'quantity', 10, 'unit_price', '5.0000'),
                             jsonb_build_object('inventory_id', iyh, 'quantity', 10, 'unit_price', '12.0000'));
  r := purchase_save(owner, null, null, 'hannover', null, 10, 0, 'T6 purchase 1', items, 't6-pur1-' || gen_random_uuid()::text);
  pid1 := (r->>'id')::bigint;
  assert (purchase_save(owner, null, null, 'hannover', null, 10, 0, 'dup', items, (select idempotency_key from purchases where id = pid1))->>'duplicate')::boolean,
         'purchase_save is idempotent by key';
  assert (select quantity from inventory where id = ixh) = 0, 'draft purchase must not change stock';
  r := purchase_post(owner, pid1, null, 't6-post1-' || gen_random_uuid()::text);
  -- доставка 10 распределена пропорционально стоимости: X 50/170, Y — остаток (Σ = 10 точно)
  assert (select landed_unit_cost from purchase_items where purchase_id = pid1 and inventory_id = ixh) = 5.294000, 'landed cost X';
  assert (select landed_unit_cost from purchase_items where purchase_id = pid1 and inventory_id = iyh) = 12.706000, 'landed cost Y';
  assert (select quantity from inventory where id = ixh) = 10 and (select sum(qty_remaining) from stock_batches where inventory_id = ixh) = 10, 'stock = batches';
  assert (select total_cost from purchases where id = pid1) = 180, 'purchase total = goods + shipping';
  assert pg_temp.fails(format('select purchase_post(%s,%s,null,%L)', owner, pid1, 't6-post1-other-' || gen_random_uuid()::text), 'bad_status'), 'cannot post twice with another key';

  s1 := finance_summary(owner, 'hannover', today, today, null, null);
  assert s1->'current' = s0->'current', 'purchase is not an expense and not revenue';

  -- вторая партия X дороже, с оплатой со счёта; оплата — движение денег, не расход
  r := purchase_save(owner, null, null, 'hannover', null, 0, 0, 'T6 purchase 2',
        jsonb_build_array(jsonb_build_object('inventory_id', ixh, 'quantity', 10, 'unit_price', '6.0000')), 't6-pur2-' || gen_random_uuid()::text);
  pid2 := (r->>'id')::bigint;
  b0 := _account_balance(bank);
  r := purchase_post(owner, pid2, bank, 't6-post2-' || gen_random_uuid()::text);
  assert _account_balance(bank) = b0 - 60, 'payment reduces account balance';
  assert (finance_summary(owner, 'hannover', today, today, null, null)->'current') = (s0->'current'), 'payment is not P&L';

  -- ================================================================= 3. Персональные цены
  r := customer_price_set(owner, uA, px, 7, 'T6 deal', null, null);
  assert (r->>'below_cost')::boolean = false and (r->>'created')::boolean, 'personal price 7 is above cost 6';

  pv := pricing_preview('hannover', jsonb_build_array(jsonb_build_object('inventory_id', ixh, 'quantity', 1)), uA);
  assert (pv->'lines'->0->>'unit_price')::numeric = 7 and pv->'lines'->0->>'price_source' = 'personal', 'client A gets personal price';
  assert position('unit_cost' in pv::text) = 0 and position('below_cost' in pv::text) = 0, 'preview must not leak cost';
  pv := pricing_preview('hannover', jsonb_build_array(jsonb_build_object('inventory_id', ixh, 'quantity', 1)), uB);
  assert (pv->'lines'->0->>'unit_price')::numeric = 10 and pv->'lines'->0->>'price_source' = 'retail', 'client B gets standard price';
  pv := pricing_preview('hannover', jsonb_build_array(jsonb_build_object('inventory_id', ixh, 'quantity', 1)));
  assert (pv->'lines'->0->>'unit_price')::numeric = 10 and position('unit_cost' in pv::text) = 0, 'old 2-arg preview is also cost-free';

  -- A: персональная на X, оптовая ступень на Y (3 шт. → ступень 3–4)
  items := jsonb_build_array(jsonb_build_object('inventory_id', ixh, 'quantity', 2), jsonb_build_object('inventory_id', iyh, 'quantity', 1));
  pv := pricing_preview('hannover', items, uA);
  assert (select (l->>'unit_price')::numeric from jsonb_array_elements(pv->'lines') l where l->>'inventory_id' = ixh::text) = 7, 'A: X personal';
  assert (select l->>'price_source' from jsonb_array_elements(pv->'lines') l where l->>'inventory_id' = iyh::text) = 'tier'
     and (select (l->>'unit_price')::numeric from jsonb_array_elements(pv->'lines') l where l->>'inventory_id' = iyh::text) = 17, 'A: Y wholesale tier';
  assert (pv->>'total')::numeric = 31, 'A total = 2*7 + 17';

  r := create_order(uA, 'hannover', items, 'T6 contact', '', 't6-ordA-' || gen_random_uuid()::text);
  oA := (r->>'id')::uuid;
  assert (select total from orders where id = oA) = 31 and (select has_personal_price from orders where id = oA), 'order stores personal-price flag';
  assert (select unit_price from order_items where order_id = oA and inventory_id = ixh) = 7
     and (select price_source from order_items where order_id = oA and inventory_id = ixh) = 'personal', 'applied price is snapshotted in order';
  assert (select reference_price from order_items where order_id = oA and inventory_id = ixh) = 8, 'reference price (tier) kept for owner';

  -- изменение персональной цены не меняет старый заказ; ниже себестоимости — предупреждение
  r := customer_price_set(owner, uA, px, 5, 'T6 deal v2', null, null);
  assert (r->>'below_cost')::boolean and (r->>'cost_price')::numeric = 6, 'below-cost warning';
  assert (select unit_price from order_items where order_id = oA and inventory_id = ixh) = 7 and (select total from orders where id = oA) = 31, 'old order unchanged';
  pv := pricing_preview('hannover', items, uA);
  assert (select (l->>'unit_price')::numeric from jsonb_array_elements(pv->'lines') l where l->>'inventory_id' = ixh::text) = 5, 'new preview uses new price';
  assert (select count(*) from audit_log where action = 'customer_price_update' and entity_id = uA::text || ':' || px::text
            and (old_value->>'price')::numeric = 7 and (new_value->>'price')::numeric = 5) = 1, 'update audited with old/new values';
  -- повтор без изменений не плодит аудит
  perform customer_price_set(owner, uA, px, 5, 'T6 deal v2', null, null);
  assert (select count(*) from audit_log where action = 'customer_price_update' and entity_id = uA::text || ':' || px::text) = 1, 'no-op update is not audited again';
  perform customer_price_set(owner, uA, px, 7, 'T6 deal', null, null);

  -- отключение, срок действия
  perform customer_price_set_active(owner, (select id from customer_prices where user_id = uA and product_id = px), false);
  pv := pricing_preview('hannover', jsonb_build_array(jsonb_build_object('inventory_id', ixh, 'quantity', 1)), uA);
  assert (pv->'lines'->0->>'unit_price')::numeric = 10, 'disabled personal price is not applied';
  perform customer_price_set_active(owner, (select id from customer_prices where user_id = uA and product_id = px), true);
  perform customer_price_set(owner, uA, px, 7, 'expired', now() - interval '2 days', now() - interval '1 day');
  pv := pricing_preview('hannover', jsonb_build_array(jsonb_build_object('inventory_id', ixh, 'quantity', 1)), uA);
  assert (pv->'lines'->0->>'unit_price')::numeric = 10, 'expired personal price is not applied';
  perform customer_price_set(owner, uA, px, 7, 'T6 deal', now() - interval '2 days', null);

  -- права: администратор города не может менять и читать персональные цены и CRM
  assert pg_temp.fails(format('select customer_price_set(%s,%L,%L,1,%L,null,null)', hadm, uA, px, ''), 'forbidden'), 'city admin cannot set personal price';
  assert pg_temp.fails(format('select customer_price_delete(%s,1)', hadm), 'forbidden'), 'city admin cannot delete personal price';
  assert pg_temp.fails(format('select customer_price_set_active(%s,1,false)', hadm), 'forbidden'), 'city admin cannot toggle personal price';
  assert pg_temp.fails(format('select customer_prices_list(%s,%L)', hadm, uA), 'forbidden'), 'city admin cannot list personal prices';
  assert pg_temp.fails(format('select crm_customers(%s,null,null,null,null,10,0)', hadm), 'forbidden'), 'city admin cannot open CRM';
  assert pg_temp.fails(format('select crm_customer(%s,%L)', hadm, uA), 'forbidden'), 'city admin cannot open customer profile';
  -- цена не передаётся покупателем: у create_order нет параметра цены
  assert not exists(select 1 from pg_proc where proname = 'create_order' and pg_get_function_arguments(oid) ilike '%price%'), 'create_order has no price argument';

  -- выдача заказа A: FIFO-себестоимость из первой партии
  perform change_order_status(oA, 'prepared', owner);
  perform change_order_status(oA, 'issued', owner);
  assert (select cogs_total from order_items where order_id = oA and inventory_id = ixh) = 10.588, 'A: X cogs = 2 * 5.294';
  assert (select cogs_total from order_items where order_id = oA and inventory_id = iyh) = 12.706, 'A: Y cogs';
  assert (select cost_method from order_items where order_id = oA and inventory_id = ixh) = 'fifo', 'cost method fifo';

  -- CRM
  r := crm_customer(owner, uA);
  assert (r->>'issued_count')::int = 1 and (r->>'spent')::numeric = 31 and (r->>'avg_check')::numeric = 31 and jsonb_array_length(r->'prices') = 1, 'CRM stats of client A';
  assert (crm_customers(owner, '990000011', null, null, 'recent', 10, 0)->>'total')::int = 1, 'CRM search by telegram id';
  assert (crm_customers(owner, 'T6 A', null, null, 'spent', 10, 0)->'rows'->0->>'telegram_id')::bigint = 990000011, 'CRM search by name';

  -- ================================================================= 4. FIFO, отмена, двойная выдача
  r := create_order(uB, 'hannover', jsonb_build_array(jsonb_build_object('inventory_id', ixh, 'quantity', 12)), 'T6 B', '', 't6-ordB-' || gen_random_uuid()::text);
  oB := (r->>'id')::uuid;
  assert (select total from orders where id = oB) = 90, 'B: 12 units at tier 9-20 price 7.5';
  perform change_order_status(oB, 'prepared', owner);
  perform change_order_status(oB, 'issued', owner);
  -- осталось 8 из партии 1 (по 5.294) и 10 из партии 2 (по 6): 8*5.294 + 4*6 = 66.352
  assert (select cogs_total from order_items where order_id = oB) = 66.352, 'FIFO: oldest batch first, then next';
  assert (select qty_remaining from stock_batches sb join purchase_items pi on pi.id = sb.purchase_item_id where pi.purchase_id = pid1 and sb.inventory_id = ixh) = 0, 'oldest batch drained';
  assert (select qty_remaining from stock_batches sb join purchase_items pi on pi.id = sb.purchase_item_id where pi.purchase_id = pid2) = 6, 'second batch partially used';
  assert (select count(*) from batch_consumptions where order_id = oB) = 2 and (select sum(quantity) from batch_consumptions where order_id = oB) = 12, 'consumption history';
  assert (select quantity from inventory where id = ixh) = 6, 'stock after sales';
  assert pg_temp.fails(format('select change_order_status(%L,%L,%s)', oB, 'issued', owner), 'bad_transition'), 'cannot issue twice';
  assert (select sum(quantity) from batch_consumptions where order_id = oB) = 12, 'no double consumption';
  assert pg_temp.fails(format($q$insert into batch_consumptions(batch_id,inventory_id,kind,quantity,unit_cost,order_id,order_item_id)
      select batch_id,inventory_id,kind,quantity,unit_cost,order_id,order_item_id from batch_consumptions where order_id = %L limit 1$q$, oB), 'unique'),
      'same order item cannot consume the same batch twice';
  assert pg_temp.fails('update stock_batches set qty_remaining = qty_remaining + 1 where inventory_id = ' || quote_literal(ixh), 'batch_immutable'), 'batch cannot grow';

  s1 := finance_summary(owner, 'hannover', today, today, null, null);
  assert (s1->'current'->>'revenue')::numeric - (s0->'current'->>'revenue')::numeric = 121, 'revenue = 31 + 90';
  assert abs(((s1->'current'->>'cogs')::numeric - (s0->'current'->>'cogs')::numeric) - (23.294 + 66.352)) <= 0.01, 'COGS from FIFO appears in finance';

  -- отмена заказа: резерв освобождается, списания нет
  r := create_order(uB, 'hannover', jsonb_build_array(jsonb_build_object('inventory_id', ixh, 'quantity', 2)), 'T6 B', '', 't6-ordC-' || gen_random_uuid()::text);
  oC := (r->>'id')::uuid;
  assert (select reserved_quantity from inventory where id = ixh) = 2 and (select quantity from inventory where id = ixh) = 6, 'reserve does not consume stock';
  perform change_order_status(oC, 'cancelled', owner);
  assert (select reserved_quantity from inventory where id = ixh) = 0 and (select quantity from inventory where id = ixh) = 6, 'cancel releases reserve only';
  assert (select count(*) from batch_consumptions where order_id = oC) = 0, 'cancelled order has no consumption';

  -- нельзя оформить больше свободного остатка (9 шт. имеют ступень цены, остаток — 6)
  assert pg_temp.fails(format($q$select create_order(%L,'hannover',%L::jsonb,'x','',%L)$q$, uB,
         jsonb_build_array(jsonb_build_object('inventory_id', ixh, 'quantity', 9))::text, 't6-over-' || gen_random_uuid()::text), 'insufficient_stock'), 'cannot oversell';

  -- проверка возраста при выдаче (включается настройкой)
  assert pg_temp.fails(format($q$select admin_set_setting(%s,'require_age_check_on_issue','true'::jsonb)$q$, hadm), 'forbidden'), 'city admin cannot change settings';
  perform admin_set_setting(owner, 'require_age_check_on_issue', 'true'::jsonb);
  r := create_order(uB, 'hannover', jsonb_build_array(jsonb_build_object('inventory_id', ixh, 'quantity', 1)), 'T6 B', '', 't6-ordAge-' || gen_random_uuid()::text);
  oAge := (r->>'id')::uuid;
  perform change_order_status(oAge, 'prepared', owner);
  assert pg_temp.fails(format('select change_order_status(%L,%L,%s)', oAge, 'issued', owner), 'age_check_required'), 'issue blocked without age check';
  perform order_mark_age_checked(hadm, oAge);
  perform change_order_status(oAge, 'issued', owner);
  perform admin_set_setting(owner, 'require_age_check_on_issue', 'false'::jsonb);
  -- остаток X теперь 5 (6 − 1), в партии 2 — тоже 5

  -- ================================================================= 5. Перемещения и стоимость запасов
  v0 := (inventory_valuation(owner)->>'total_value')::numeric;
  r := transfer_save(owner, null, 'hannover', 'muenchen', 'T6 move', jsonb_build_array(jsonb_build_object('inventory_id', ixh, 'quantity', 4)), 't6-tr1-' || gen_random_uuid()::text);
  tid := (r->>'id')::bigint;
  assert pg_temp.fails(format('select transfer_receive(%s,%s,%L)', owner, tid, 't6-rcv-early-' || gen_random_uuid()::text), 'bad_status'), 'cannot receive a draft';
  perform transfer_send(owner, tid, 't6-snd1-' || gen_random_uuid()::text);
  assert (select quantity from inventory where id = ixh) = 1, 'sender stock decreased on send';
  assert (inventory_valuation(owner)->>'total_value')::numeric = v0, 'in-transit goods keep their value (nothing disappears)';
  assert (inventory_valuation(owner)->'in_transit'->>'units')::int >= 4, 'in-transit units visible';
  perform transfer_receive(owner, tid, 't6-rcv1-' || gen_random_uuid()::text);
  assert (select quantity from inventory where id = ixm) = 4 and (select unit_cost from stock_batches where inventory_id = ixm and qty_remaining > 0) = 6.000000,
         'receiver gets goods with original cost';
  assert (inventory_valuation(owner)->>'total_value')::numeric = v0, 'transfer does not change total inventory value';
  assert (select quantity from inventory where id = ixh) + (select quantity from inventory where id = ixm) = 5, 'units conserved';

  -- отмена в пути возвращает товар отправителю с прежней себестоимостью
  r := transfer_save(owner, null, 'hannover', 'muenchen', 'T6 cancel', jsonb_build_array(jsonb_build_object('inventory_id', ixh, 'quantity', 1)), 't6-tr2-' || gen_random_uuid()::text);
  tid2 := (r->>'id')::bigint;
  perform transfer_send(owner, tid2, 't6-snd2-' || gen_random_uuid()::text);
  assert (select quantity from inventory where id = ixh) = 0, 'all sent';
  assert pg_temp.fails(format('select transfer_cancel(%s,%s,%L)', owner, tid2, 'ok'), 'reason_required'), 'cancel needs reason';
  perform transfer_cancel(owner, tid2, 'T6 cancel in transit');
  assert (select quantity from inventory where id = ixh) = 1 and (select unit_cost from stock_batches where inventory_id = ixh and qty_remaining > 0) = 6.000000, 'returned with cost';
  assert (inventory_valuation(owner)->>'total_value')::numeric = v0, 'value unchanged after cancel';
  assert pg_temp.fails(format('select transfer_send(%s,%s,%L)', hadm, tid2, 'k-12345678'), 'forbidden'), 'city admin cannot transfer stock';

  -- ручное уменьшение остатка списывает партии (FIFO) и не ломает инвариант
  perform admin_set_stock(owner, ixm, 3, 'adjust', 'T6 loss');
  assert (select sum(qty_remaining) from stock_batches where inventory_id = ixm) = 3 and (select quantity from inventory where id = ixm) = 3, 'manual decrease consumes batches';
  assert (select sum(quantity) from batch_consumptions where inventory_id = ixm and kind = 'writeoff') = 1, 'write-off recorded';
  assert not exists(select 1 from jsonb_array_elements(inventory_batch_check(owner)) e where e->>'inventory_id' in (ixh::text, ixm::text, iyh::text)), 'stock = batches for test items';

  -- сторно закупки: чистая — можно, проданная — нельзя
  r := purchase_save(owner, null, null, 'hannover', null, 0, 0, 'T6 purchase 3', jsonb_build_array(jsonb_build_object('inventory_id', iyh, 'quantity', 5, 'unit_price', '12.0000')), 't6-pur3-' || gen_random_uuid()::text);
  pid3 := (r->>'id')::bigint;
  perform purchase_post(owner, pid3, null, 't6-post3-' || gen_random_uuid()::text);
  n1 := (select quantity from inventory where id = iyh);
  perform purchase_reverse(owner, pid3, 'T6 wrong purchase', 't6-rev3-' || gen_random_uuid()::text);
  assert (select quantity from inventory where id = iyh) = n1 - 5, 'reversal removes goods';
  assert pg_temp.fails(format('select purchase_reverse(%s,%s,%L,%L)', owner, pid1, 'T6 try sold', 't6-rev1-' || gen_random_uuid()::text), 'batch_consumed'), 'sold batches block reversal';

  -- ================================================================= 6. München (owner_operated) и Hannover (city_managed)
  s0 := finance_summary(owner, null, today, today, null, null);
  m0 := _account_balance(mcash);
  insert into orders(number, user_id, telegram_id, city_id, contact, address, delivery_service, comment, idempotency_key, status, total, paid_at, paid_amount)
    values ('T6-M-' || gen_random_uuid()::text, uA, 990000011, 'muenchen', 't6', '', '', '', 't6-m-' || gen_random_uuid()::text, 'issued', 100, now(), 100) returning id into oM;
  insert into order_items(order_id, product_id, inventory_id, product_name, quantity, unit_price, base_price, is_wholesale, tier_label, unit_cost)
    values (oM, px, ixm, 'T6 X', 10, 10, 10, false, '9–20 шт.', 6);
  s1 := finance_summary(owner, null, today, today, null, null);
  assert (s1->'current'->>'revenue')::numeric - (s0->'current'->>'revenue')::numeric = 100, 'München sale is in total revenue';
  assert (s1->'current'->>'gross_profit')::numeric - (s0->'current'->>'gross_profit')::numeric = 40, 'München sale is in total gross profit';
  assert (select sum((b->'metrics'->>'revenue')::numeric) from jsonb_array_elements(s1->'by_city') b) = (s1->'current'->>'revenue')::numeric, 'by_city revenue sums to total';
  r := _settlement('muenchen');
  assert r->>'mode' = 'owner_operated' and not (r->>'transfer_required')::boolean and (r->>'owed')::numeric = 0, 'München: no debt to owner';
  assert r->>'message' like '%управляется владельцем. Передача денег владельцу не требуется', 'München message';
  assert _account_balance(mcash) = m0 + 100, 'München cash balance shown separately and grows with sales';
  assert pg_temp.fails(format('select record_cash_transfer(%s,%L,10,%L,%L)', owner, 'muenchen', '', 't6-mtr-' || gen_random_uuid()::text), 'transfer_not_required'), 'München transfer is disabled in DB';
  assert exists(select 1 from jsonb_array_elements(s1->'settlement') x where x->>'city_id' = 'muenchen' and not (x->>'transfer_required')::boolean), 'summary: München not required';

  -- расход München уменьшает кассу München и чистую прибыль
  r := finance_post_entry(owner, 'expense', 12, 'muenchen', 'T6 rent', 'T6', 't6-exp-m-' || gen_random_uuid()::text, mcash);
  s2 := finance_summary(owner, null, today, today, null, null);
  assert (s2->'current'->>'expenses')::numeric - (s1->'current'->>'expenses')::numeric = 12, 'München expense counted';
  assert (s2->'current'->>'net_profit')::numeric - (s1->'current'->>'net_profit')::numeric = -12, 'München expense reduces net profit';
  assert _account_balance(mcash) = m0 + 100 - 12, 'München cash reduced by expense';

  -- Hannover: долг = остаток кассы города; передача уменьшает; повтор не списывает дважды
  d0 := (_settlement('hannover')->>'owed')::numeric;
  assert d0 = _account_balance(hcash) and (_settlement('hannover')->>'transfer_required')::boolean, 'Hannover owed = city cash balance';
  assert d0 >= 121 + 0, 'Hannover owed includes sales of this test';
  s1 := finance_summary(owner, null, today, today, null, null);
  r := record_cash_transfer(owner, 'hannover', 50, 'T6 transfer', 't6-htr-' || gen_random_uuid()::text);
  assert not (r->>'duplicate')::boolean and (r->>'owed_after')::numeric = d0 - 50, 'transfer reduces owed';
  assert (_settlement('hannover')->>'owed')::numeric = d0 - 50, 'settlement owed after transfer';
  s2 := finance_summary(owner, null, today, today, null, null);
  assert s2->'current' = s1->'current', 'settlement transfer is not income or expense';
  assert (record_cash_transfer(owner, 'hannover', 50, 'T6 transfer', (select substr(idempotency_key, 1, length(idempotency_key) - 4) from cash_entries where kind = 'transfer_out' order by id desc limit 1))->>'duplicate')::boolean,
         'same key is a duplicate';
  assert (_settlement('hannover')->>'owed')::numeric = d0 - 50, 'duplicate did not change owed';
  assert pg_temp.fails(format('select record_cash_transfer(%s,%L,%s,%L,%L)', owner, 'hannover', d0 + 1, '', 't6-htr2-' || gen_random_uuid()::text), 'exceeds_balance'), 'cannot transfer more than owed';
  assert jsonb_array_length(_settlement('hannover')->'transfers') >= 1, 'transfer history kept';
  assert pg_temp.fails(format('select record_cash_transfer(%s,%L,5,%L,%L)', hadm, 'hannover', '', 't6-htr3-' || gen_random_uuid()::text), 'forbidden'), 'city admin cannot record transfers';

  -- ================================================================= 7. Счета: перевод, сторно, неизменяемость, расходы со счёта
  b0 := _account_balance(bank); h0 := _account_balance(hcash);
  s1 := finance_summary(owner, null, today, today, null, null);
  r := account_transfer(owner, hcash, bank, 10, 'T6 move', 't6-acc1-' || gen_random_uuid()::text);
  tuid := (r->>'transfer_id')::uuid;
  assert _account_balance(bank) = b0 + 10 and _account_balance(hcash) = h0 - 10, 'transfer moves money';
  assert (finance_summary(owner, null, today, today, null, null)->'current') = (s1->'current'), 'account transfer is not profit';
  assert (account_transfer(owner, hcash, bank, 10, 'T6 move', (select substr(idempotency_key, 1, length(idempotency_key) - 4) from cash_entries where transfer_id = tuid and kind = 'transfer_out'))->>'duplicate')::boolean,
         'transfer is idempotent';
  assert _account_balance(bank) = b0 + 10, 'duplicate transfer did not move money again';
  assert pg_temp.fails(format('select account_transfer(%s,%s,%s,%s,%L,%L)', owner, hcash, bank, h0 + 100000, '', 't6-acc2-' || gen_random_uuid()::text), 'insufficient_funds'), 'no negative balance';
  assert pg_temp.fails(format('select account_transfer(%s,%s,%s,5,%L,%L)', owner, hcash, hcash, '', 't6-acc3-' || gen_random_uuid()::text), 'bad_accounts'), 'same account rejected';
  perform account_transfer_reverse(owner, tuid, 'T6 revert', 't6-accrev-' || gen_random_uuid()::text);
  assert _account_balance(bank) = b0 and _account_balance(hcash) = h0, 'reversal restores both balances';
  assert pg_temp.fails(format('select account_transfer_reverse(%s,%L,%L,%L)', owner, tuid, 'T6 again', 't6-accrev2-' || gen_random_uuid()::text), 'already_reversed'), 'no double reversal';

  r := finance_post_entry(owner, 'expense', 5, 'hannover', 'T6 cat', 'T6', 't6-exp-h-' || gen_random_uuid()::text, hcash);
  ent := (r->>'id')::bigint;
  assert _account_balance(hcash) = h0 - 5, 'expense with account reduces cash';
  perform finance_reverse_entry(owner, ent, 'T6 wrong expense', 't6-exprev-' || gen_random_uuid()::text);
  assert _account_balance(hcash) = h0, 'reversing expense restores cash';
  assert pg_temp.fails(format($q$select finance_post_entry(%s,'cash_out',%s,null,'','x',%L,%s)$q$, owner, h0 + 500000, 't6-wd-' || gen_random_uuid()::text, hcash), 'insufficient_funds'), 'withdrawal cannot exceed balance';
  assert pg_temp.fails(format($q$select finance_post_entry(%s,'expense',5,'muenchen','c','x',%L,%s)$q$, owner, 't6-mm-' || gen_random_uuid()::text, hcash), 'account_city_mismatch'), 'expense city must match city cash';
  r := cash_adjust(owner, bank, 7, 'T6 recount', 't6-adj-' || gen_random_uuid()::text);
  assert _account_balance(bank) = b0 + 7, 'adjustment applied';
  assert pg_temp.fails(format('select cash_adjust(%s,%s,-1000000,%L,%L)', owner, bank, 'T6 too much', 't6-adj2-' || gen_random_uuid()::text), 'insufficient_funds'), 'adjustment cannot make negative balance';
  assert pg_temp.fails(format('select cash_adjust(%s,%s,1,%L,%L)', owner, bank, 'no', 't6-adj3-' || gen_random_uuid()::text), 'reason_required'), 'adjustment needs reason';
  assert pg_temp.fails('update cash_entries set amount = 1 where id = (select max(id) from cash_entries)', 'cash_immutable'), 'cash journal is immutable (update)';
  assert pg_temp.fails('delete from cash_entries where id = (select max(id) from cash_entries)', 'cash_immutable'), 'cash journal is immutable (delete)';
  assert pg_temp.fails('update audit_log set action = ''x'' where id = (select max(id) from audit_log)', 'audit_immutable'), 'audit log is immutable (update)';
  assert pg_temp.fails('delete from audit_log where id = (select max(id) from audit_log)', 'audit_immutable'), 'audit log is immutable (delete)';
  assert exists(select 1 from pg_trigger where tgname = 'trg_cash_transfers_frozen'), 'legacy cash_transfers is frozen (history kept)';
  assert pg_temp.fails(format('select account_transfer(%s,%s,%s,5,%L,%L)', hadm, hcash, bank, '', 't6-acc4-' || gen_random_uuid()::text), 'forbidden'), 'city admin cannot move money';

  -- ================================================================= 8. Безопасность, рассылки, аудит
  assert not has_column_privilege('anon', 'public.products', 'cost_price', 'SELECT'), 'anon must not read products.cost_price';
  assert not has_column_privilege('authenticated', 'public.products', 'cost_price', 'SELECT'), 'authenticated must not read products.cost_price';
  assert has_column_privilege('anon', 'public.products', 'name', 'SELECT'), 'public catalog columns stay readable';
  assert not has_table_privilege('anon', 'public.orders', 'SELECT') and not has_table_privilege('anon', 'public.customer_prices', 'SELECT')
     and not has_table_privilege('anon', 'public.cash_entries', 'SELECT') and not has_table_privilege('anon', 'public.stock_batches', 'SELECT'), 'anon has no access to private tables';
  assert not has_function_privilege('anon', 'public.crm_customers(bigint,text,text,int,text,int,int)', 'EXECUTE')
     and not has_function_privilege('authenticated', 'public.customer_price_set(bigint,uuid,uuid,numeric,text,timestamptz,timestamptz)', 'EXECUTE'), 'RPC is not executable by anon/authenticated';
  assert (select bool_and(relrowsecurity) from pg_class where relname in ('customer_prices','cash_accounts','cash_entries','city_mode_history','suppliers','purchases',
          'purchase_items','stock_batches','batch_consumptions','stock_transfers','stock_transfer_items','stock_transfer_layers','app_settings')) , 'RLS enabled on all new tables';

  -- рассылки выключены по умолчанию; только с согласием; дедупликация очереди
  assert not _setting_bool('broadcasts_enabled'), 'broadcasts are off by default';
  assert pg_temp.fails(format('select create_broadcast(%s,%L,%L,%L::uuid[],%L)', owner, 'hannover', 'T6', '{}', 't6-bc0-' || gen_random_uuid()::text), 'broadcasts_disabled'), 'broadcast blocked by default';
  perform admin_set_setting(owner, 'broadcasts_enabled', 'true'::jsonb);
  r := create_broadcast(owner, 'hannover', 'T6 text', '{}', 't6-bc1-' || gen_random_uuid()::text);
  bid := (r->>'id')::bigint;
  assert exists(select 1 from outbox where broadcast_id = bid and chat_id = 990000013), 'client with consent receives broadcast';
  assert not exists(select 1 from outbox where broadcast_id = bid and chat_id in (990000011, 990000012)), 'clients without consent do not';
  assert pg_temp.fails(format('select create_broadcast(%s,%L,%L,%L::uuid[],%L)', owner, 'hannover', 'T6 2', '{}', 't6-bc2-' || gen_random_uuid()::text), 'broadcast_cooldown'), 'cooldown';
  assert jsonb_array_length(broadcast_list(owner, 'hannover', 5)) >= 1, 'broadcast journal';
  assert pg_temp.fails($q$insert into outbox(chat_id,kind,text,dedupe_key) values (1,'low_stock','x','t6-dup-1'),(1,'low_stock','x','t6-dup-1')$q$, 'unique'), 'outbox dedupe key is unique';
  insert into outbox(chat_id, kind, text) values (1, 'low_stock', 'x'), (1, 'low_stock', 'x');   -- без ключа дубли допустимы (NULL)
  assert (outbox_stats(owner, 7)->'by_kind') is not null, 'outbox stats';

  -- низкие остатки и белый список аудита
  assert jsonb_array_length(low_stock_for_order(oA)) >= 1, 'low stock detected (X has 1 available)';
  assert pg_temp.fails(format($q$select audit_event(%s,'delete_everything','x',null,'{}'::jsonb)$q$, owner), 'bad_action'), 'audit_event whitelist';
  perform audit_event(owner, 'customers_export', 'customers', null, '{"rows": 1}'::jsonb);

  -- изменения каталога идут через RPC с аудитом
  perform admin_update_product_fields(owner, px, '{"name":"T6 X renamed"}'::jsonb);
  assert exists(select 1 from audit_log where action = 'product_update' and entity_id = px::text and new_value->>'name' = 'T6 X renamed' and old_value->>'name' = 'T6 X'), 'product rename audited';
  assert pg_temp.fails(format($q$select admin_update_product_fields(%s,%L,'{"active":false}'::jsonb)$q$, hadm, px), 'forbidden'), 'city admin cannot edit products';
  assert (activity_feed(owner, today, today, 'audit', null, 50)) is not null and jsonb_array_length(activity_feed(owner, today, today, null, null, 500)) > 0, 'activity feed works';

  -- ================================================================= 9. Смена режима города (не создаёт искусственных долгов и не меняет историю)
  n1 := (select count(*) from orders); n2 := (select count(*) from finance_entries);
  assert pg_temp.fails(format('select admin_set_city_mode(%s,%L,%L,%L,%L)', owner, 'hannover', 'owner_operated', 'T6 switch', 't6-mode0-' || gen_random_uuid()::text), 'settle_first'),
         'cannot drop debt by switching mode';
  perform record_cash_transfer(owner, 'hannover', (_settlement('hannover')->>'owed')::numeric, 'T6 settle all', 't6-settle-' || gen_random_uuid()::text);
  assert (_settlement('hannover')->>'owed')::numeric = 0, 'Hannover fully settled';
  r := admin_set_city_mode(owner, 'hannover', 'owner_operated', 'T6 switch', 't6-mode1-' || gen_random_uuid()::text);
  assert (select finance_mode from cities where id = 'hannover') = 'owner_operated' and not (_settlement('hannover')->>'transfer_required')::boolean, 'Hannover now owner_operated';
  assert pg_temp.fails(format('select admin_set_city_mode(%s,%L,%L,%L,%L)', owner, 'hannover', 'owner_operated', 'T6 same', 't6-mode2-' || gen_random_uuid()::text), 'mode_unchanged'), 'same mode rejected';
  assert (admin_set_city_mode(owner, 'hannover', 'owner_operated', 'T6 switch', (select idempotency_key from city_mode_history where city_id = 'hannover' order by id desc limit 1))->>'duplicate')::boolean, 'mode change is idempotent';
  insert into orders(number, user_id, telegram_id, city_id, contact, address, delivery_service, comment, idempotency_key, status, total, paid_at, paid_amount)
    values ('T6-H1-' || gen_random_uuid()::text, uA, 990000011, 'hannover', 't6', '', '', '', 't6-h1-' || gen_random_uuid()::text, 'issued', 30, clock_timestamp(), 30);
  assert (_settlement('hannover')->>'owed')::numeric = 0 and (_settlement('hannover')->>'cash_balance')::numeric >= 30, 'owner_operated: money is owner''s, no debt';
  perform admin_set_city_mode(owner, 'hannover', 'city_managed', 'T6 switch back', 't6-mode3-' || gen_random_uuid()::text);
  assert (_settlement('hannover')->>'owed')::numeric = 0, 'switching to city_managed does not turn owner money into debt';
  insert into orders(number, user_id, telegram_id, city_id, contact, address, delivery_service, comment, idempotency_key, status, total, paid_at, paid_amount)
    values ('T6-H2-' || gen_random_uuid()::text, uA, 990000011, 'hannover', 't6', '', '', '', 't6-h2-' || gen_random_uuid()::text, 'issued', 20, clock_timestamp(), 20);
  assert (_settlement('hannover')->>'owed')::numeric = 20, 'new sales after switch create debt again';
  assert (select count(*) from orders) = n1 + 2 and (select count(*) from finance_entries) = n2, 'mode changes did not touch historical finance entries';
  assert (select count(*) from city_mode_history where city_id = 'hannover') >= 3, 'mode history kept';
  assert pg_temp.fails(format('select admin_set_city_mode(%s,%L,%L,%L,%L)', hadm, 'hannover', 'owner_operated', 'T6 hack', 't6-mode4-' || gen_random_uuid()::text), 'forbidden'), 'city admin cannot change mode';

  raise notice 'ALL V6 TESTS PASSED';
end $$;

rollback;
