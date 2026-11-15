"""Offline-тесты логики backend v4 (запуск: `cd backend && python3 -m unittest discover -s tests_offline -v`).

Работают на заглушках (см. bootstrap.py): проверяют распределение прав, передачу параметров в RPC, защиту от утечек,
дедупликацию уведомлений и деньги без float. НЕ проверяют SQL — для него см. supabase/tests_v6_*.sql.
"""
import ast, asyncio, os, unittest
from decimal import Decimal

import bootstrap
from bootstrap import main, HTTPException, FastAPI

OWNER = {"telegram_id": 1, "role": "owner", "city_id": None}
HANNOVER = {"telegram_id": 2, "role": "city_admin", "city_id": "hannover"}


class Fake:
    """Подмена main.rpc / main.db: записывает вызовы, отвечает заготовленными значениями."""
    def __init__(self, rpc_results=None, db_results=None):
        self.rpc_calls, self.db_calls = [], []
        self.rpc_results, self.db_results = rpc_results or {}, db_results or {}

    async def rpc(self, name, args):
        self.rpc_calls.append((name, args))
        r = self.rpc_results.get(name)
        if isinstance(r, Exception): raise r
        return r(args) if callable(r) else r

    async def db(self, method, path, prefer=None, **kw):
        self.db_calls.append((method, path, prefer, kw))
        r = self.db_results.get(f"{method} {path.split('?')[0]}")
        if isinstance(r, Exception): raise r
        return r(kw) if callable(r) else r

    def names(self): return [n for n, _ in self.rpc_calls]


def run(coro): return asyncio.run(coro)


class Base(unittest.TestCase):
    def setUp(self):
        self._orig = (main.rpc, main.db, main.bg, main.deliver_pending)
        main.bg = lambda coro: (coro.close(), None)[1]          # фоновые задачи в тестах не запускаем
        async def noop(*a, **kw): return None
        main.deliver_pending = noop

    def tearDown(self):
        main.rpc, main.db, main.bg, main.deliver_pending = self._orig

    def use(self, fake):
        main.rpc, main.db = fake.rpc, fake.db
        return fake


# ============================================================ права доступа (статический обход main.py)
CITY_ADMIN_ALLOWED = {
    ("GET", "/api/admin/cities"), ("GET", "/api/admin/dashboard"), ("GET", "/api/admin/catalog"),
    ("GET", "/api/admin/inventory"), ("POST", "/api/admin/inventory"), ("GET", "/api/admin/inventory/{inventory_id}/history"),
    ("GET", "/api/admin/orders"), ("GET", "/api/admin/orders/{order_id}"), ("PATCH", "/api/admin/orders/{order_id}"),
    ("POST", "/api/admin/orders/{order_id}/age-check"), ("GET", "/api/admin/settlement"),
    ("GET", "/api/admin/broadcast/preview"), ("POST", "/api/admin/broadcasts"), ("GET", "/api/admin/broadcasts"),
    ("GET", "/api/admin/broadcasts/{broadcast_id}"), ("GET", "/api/admin/export/inventory"), ("GET", "/api/admin/export/orders"),
}


