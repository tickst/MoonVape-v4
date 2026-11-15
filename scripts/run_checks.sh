#!/usr/bin/env bash
# Проверки, которые не требуют PostgreSQL, сети и установленных зависимостей.
# Это НЕ замена: pytest (backend/tests), SQL-тесты (supabase/tests_v6.sql) и `npm run build` нужно запускать у себя.
set -u
cd "$(dirname "$0")/.."
fail=0
step() { echo; echo "=== $1"; shift; "$@" || { echo "!!! ПРОВАЛ: $*"; fail=1; }; }

step "SQL: статический анализ миграций (скобки, арность функций, колонки, RLS)" python3 scripts/check_sql.py
step "Python: компиляция backend" python3 -m py_compile backend/main.py backend/helpers.py
step "Python: offline-тесты backend (на заглушках зависимостей)" bash -c 'cd backend && python3 -m unittest discover -s tests_offline'
if command -v node >/dev/null 2>&1; then
  step "TypeScript/Node: тесты lib (деньги, периоды)" bash -c 'cd frontend && node --experimental-strip-types --test lib/lib.test.ts 2>&1 | tail -12'
else echo "node не найден — пропуск тестов lib"; fi
echo; [ $fail -eq 0 ] && echo "ВСЕ ДОСТУПНЫЕ ПРОВЕРКИ ПРОЙДЕНЫ" || echo "ЕСТЬ ПРОВАЛЫ"
exit $fail
