"""Минимальные заглушки fastapi / pydantic / aiogram / httpx для запуска логики backend БЕЗ установки зависимостей.

Что это даёт: можно импортировать main.py и вызывать функции эндпоинтов напрямую с поддельными rpc()/db().
Чего это НЕ даёт: валидацию Pydantic (ge/le/min_length, decimal_places), маршрутизацию и HTTP-слой FastAPI.
Эти проверки остаются за настоящими тестами (backend/tests/, pytest + TestClient) — запускайте их у себя.
"""
import os, sys, types, asyncio

REQUIRED = object()


def _mod(name, **attrs):
    m = types.ModuleType(name)
    m.__dict__.update(attrs)
    sys.modules[name] = m
    return m


# ----------------------------------------------------------------- pydantic
def Field(default=REQUIRED, **kw):
    if "default_factory" in kw:
        return kw["default_factory"]()
    return default


class BaseModel:
    def __init__(self, **kw):
        ann = {}
        for klass in reversed(type(self).__mro__):
            ann.update(getattr(klass, "__annotations__", {}))
        for name in ann:
            if name in kw:
                val = kw[name]
            elif hasattr(type(self), name) and getattr(type(self), name) is not REQUIRED:
                val = getattr(type(self), name)
            else:
                raise TypeError(f"{type(self).__name__}: нет обязательного поля {name}")
            setattr(self, name, val)
        self.model_fields_set = set(kw)

    def model_dump(self, exclude_unset=False):
        names = [n for n in self.__dict__ if n != "model_fields_set"]
        return {n: self.__dict__[n] for n in names if not exclude_unset or n in self.model_fields_set}


_mod("pydantic", BaseModel=BaseModel, Field=Field)


# ----------------------------------------------------------------- fastapi
class HTTPException(Exception):
    def __init__(self, status_code, detail=None):
        super().__init__(f"{status_code}: {detail}")
        self.status_code, self.detail = status_code, detail


class FastAPI:
    ROUTES = []   # (method, path, function)

    def __init__(self, *a, **kw): pass
    def add_middleware(self, *a, **kw): pass

    def _reg(self, method):
        def deco_factory(path, **kw):
            def deco(fn):
                FastAPI.ROUTES.append((method, path, fn))
                return fn
            return deco
        return deco_factory

    def __getattr__(self, name):
        if name in ("get", "post", "put", "patch", "delete"):
            return self._reg(name.upper())
        raise AttributeError(name)


class PlainTextResponse:
    def __init__(self, content="", media_type=None, **kw):
        self.body, self.media_type = content, media_type


_mod("fastapi", FastAPI=FastAPI, Request=object, HTTPException=HTTPException, Depends=lambda fn=None: ("depends", fn),
     Header=lambda default="": default, Query=lambda default=None, **kw: default)
_mod("fastapi.middleware")
_mod("fastapi.middleware.cors", CORSMiddleware=object)
_mod("fastapi.responses", PlainTextResponse=PlainTextResponse)


# ----------------------------------------------------------------- aiogram
class _Magic:
    def __getattr__(self, n): return _Magic()
    def __call__(self, *a, **kw): return _Magic()


class _Router:
    def message(self, *a, **kw): return lambda fn: fn
    def callback_query(self, *a, **kw): return lambda fn: fn


class _Bot:
    def __init__(self, *a, **kw): self.sent = []
    async def send_message(self, chat_id, text, reply_markup=None):
        self.sent.append((chat_id, text)); return None
    async def set_webhook(self, *a, **kw): return None
    class session:
        @staticmethod
        async def close(): return None


class _Dispatcher:
    def include_router(self, r): pass


class TelegramForbiddenError(Exception): pass


class TelegramRetryAfter(Exception):
    def __init__(self, retry_after=1): self.retry_after = retry_after


class _Btn:
    def __init__(self, **kw): self.__dict__.update(kw)


_mod("aiogram", Bot=_Bot, Dispatcher=_Dispatcher, Router=_Router, F=_Magic())
_mod("aiogram.client")
_mod("aiogram.client.default", DefaultBotProperties=lambda **kw: None)
_mod("aiogram.filters", CommandStart=lambda *a, **kw: None)
_mod("aiogram.exceptions", TelegramForbiddenError=TelegramForbiddenError, TelegramRetryAfter=TelegramRetryAfter)
_mod("aiogram.types", Update=object, InlineKeyboardMarkup=_Btn, InlineKeyboardButton=_Btn, CallbackQuery=object, Message=object, WebAppInfo=_Btn)


# ----------------------------------------------------------------- httpx
class _AsyncClient:
    def __init__(self, *a, **kw): pass
    async def request(self, *a, **kw): raise RuntimeError("сеть недоступна в offline-тестах")
    async def aclose(self): return None


_mod("httpx", AsyncClient=_AsyncClient)

# ----------------------------------------------------------------- окружение и импорт main
os.environ.setdefault("BOT_TOKEN", "123:TEST")
os.environ.setdefault("SUPABASE_URL", "http://supabase.invalid")
os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "service-key-test")
os.environ.setdefault("WEBAPP_URL", "http://webapp.invalid")
os.environ.setdefault("OWNER_TELEGRAM_ID", "1")

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import main  # noqa: E402

__all__ = ["main", "HTTPException", "FastAPI", "PlainTextResponse"]