class AuthorizationMatrix(unittest.TestCase):
    """Каждый /api/admin/* эндпоинт обязан вызывать require_owner(ctx), кроме явного списка допустимых для администратора города.
    Забытая проверка роли в новом эндпоинте ломает этот тест."""

    def endpoints(self):
        src = open(os.path.join(os.path.dirname(__file__), "..", "main.py"), encoding="utf-8").read()
        tree = ast.parse(src)
        out = []
        for node in ast.walk(tree):
            if isinstance(node, (ast.AsyncFunctionDef, ast.FunctionDef)):
                for d in node.decorator_list:
                    if (isinstance(d, ast.Call) and isinstance(d.func, ast.Attribute) and isinstance(d.func.value, ast.Name)
                            and d.func.value.id == "app" and d.args and isinstance(d.args[0], ast.Constant)
                            and str(d.args[0].value).startswith("/api/admin/")):
                        calls_owner = any(isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id == "require_owner"
                                          for n in ast.walk(node))
                        out.append((d.func.attr.upper(), d.args[0].value, node.name, calls_owner))
        return out

    def test_every_admin_endpoint_is_owner_only_unless_allowlisted(self):
        eps = self.endpoints()
        self.assertGreater(len(eps), 50)
        bad = [f"{m} {p} ({fn})" for m, p, fn, owner in eps if not owner and (m, p) not in CITY_ADMIN_ALLOWED]
        self.assertEqual(bad, [], "эндпоинты без require_owner(ctx), которых нет в списке для администратора города")

    def test_allowlist_has_no_stale_entries(self):
        existing = {(m, p) for m, p, _, _ in self.endpoints()}
        self.assertEqual(sorted(CITY_ADMIN_ALLOWED - existing), [])

    def test_new_finance_and_crm_endpoints_exist_and_are_owner_only(self):
        eps = {(m, p): owner for m, p, _, owner in self.endpoints()}
        for key in [("GET", "/api/admin/customers"), ("PUT", "/api/admin/customers/{user_id}/prices"),
                    ("DELETE", "/api/admin/customer-prices/{price_id}"), ("POST", "/api/admin/cash/transfers"),
                    ("PUT", "/api/admin/cities/{city_id}/mode"), ("POST", "/api/admin/purchases/{purchase_id}/post"),
                    ("POST", "/api/admin/stock-transfers/{transfer_id}/send"), ("GET", "/api/admin/activity"),
                    ("PUT", "/api/admin/settings/{key}")]:
            self.assertIn(key, eps); self.assertTrue(eps[key], key)

    def test_export_route_declared_before_param_route(self):
        paths = [p for m, p, f in FastAPI.ROUTES if m == "GET" and p.startswith("/api/admin/customers")]
        self.assertLess(paths.index("/api/admin/customers/export"), paths.index("/api/admin/customers/{user_id}"))


class OwnerOnlyAtRuntime(Base):
    def test_city_admin_cannot_touch_personal_prices_or_crm(self):
        fake = self.use(Fake())
        body = main.CustomerPriceIn(product_id="00000000-0000-0000-0000-000000000001", price=Decimal("7"), note="", valid_from=None, valid_until=None)
        for coro in [main.crm_set_price("00000000-0000-0000-0000-000000000002", body, HANNOVER),
                     main.crm_delete_price(1, HANNOVER), main.crm_toggle_price(1, main.ActiveIn(active=False), HANNOVER),
                     main.crm_get("00000000-0000-0000-0000-000000000002", HANNOVER), main.crm_export("", None, None, HANNOVER)]:
            with self.assertRaises(HTTPException) as cm: run(coro)
            self.assertEqual(cm.exception.status_code, 403)
        self.assertEqual(fake.rpc_calls, [], "RPC не должен вызываться при отказе по роли")

    def test_city_admin_cannot_change_city_mode_or_post_finance(self):
        self.use(Fake())
        with self.assertRaises(HTTPException) as cm:
            run(main.admin_set_city_mode("muenchen", main.CityModeIn(mode="city_managed", reason="проверка", idempotency_key="k" * 10), HANNOVER))
        self.assertEqual(cm.exception.status_code, 403)
        with self.assertRaises(HTTPException) as cm:
            run(main.cash_transfer(main.AccountTransferIn(from_account_id=1, to_account_id=2, amount=Decimal("5"), reason="", idempotency_key="k" * 10), HANNOVER))
        self.assertEqual(cm.exception.status_code, 403)


