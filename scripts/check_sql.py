#!/usr/bin/env python3
"""Статическая проверка SQL-миграций MoonVape (без PostgreSQL).

ЭТО НЕ ЗАМЕНА ЗАПУСКУ НА БАЗЕ. Проверяет только то, что можно проверить текстом:
  1. баланс $$-блоков и круглых скобок в каждом файле;
  2. каждая вызываемая функция проекта существует, и число аргументов подходит хотя бы под одну сигнатуру
     (учитываются значения по умолчанию);
  3. колонки в `insert into T(...)` и `update T set col = ...` существуют в таблице T
     (таблицы и колонки собираются из schema.sql и всех миграций по порядку);
  4. порядок миграций: каждая начинается проверкой предыдущей версии и заканчивается записью своей;
  5. новые таблицы получают `enable row level security`.
Запуск: python3 scripts/check_sql.py
"""
import glob, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SQL_FILES = [os.path.join(ROOT, 'supabase', 'schema.sql')] + sorted(glob.glob(os.path.join(ROOT, 'supabase', 'migrations', '0*.sql')))

errors, warnings = [], []


def strip_comments(s):
    s = re.sub(r'/\*.*?\*/', '', s, flags=re.S)
    return re.sub(r'--[^\n]*', '', s)


def mask_strings(s):
    """Заменяет содержимое '...' пробелами (длина сохраняется), чтобы скобки/запятые в строках не мешали."""
    out, i, n = [], 0, len(s)
    while i < n:
        c = s[i]
        if c == "'":
            j = i + 1
            while j < n:
                if s[j] == "'" and j + 1 < n and s[j + 1] == "'":
                    j += 2
                    continue
                if s[j] == "'":
                    break
                j += 1
            out.append("'" + ' ' * (j - i - 1) + "'")
            i = j + 1
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def split_top(s, sep=','):
    parts, depth, cur = [], 0, []
    for ch in s:
        if ch in '([{':
            depth += 1
        elif ch in ')]}':
            depth -= 1
        if ch == sep and depth == 0:
            parts.append(''.join(cur)); cur = []
        else:
            cur.append(ch)
    parts.append(''.join(cur))
    return parts


def match_paren(s, i):
    depth = 0
    for j in range(i, len(s)):
        if s[j] == '(':
            depth += 1
        elif s[j] == ')':
            depth -= 1
            if depth == 0:
                return j
    return -1


# ----------------------------------------------------------------- сбор схемы и функций
tables = {}      # имя -> set(колонок)
functions = {}   # имя -> set((min_args, max_args))
CONSTRAINT_WORDS = ('primary', 'unique', 'check', 'foreign', 'constraint', 'exclude')
file_text = {}

for path in SQL_FILES:
    raw = open(path, encoding='utf-8').read()
    file_text[path] = raw
    s = mask_strings(strip_comments(raw))
    for m in re.finditer(r'create\s+table\s+(?:if\s+not\s+exists\s+)?(?:public\.)?([a-z_][a-z0-9_]*)\s*\(', s, re.I):
        name = m.group(1).lower()
        end = match_paren(s, m.end() - 1)
        body = s[m.end():end]
        cols = tables.setdefault(name, set())
        for seg in split_top(body):
            seg = seg.strip()
            if not seg:
                continue
            w = re.match(r'([a-z_][a-z0-9_]*)', seg, re.I)
            if w and w.group(1).lower() not in CONSTRAINT_WORDS:
                cols.add(w.group(1).lower())
    for m in re.finditer(r'alter\s+table\s+(?:only\s+)?(?:public\.)?([a-z_][a-z0-9_]*)\s+add\s+column\s+(?:if\s+not\s+exists\s+)?([a-z_][a-z0-9_]*)', s, re.I):
        tables.setdefault(m.group(1).lower(), set()).add(m.group(2).lower())


def apply_functions(s):
    """Применяет create/drop function из текста файла к текущему состоянию `functions` по порядку."""
    events = []
    for m in re.finditer(r'create\s+(?:or\s+replace\s+)?function\s+([a-z_][a-z0-9_]*)\s*\(', s, re.I):
        name = m.group(1).lower()
        end = match_paren(s, m.end() - 1)
        args = [a.strip() for a in split_top(s[m.end():end]) if a.strip()]
        mn = sum(1 for a in args if not re.search(r'\bdefault\b|=', a, re.I))
        events.append((m.start(), 'c', name, (mn, len(args))))
    for m in re.finditer(r'drop\s+function\s+(?:if\s+exists\s+)?([a-z_][a-z0-9_]*)\s*\(([^)]*)\)', s, re.I):
        n = len([a for a in m.group(2).split(',') if a.strip()])
        events.append((m.start(), 'd', m.group(1).lower(), (n, n)))
    for _, kind, name, sig in sorted(events):
        if kind == 'c':
            functions.setdefault(name, set()).add(sig)
        elif name in functions:
            functions[name] = {x for x in functions[name] if x[1] != sig[1]}

