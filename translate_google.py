#!/usr/bin/env python3
"""Earworm: переклад рядків українською через Google Translate (без ключа).
Кожен запит має обмеження часу; після 5 провалів поспіль переклад зупиняється (решту добере наступна збірка).
Зберігає після кожної порції."""
import glob, json, os, sys, time, urllib.parse, urllib.request

ROOT = os.path.dirname(os.path.abspath(__file__))
APP = os.path.join(ROOT, "app")
DEADLINE = time.time() + float(os.environ.get("EARWORM_TR_MINUTES", "25")) * 60
fails = 0


def gtx(text):
    data = urllib.parse.urlencode({"q": text}).encode()
    url = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=en&tl=uk&dt=t"
    req = urllib.request.Request(url, data=data, headers={"User-Agent": "Mozilla/5.0", "Content-Type": "application/x-www-form-urlencoded;charset=utf-8"})
    with urllib.request.urlopen(req, timeout=20) as r:
        js = json.load(r)
    return "".join(seg[0] for seg in js[0] if seg and seg[0])


def safe(text):
    global fails
    for _ in range(2):
        try:
            out = gtx(text)
            fails = 0
            return out
        except Exception as ex:
            print("   помилка запиту:", str(ex)[:120], flush=True)
            time.sleep(3)
    fails += 1
    return None


def chunks(idx, lines, limit=3500):
    part, size = [], 0
    for i in idx:
        n = len(lines[i]["en"]) + 1
        if part and (size + n > limit or len(part) >= 50):
            yield part
            part, size = [], 0
        part.append(i)
        size += n
    if part:
        yield part


stop = False
for path in sorted(glob.glob(os.path.join(APP, "lessons", "*.json"))):
    if stop:
        break
    les = json.load(open(path, encoding="utf-8"))
    lines = les["lines"]
    todo = [i for i, l in enumerate(lines) if not l.get("uk")]
    if not todo:
        continue
    print(f"→ {les['id']}: {len(todo)} рядків", flush=True)
    for part in chunks(todo, lines):
        if fails >= 5 or time.time() > DEADLINE:
            print("Зупиняю переклад: забагато помилок або вийшов час. Решту доберу наступного разу.", flush=True)
            stop = True
            break
        out = safe("\n".join(lines[i]["en"] for i in part))
        got = [g.strip() for g in out.split("\n")] if out else []
        if len(got) == len(part):
            for i, t in zip(part, got):
                lines[i]["uk"] = t
        elif out is not None:
            for i in part:
                t = safe(lines[i]["en"])
                if t:
                    lines[i]["uk"] = t.strip()
        json.dump(les, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
        time.sleep(0.4)
    done = sum(1 for l in lines if l.get("uk"))
    print(f"   перекладено {done}/{len(lines)}", flush=True)

cat_path = os.path.join(APP, "catalog.json")
if os.path.exists(cat_path):
    cat = json.load(open(cat_path, encoding="utf-8"))
    for c in cat:
        p = os.path.join(APP, "lessons", c["id"] + ".json")
        if os.path.exists(p):
            c["uk"] = sum(1 for l in json.load(open(p, encoding="utf-8"))["lines"] if l.get("uk"))
    json.dump(cat, open(cat_path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print("Переклад: крок завершено.")