# ============================================================ персональные цены
class PersonalPrices(Base):
    def test_set_price_sends_money_string_not_float(self):
        fake = self.use(Fake({"customer_price_set": {"id": 5, "price": "7.50", "below_cost": False}}))
        body = main.CustomerPriceIn(product_id="00000000-0000-0000-0000-000000000001", price=Decimal("7.5"), note="  договорённость ", valid_from=None, valid_until=None)
        res = run(main.crm_set_price("00000000-0000-0000-0000-000000000002", body, OWNER))
        name, args = fake.rpc_calls[0]
        self.assertEqual(name, "customer_price_set")
        self.assertEqual(args["p_price"], "7.50"); self.assertIsInstance(args["p_price"], str)
        self.assertEqual(args["p_note"], "договорённость"); self.assertEqual(args["p_actor"], 1)
        self.assertEqual(res["id"], 5)

    def test_preview_passes_user_and_strips_cost_even_if_rpc_leaks(self):
        leaked = {"lines": [{"inventory_id": "i", "unit_price": 7, "unit_cost": 3.1, "personal_price_id": 9, "below_cost": True, "price_source": "personal"}], "total": 7}
        fake = self.use(Fake({"pricing_preview": leaked}))
        u = {"id": "user-uuid", "city_id": "hannover", "age_confirmed_at": "2026-01-01"}
        body = main.OrderPreviewIn(items=[main.Item(inventory_id="00000000-0000-0000-0000-000000000003", quantity=1)])
        res = run(main.pricing_preview(body, u))
        self.assertEqual(fake.rpc_calls[0][1]["p_user"], "user-uuid")
        line = res["lines"][0]
        for k in ("unit_cost", "personal_price_id", "below_cost"): self.assertNotIn(k, line)
        self.assertEqual(line["price_source"], "personal")   # покупатель видит, что цена персональная

    def test_edit_preview_strips_cost(self):
        self.use(Fake({"customer_edit_preview": {"lines": [{"unit_cost": 1, "unit_price": 2}]}}))
        u = {"id": "u", "city_id": "hannover", "age_confirmed_at": "x"}
        res = run(main.edit_preview("00000000-0000-0000-0000-000000000004", main.OrderPreviewIn(items=[main.Item(inventory_id="00000000-0000-0000-0000-000000000003", quantity=1)]), u))
        self.assertNotIn("unit_cost", res["lines"][0])

    def test_city_admin_does_not_see_personal_price_markers(self):
        order = {"id": "o", "city_id": "hannover", "user_id": "u", "has_personal_price": True,
                 "order_items": [{"unit_price": 7, "price_source": "personal", "reference_price": 8}]}
        self.use(Fake(db_results={"GET orders": [order]}))
        got = run(main.admin_get_order("00000000-0000-0000-0000-000000000005", HANNOVER))
        self.assertNotIn("has_personal_price", got); self.assertNotIn("user_id", got)
        self.assertNotIn("price_source", got["order_items"][0]); self.assertNotIn("reference_price", got["order_items"][0])
        self.assertEqual(got["order_items"][0]["unit_price"], 7)   # итоговую цену администратор видит — он принимает деньги

    def test_owner_sees_personal_price_markers(self):
        order = {"id": "o", "city_id": "hannover", "user_id": "u", "has_personal_price": True,
                 "order_items": [{"unit_price": 7, "price_source": "personal", "reference_price": 8}]}
        self.use(Fake(db_results={"GET orders": [order]}))
        got = run(main.admin_get_order("00000000-0000-0000-0000-000000000005", OWNER))
        self.assertTrue(got["has_personal_price"]); self.assertEqual(got["order_items"][0]["price_source"], "personal")

    def test_city_admin_cannot_open_other_city_order(self):
        self.use(Fake(db_results={"GET orders": [{"id": "o", "city_id": "muenchen", "order_items": []}]}))
        with self.assertRaises(HTTPException) as cm: run(main.admin_get_order("00000000-0000-0000-0000-000000000005", HANNOVER))
        self.assertEqual(cm.exception.status_code, 404)

    def test_order_text_marks_personal_price_for_owner_only(self):
        o = {"status": "new", "number": "N1", "city_id": "x", "cities": {"name": "Hannover"}, "telegram_id": 5, "total": 7, "users": {},
             "order_items": [{"product_name": "Товар", "quantity": 1, "price_source": "personal"}]}
        self.assertIn("персональная цена", main.order_text(o, owner_view=True))
        self.assertNotIn("персональная цена", main.order_text(o, owner_view=False))
        self.assertNotIn("персональная цена", main.order_text(o))

    def test_order_select_does_not_expose_idempotency_or_cost(self):
        for bad in ("idempotency_key", "unit_cost", "cost_price", "paid_by", "*,"):
            self.assertNotIn(bad, main.ORDER_SELECT)