# ----------------------------------------------------------------- проверки по файлам
KW_NOT_FUNC = set('''if in not and or is null from where select values into set returning using on as exists any all array
case when then else end filter over by order group limit offset join left right inner outer cross lateral union interval
primary unique check references default constraint key table index create replace function returns language begin declare
loop for while raise exception perform insert update delete with recursive distinct count sum min max coalesce nullif
greatest least round trunc now abs length trim lower upper left right substr replace jsonb_build_object jsonb_agg
jsonb_array_elements jsonb_array_length jsonb_typeof jsonb_set to_jsonb to_char make_interval row_number regexp_replace
format hashtext gen_random_uuid nextval random floor lpad split_part string_agg unnest generate_series pg_advisory_xact_lock
count_distinct bool_or bool_and avg cast extract date_trunc current_date current_timestamp pg_get_constraintdef
row_to_json json_build_object to_date to_timestamp md5 encode digest'''.split())

for path in SQL_FILES:
    name = os.path.basename(path)
    raw = file_text[path]
    s = mask_strings(strip_comments(raw))
    apply_functions(s)
    if s.count('$$') % 2:
        errors.append(f'{name}: нечётное число $$')
    if s.count('(') != s.count(')'):
        errors.append(f'{name}: скобки не сбалансированы ({s.count("(")} ( против {s.count(")")} ) )')
    if not name.startswith('0'):
        continue
    ver = name[:4]
    if ver >= '0019':
        prev = '%04d' % (int(ver) - 1)
        if f"version='{prev}'" not in raw.replace(' ', ''):
            errors.append(f'{name}: нет проверки предыдущей миграции {prev}')
        if not re.search(r"insert\s+into\s+schema_migrations\(version\)\s+values\('%s'\)" % ver, raw):
            errors.append(f'{name}: нет записи в schema_migrations')
        if 'revoke execute on all functions' not in raw:
            warnings.append(f'{name}: нет revoke execute on all functions')

    # новые таблицы -> RLS
    for m in re.finditer(r'create\s+table\s+(?:if\s+not\s+exists\s+)?([a-z_][a-z0-9_]*)', s, re.I):
        t = m.group(1).lower()
        if ver >= '0019' and not re.search(r'alter\s+table\s+%s\s+enable\s+row\s+level\s+security' % t, s, re.I):
            errors.append(f'{name}: у таблицы {t} не включён RLS')

    # insert into T(cols)
    for m in re.finditer(r'insert\s+into\s+([a-z_][a-z0-9_]*)\s*\(([^)]*)\)', s, re.I):
        t = m.group(1).lower()
        if t not in tables:
            continue
        for c in [x.strip().lower() for x in m.group(2).split(',') if x.strip()]:
            if c not in tables[t]:
                line = s[:m.start()].count('\n') + 1
                errors.append(f'{name}:{line}: insert into {t}: нет колонки {c}')
    # update T set a=..., b=...
    for m in re.finditer(r'update\s+([a-z_][a-z0-9_]*)\s+set\s+', s, re.I):
        t = m.group(1).lower()
        if t not in tables:
            continue
        rest = s[m.end():]
        stop = re.search(r'\bwhere\b|\bfrom\b|\breturning\b|;', rest, re.I)
        clause = rest[:stop.start()] if stop else rest
        for seg in split_top(clause):
            cm = re.match(r'\s*([a-z_][a-z0-9_]*)\s*=', seg, re.I)
            if cm and cm.group(1).lower() not in tables[t]:
                line = s[:m.start()].count('\n') + 1
                errors.append(f'{name}:{line}: update {t}: нет колонки {cm.group(1)}')

    # вызовы функций проекта (DROP FUNCTION / GRANT / REVOKE содержат сигнатуры типов — это не вызовы)
    s = re.sub(r'(drop\s+function|revoke\s+execute|grant\s+execute)[^;]*;', lambda mm: re.sub(r'[^\n]', ' ', mm.group(0)), s, flags=re.I)
    for m in re.finditer(r'(?<![\w.])([a-z_][a-z0-9_]*)\s*\(', s, re.I):
        fn = m.group(1).lower()
        if fn in KW_NOT_FUNC or fn not in functions:
            continue
        before = s[max(0, m.start() - 40):m.start()].lower()
        if re.search(r'(function|table|into)\s+$', before):   # определение / insert into T(
            continue
        if re.search(r'(drop\s+function(\s+if\s+exists)?|on\s+function|,)\s+$', before) and re.search(r'(revoke|grant|drop)', s[max(0, m.start() - 400):m.start()], re.I) and not re.search(r';', s[max(0, m.start() - 80):m.start()]):
            continue
        end = match_paren(s, m.end() - 1)
        if end < 0:
            continue
        inner = s[m.end():end].strip()
        n = 0 if not inner else len(split_top(inner))
        if not any(mn <= n <= mx for mn, mx in functions[fn]):
            line = s[:m.start()].count('\n') + 1
            errors.append(f'{name}:{line}: вызов {fn}() с {n} арг., сигнатуры: {sorted(functions[fn])}')

print(f'Проверено файлов: {len(SQL_FILES)}; таблиц: {len(tables)}; функций: {len(functions)}')
for w in warnings:
    print('WARN ', w)
for e in errors:
    print('ERROR', e)
print('ИТОГО: ошибок %d, предупреждений %d' % (len(errors), len(warnings)))
sys.exit(1 if errors else 0)
