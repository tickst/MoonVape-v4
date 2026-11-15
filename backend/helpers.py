"""Чистые вспомогательные функции backend (без FastAPI/aiogram), чтобы их можно было тестировать отдельно."""
from decimal import Decimal, ROUND_HALF_UP, InvalidOperation
from typing import Any, Iterable

CENT = Decimal("0.01")
_FORMULA_PREFIX = ("=", "+", "-", "@", "\t", "\r")


def money(x: Any, places: int = 2) -> str:
    """Деньги → строка с фиксированным числом знаков ('7.50'). Принимает Decimal/int/str/float.
    Строка уходит в PostgREST и приводится к numeric на стороне БД — без промежуточного float."""
    if x is None:
        raise ValueError("money: None")
    try:
        d = x if isinstance(x, Decimal) else Decimal(str(x))
    except InvalidOperation as ex:
        raise ValueError(f"money: bad value {x!r}") from ex
    if not d.is_finite():
        raise ValueError("money: not finite")
    return str(d.quantize(Decimal(1).scaleb(-places), rounding=ROUND_HALF_UP))


def money_or_none(x: Any):
    return None if x is None else money(x)


def eur(x: Any) -> str:
    """Формат для сообщений: '12,50 €'."""
    try:
        d = Decimal(str(x if x is not None else 0)).quantize(CENT, rounding=ROUND_HALF_UP)
    except InvalidOperation:
        d = Decimal("0.00")
    return f"{d}".replace(".", ",") + " €"


def csv_cell(v: Any) -> str:
    """Ячейка CSV. Строки, начинающиеся с = + - @ (и управляющих символов), экранируются апострофом:
    иначе Excel/Sheets выполнит их как формулу (CSV-инъекция). Числа не трогаем."""
    if v is None:
        s = ""
    elif isinstance(v, bool):
        s = "true" if v else "false"
    elif isinstance(v, (int, float, Decimal)):
        s = str(v)
    else:
        s = str(v)
        if s.startswith(_FORMULA_PREFIX):
            s = "'" + s
    return '"' + s.replace('"', '""') + '"'


def csv_text(rows: Iterable[dict], header: list) -> str:
    return "\n".join([",".join(header)] + [",".join(csv_cell(r.get(h)) for h in header) for r in rows])


def dedupe(*parts: Any) -> str:
    """Ключ дедупликации для outbox: 'order_admin:<order>:created:<chat>'."""
    return ":".join(str(p) for p in parts)[:200]