# ============================================================ уведомления
class Notifications(Base):
    def test_enqueue_uses_on_conflict_ignore_duplicates(self):
        fake = self.use(Fake())
        run(main.enqueue([{"chat_id": 1, "kind": "order_customer", "text": "x", "dedupe_key": "a"}, {"chat_id": 2, "kind": "broadcast", "text": "y"}]))
        method, path, prefer, kw = fake.db_calls[0]
        self.assertEqual((method, path), ("POST", "outbox?on_conflict=dedupe_key"))
        self.assertIn("ignore-duplicates", prefer)
        self.assertEqual([r["dedupe_key"] for r in kw["json"]], ["a", None])    # у всех строк один набор ключей

    def test_admin_notification_keys_are_stable_per_order_tag_and_chat(self):
        fake = self.use(Fake(db_results={"GET admins": [{"telegram_id": 1, "role": "owner", "city_id": None},
                                                         {"telegram_id": 2, "role": "city_admin", "city_id": "hannover"},
                                                         {"telegram_id": 3, "role": "city_admin", "city_id": "other"}]}))
        run(main.enqueue_admins("ord1", "hannover", "created")); run(main.enqueue_admins("ord1", "hannover", "created"))
        rows1 = fake.db_calls[1][3]["json"]; rows2 = fake.db_calls[3][3]["json"]
        self.assertEqual([r["dedupe_key"] for r in rows1], [r["dedupe_key"] for r in rows2])
        self.assertEqual(sorted(r["chat_id"] for r in rows1), [1, 2], "чужой город уведомление не получает")
        run(main.enqueue_admins("ord1", "hannover", "edit:abc"))
        self.assertNotEqual(fake.db_calls[5][3]["json"][0]["dedupe_key"], rows1[0]["dedupe_key"])

    def test_low_stock_alert_after_issue_is_deduped_per_level_and_day(self):
        item = {"inventory_id": "inv1", "city_id": "hannover", "product_name": "Товар", "variant_name": None, "available": 1, "threshold": 2}
        fake = self.use(Fake({"low_stock_for_order": [item]},
                             {"GET admins": [{"telegram_id": 1, "role": "owner", "city_id": None}, {"telegram_id": 2, "role": "city_admin", "city_id": "hannover"},
                                             {"telegram_id": 3, "role": "city_admin", "city_id": "muenchen"}],
                              "GET cities": [{"id": "hannover", "name": "Hannover", "active": True}],
                              "GET orders": [{"id": "o1", "telegram_id": 9, "number": "N1", "order_items": [], "users": {}}]}))
        run(main.after_status_change("o1", "issued"))
        posted = [kw["json"] for m, p, pr, kw in fake.db_calls if m == "POST" and p.startswith("outbox")]
        low = [r for batch in posted for r in batch if r["kind"] == "low_stock"]
        self.assertEqual(sorted(r["chat_id"] for r in low), [1, 2])
        self.assertTrue(all(r["dedupe_key"].startswith("low:inv1:1:") for r in low))
        customer = [r for batch in posted for r in batch if r["kind"] == "order_customer"]
        self.assertEqual(customer[0]["dedupe_key"], "order_customer:o1:issued")

    def test_status_change_other_than_issued_has_no_low_stock_call(self):
        fake = self.use(Fake(db_results={"GET orders": [{"id": "o1", "telegram_id": 9, "number": "N1", "order_items": [], "users": {}}]}))
        run(main.after_status_change("o1", "prepared"))
        self.assertNotIn("low_stock_for_order", fake.names())

    def test_broadcast_recipient_count_requires_consent(self):
        fake = self.use(Fake(db_results={"GET users": [{"telegram_id": 1}]}))
        self.assertEqual(run(main.count_recipients("hannover")), 1)
        self.assertEqual(fake.db_calls[0][3]["params"]["marketing_consent_at"], "not.is.null")

    def test_enabling_notifications_records_consent_and_disabling_clears_it(self):
        fake = self.use(Fake())
        u = {"id": "u1"}
        run(main.set_notifications(main.NotifyIn(notify_stock=True), u))
        run(main.set_notifications(main.NotifyIn(notify_stock=False), u))
        on, off = fake.db_calls[0][3]["json"], fake.db_calls[1][3]["json"]
        self.assertTrue(on["notify_stock"]); self.assertIsNotNone(on["marketing_consent_at"])
        self.assertFalse(off["notify_stock"]); self.assertIsNone(off["marketing_consent_at"])

    def test_owner_check_for_card_rendering(self):
        fake = self.use(Fake(db_results={"GET admins": lambda kw: [{"telegram_id": 1}] if kw["params"]["telegram_id"] == "eq.1" else []}))
        self.assertTrue(run(main.is_owner(1))); self.assertFalse(run(main.is_owner(2)))


