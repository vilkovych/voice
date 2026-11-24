#!/usr/bin/env python3
"""Earworm: переклад рядків українською через Google Translate (без ключа, бібліотека deep-translator).
Перекладає лише неперекладене; рядки однієї порції йдуть одним запитом, розділені переносом."""
import glob, json, os, time
from deep_translator import GoogleTranslator

ROOT = os.path.dirname(os.path.abspath(__file__))
APP = os.path.join(ROOT, "app")
tr = GoogleTranslator(source="en", target="uk")


def chunks(idx, lines, limit=4000):
    part, size = [], 0
    for i in idx:
        n = len(lines[i]["en"]) + 1
        if part and (size + n > limit or len(part) >= 60):
            yield part
            part, size = [], 0
        part.append(i)
        size += n
    if part:
        yield part


def one(text):
    for _ in range(3):
        try:
            return tr.translate(text)
        except Exception:
            time.sleep(2)
    return None


for path in sorted(glob.glob(os.path.join(APP, "lessons", "*.json"))):
    les = json.load(open(path, encoding="utf-8"))
    lines = les["lines"]
    todo = [i for i, l in enumerate(lines) if not l.get("uk")]
    if not todo:
        continue
    print(f"→ {les['id']}: {len(todo)} рядків", flush=True)
    for part in chunks(todo, lines):
        out = one("\n".join(lines[i]["en"] for i in part))
        got = out.split("\n") if out else []
        if len(got) == len(part):
            for i, t in zip(part, got):
                lines[i]["uk"] = t.strip()
        else:
            for i in part:
                t = one(lines[i]["en"])
                if t:
                    lines[i]["uk"] = t.strip()
        time.sleep(0.5)
    json.dump(les, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)

cat_path = os.path.join(APP, "catalog.json")
if os.path.exists(cat_path):
    cat = json.load(open(cat_path, encoding="utf-8"))
    for c in cat:
        p = os.path.join(APP, "lessons", c["id"] + ".json")
        if os.path.exists(p):
            c["uk"] = sum(1 for l in json.load(open(p, encoding="utf-8"))["lines"] if l.get("uk"))
    json.dump(cat, open(cat_path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print("Переклад готовий.")