# ============================================================ финансы: ошибки и журнал
class FinanceFailures(Base):
    def test_business_rejection_is_audited_not_alerted(self):
        err = HTTPException(409, "insufficient_funds")
        fake = self.use(Fake({"account_transfer": err, "audit_event": None}))
        body = main.AccountTransferIn(from_account_id=1, to_account_id=2, amount=Decimal("5"), reason="", idempotency_key="key-12345")
        captured = []
        main.bg = lambda coro: captured.append(coro)
        with self.assertRaises(HTTPException): run(main.cash_transfer(body, OWNER))
        run(captured[0])
        self.assertIn("audit_event", fake.names())
        self.assertEqual([c for c in fake.db_calls if c[1].startswith("outbox")], [], "для бизнес-отказа сообщение владельцу не нужно")

    def test_db_failure_alerts_owner_once_per_key(self):
        err = HTTPException(500, "db_error")
        fake = self.use(Fake({"purchase_post": err, "audit_event": None}, {"GET admins": [{"telegram_id": 1}]}))
        captured = []
        main.bg = lambda coro: captured.append(coro)
        with self.assertRaises(HTTPException): run(main.purchase_post(7, main.PurchasePostIn(account_id=None, idempotency_key="key-12345"), OWNER))
        run(captured[0])
        posted = [c for c in fake.db_calls if c[0] == "POST" and c[1].startswith("outbox")]
        self.assertEqual(posted[0][3]["json"][0]["kind"], "system_alert")
        self.assertEqual(posted[0][3]["json"][0]["dedupe_key"], "fin_fail:purchase_post:key-12345:1")

    def test_forbidden_is_not_logged_as_failed_operation(self):
        fake = self.use(Fake({"cash_account_create": HTTPException(403, "forbidden")}))
        captured = []
        main.bg = lambda coro: captured.append(coro)
        with self.assertRaises(HTTPException): run(main.cash_account_create(main.AccountIn(name="X", kind="other", opening_balance=Decimal("0")), OWNER))
        self.assertEqual(captured, [])

    def test_finance_entry_sends_decimal_string_and_account(self):
        fake = self.use(Fake({"finance_post_entry": {"id": 1}}))
        b = main.FinanceEntryIn(op_type="expense", amount=Decimal("12.3"), account_id=4, city_id="hannover", category="Аренда", description=" ", idempotency_key="key-12345")
        run(main.finance_post_entry_ep(b, OWNER))
        args = fake.rpc_calls[0][1]
        self.assertEqual((args["p_amount"], args["p_account"]), ("12.30", 4))

    def test_settlement_transfer_goes_through_record_cash_transfer(self):
        fake = self.use(Fake({"record_cash_transfer": {"duplicate": False}}))
        run(main.admin_record_transfer(main.SettlementIn(city_id="hannover", amount=Decimal("100"), note="", idempotency_key="key-12345"), OWNER))
        self.assertEqual(fake.rpc_calls[0][0], "record_cash_transfer"); self.assertEqual(fake.rpc_calls[0][1]["p_amount"], "100.00")


# ============================================================ CRM, закупки, перемещения
class CrmPurchasesTransfers(Base):
    def test_customer_export_escapes_formulas_and_is_audited(self):
        rows = [{"telegram_id": 5, "username": "=HYPERLINK(\"x\")", "first_name": "+7 test", "last_name": "Ok", "city_id": "hannover",
                 "orders_count": 2, "issued_count": 1, "spent": 20, "avg_check": 20, "last_order_at": None, "personal_prices": 0}]
        fake = self.use(Fake({"crm_customers": {"total": 1, "rows": rows}, "audit_event": None}))
        res = run(main.crm_export("", None, None, OWNER))
        self.assertIn("'=HYPERLINK", res.body); self.assertIn("\"'+7 test\"", res.body)
        self.assertIn("audit_event", fake.names())
        self.assertEqual(fake.rpc_calls[-1][1]["p_detail"]["rows"], 1)

    def test_purchase_items_keep_four_decimals_and_shipping_two(self):
        fake = self.use(Fake({"purchase_save": {"id": 1}}))
        b = main.PurchaseIn(supplier_id=1, city_id="hannover", purchase_date=None, shipping_cost=Decimal("10"), extra_cost=Decimal("0"), note="",
                            items=[main.PurchaseItemIn(inventory_id="00000000-0000-0000-0000-000000000003", quantity=10, unit_price=Decimal("3.1234"))],
                            idempotency_key="key-12345")
        run(main.purchase_create(b, OWNER))
        a = fake.rpc_calls[0][1]
        self.assertEqual(a["p_items"][0]["unit_price"], "3.1234"); self.assertEqual(a["p_shipping"], "10.00"); self.assertIsNone(a["p_purchase"])

    def test_transfer_workflow_passes_keys(self):
        fake = self.use(Fake({"transfer_send": {"status": "in_transit"}, "transfer_receive": {"status": "received"}}))
        run(main.stock_transfer_send(3, main.KeyIn(idempotency_key="send-12345"), OWNER))
        run(main.stock_transfer_receive(3, main.KeyIn(idempotency_key="recv-12345"), OWNER))
        self.assertEqual([(n, a["p_key"]) for n, a in fake.rpc_calls], [("transfer_send", "send-12345"), ("transfer_receive", "recv-12345")])

    def test_product_and_variant_edits_go_through_audited_rpc(self):
        fake = self.use(Fake({"admin_update_product_fields": {}, "admin_update_variant_fields": {}, "admin_category_save": {}}))
        run(main.admin_update_product("00000000-0000-0000-0000-000000000006", main.ProductPatch(name=" Новое ", active=False), OWNER))
        run(main.admin_update_variant("00000000-0000-0000-0000-000000000007", main.VariantPatch(price=Decimal("9.9")), OWNER))
        run(main.admin_update_category(3, {"name": "Cat", "sort": 2, "evil": 1}, OWNER))
        self.assertEqual(fake.names(), ["admin_update_product_fields", "admin_update_variant_fields", "admin_category_save"])
        self.assertEqual(fake.rpc_calls[0][1]["p_patch"]["name"], "Новое")
        self.assertEqual(fake.rpc_calls[1][1]["p_patch"]["price"], "9.90")
        self.assertEqual([c for c in fake.db_calls if c[0] in ("PATCH", "POST")], [], "прямых записей в таблицы больше нет")

    def test_age_check_endpoint_delegates_city_check_to_db(self):
        fake = self.use(Fake({"order_mark_age_checked": {"duplicate": False}}))
        run(main.admin_order_age_check("00000000-0000-0000-0000-000000000005", HANNOVER))
        self.assertEqual(fake.rpc_calls[0][1]["p_actor"], 2)


# ============================================================ helpers
class Helpers(unittest.TestCase):
    def test_money_never_uses_float_artifacts(self):
        from helpers import money
        self.assertEqual(money(Decimal("0.1") + Decimal("0.2")), "0.30")
        self.assertEqual(money("7.505"), "7.51"); self.assertEqual(money(7), "7.00")
        self.assertEqual(money(Decimal("3.1234"), 4), "3.1234")
        with self.assertRaises(ValueError): money(float("nan"))
        with self.assertRaises(ValueError): money(None)

    def test_csv_cell(self):
        from helpers import csv_cell
        self.assertEqual(csv_cell("=1+1"), "\"'=1+1\""); self.assertEqual(csv_cell("-5"), "\"'-5\""); self.assertEqual(csv_cell(-5), '"-5"')
        self.assertEqual(csv_cell('a"b'), '"a""b"'); self.assertEqual(csv_cell(None), '""'); self.assertEqual(csv_cell("@x"), "\"'@x\"")

    def test_eur(self):
        from helpers import eur
        self.assertEqual(eur(7.5), "7,50 €"); self.assertEqual(eur(None), "0,00 €")


if __name__ == "__main__":
    unittest.main()
