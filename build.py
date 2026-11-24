#!/usr/bin/env python3
"""Earworm: збирає уроки з каталогу seed.json.

Для кожного пункту:
  пісня  -> текст із часом з lrclib.net + відео на YouTube тієї ж довжини (щоб текст збігався з музикою);
  решта  -> відео на YouTube + англійські субтитри (ручні, а якщо їх нема — автоматичні), склеєні в речення.
Пише app/lessons/<id>.json і app/catalog.json. Звіт про невдалі пункти — build-report.txt.

  python3 build.py            # зібрати все, що ще не зібрано
  python3 build.py --only id  # перезібрати один пункт (після правки запиту в seed.json)
  python3 build.py --force    # перезібрати все
Потрібно: python3, свіжий yt-dlp (pip install -U yt-dlp).
"""
import glob, json, os, re, subprocess, sys, tempfile, urllib.parse, urllib.request

ROOT = os.path.dirname(os.path.abspath(__file__))
APP = os.path.join(ROOT, "app")
LES = os.path.join(APP, "lessons")
UA = "Earworm/1.0 (personal English learning app)"
MAX_LINES = {"song": 400, "scene": 120, "talk": 160, "crime": 160}
DUR = {"scene": (30, 1200), "talk": (180, 3600), "crime": (180, 4800)}


def get_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def ytdlp(args, timeout=180):
    r = subprocess.run(["yt-dlp", *args], capture_output=True, text=True, timeout=timeout)
    if r.returncode:
        raise RuntimeError("yt-dlp: " + (r.stderr.strip().splitlines() or ["?"])[-1][:300])
    return r.stdout


def yt_search(q, n=8):
    data = json.loads(ytdlp(["--flat-playlist", "-J", f"ytsearch{n}:{q}"]))
    return [e for e in data.get("entries", []) if e and e.get("id")]


def video_info(vid):
    try:
        return json.loads(ytdlp(["-J", "--skip-download", "--no-warnings", f"https://www.youtube.com/watch?v={vid}"]))
    except Exception:
        return None


def embeddable(vid):
    """False лише коли YouTube прямо каже, що вбудовувати не можна; якщо перевірка не вдалась — пробуємо."""
    info = video_info(vid)
    if not info:
        return True
    return info.get("playable_in_embed", True) is not False and info.get("availability") in (None, "public", "unlisted")


def parse_lrc(text):
    rows = []
    for line in text.splitlines():
        tags = re.findall(r"\[(\d+):(\d+(?:\.\d+)?)\]", line)
        words = re.sub(r"\[[^\]]*\]", "", line).strip()
        for m, s in tags:
            rows.append((int(m) * 60 + float(s), words))
    rows.sort(key=lambda x: x[0])
    out = []
    for i, (t, words) in enumerate(rows):
        nxt = rows[i + 1][0] if i + 1 < len(rows) else t + 6
        if words and re.search(r"[A-Za-z]{2}", words):
            out.append({"t0": round(t, 2), "t1": round(min(nxt, t + 10), 2), "en": words, "uk": None})
    return out


def parse_json3(data):
    """Субтитри YouTube (json3) -> рядки-речення з часом."""
    words = []
    for ev in data.get("events", []):
        segs = ev.get("segs")
        if not segs:
            continue
        t, d = ev.get("tStartMs", 0), ev.get("dDurationMs", 0)
        toks = [(s.get("utf8", ""), s.get("tOffsetMs")) for s in segs if s.get("utf8", "").strip()]
        if not toks:
            continue
        if any(o is not None for _, o in toks[1:]):
            for x, o in toks:
                for w in x.split():
                    words.append(((t + (o or 0)) / 1000, w))
        else:
            ws = " ".join(x for x, _ in toks).split()
            for i, w in enumerate(ws):
                words.append(((t + d * i / max(1, len(ws))) / 1000, w))
    words.sort(key=lambda x: x[0])
    lines, cur = [], []

    def flush(end):
        if not cur:
            return
        en = " ".join(w for _, w in cur)
        en = re.sub(r"\[[^\]]*\]|\([^)]*\)|♪|>>", " ", en)
        en = re.sub(r"\s+", " ", en).strip(" -")
        if re.search(r"[A-Za-z]{2}", en) and len(en.split()) >= 2:
            lines.append({"t0": round(cur[0][0], 2), "t1": round(end, 2), "en": en, "uk": None})
        cur.clear()

    for i, (t, w) in enumerate(words):
        if cur and (t - cur[-1][0] > 1.3 or len(cur) >= 14):
            flush(min(t, cur[-1][0] + 0.8))
        cur.append((t, w))
        nxt = words[i + 1][0] if i + 1 < len(words) else t + 1
        if re.search(r"[.?!][\"')\]]*$", w) and len(cur) >= 3:
            flush(min(nxt, t + 1.0))
    if cur:
        flush(cur[-1][0] + 0.9)
    return lines


def subtitles(vid):
    with tempfile.TemporaryDirectory() as d:
        try:
            ytdlp(["--skip-download", "--no-warnings", "--write-subs", "--write-auto-subs",
                   "--sub-langs", "en,en-US,en-GB,en-orig", "--sub-format", "json3",
                   "-o", os.path.join(d, "%(id)s.%(ext)s"), f"https://www.youtube.com/watch?v={vid}"])
        except RuntimeError:
            pass
        files = sorted(glob.glob(os.path.join(d, "*.json3")),
                       key=lambda p: (0 if re.search(r"\.en(-US|-GB)?\.json3$", p) else 1))
        for f in files:
            try:
                lines = parse_json3(json.load(open(f, encoding="utf-8")))
            except Exception:
                continue
            if len(lines) >= 4:
                return lines
    return None


def build_song(item):
    q = urllib.parse.urlencode({"track_name": item["title"], "artist_name": item["artist"]})
    found = [r for r in get_json("https://lrclib.net/api/search?" + q)
             if r.get("syncedLyrics") and not r.get("instrumental")]
    if not found:
        raise RuntimeError("lrclib: нема тексту з часом")
    tried = set()
    for rec in found[:4]:
        dur = rec.get("duration") or 0
        for query in (f"{item['artist']} {item['title']} official audio", f"{item['artist']} {item['title']}"):
            for e in yt_search(query):
                if e["id"] in tried or not e.get("duration") or abs(e["duration"] - dur) > 3:
                    continue
                tried.add(e["id"])
                if embeddable(e["id"]):
                    return e, parse_lrc(rec["syncedLyrics"])
    raise RuntimeError("не знайшов відео, яке за довжиною збігається з текстом")


def build_video(item):
    lo, hi = DUR[item["kind"]]
    for e in yt_search(item["query"]):
        dur = e.get("duration") or 0
        if dur and not lo <= dur <= hi:
            continue
        if not embeddable(e["id"]):
            continue
        lines = subtitles(e["id"])
        if lines:
            return e, lines
    raise RuntimeError("не знайшов відео з англійськими субтитрами, яке можна вбудувати")


def main():
    args = sys.argv[1:]
    only = args[args.index("--only") + 1] if "--only" in args else None
    force = "--force" in args
    os.makedirs(LES, exist_ok=True)
    seed = json.load(open(os.path.join(ROOT, "seed.json"), encoding="utf-8"))
    report = []
    for item in seed:
        path = os.path.join(LES, item["id"] + ".json")
        if only and item["id"] != only:
            continue
        if os.path.exists(path) and not (force or only):
            continue
        print(f"→ {item['id']} …", flush=True)
        try:
            e, lines = build_song(item) if item["kind"] == "song" else build_video(item)
            lines = lines[:MAX_LINES[item["kind"]]]
            json.dump({"id": item["id"], "videoId": e["id"], "videoTitle": e.get("title"),
                       "channel": e.get("channel") or e.get("uploader"), "lines": lines},
                      open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
            print(f"   ок: {len(lines)} рядків · «{e.get('title')}» ({e.get('channel') or e.get('uploader')})")
        except Exception as ex:
            report.append(f"{item['id']}: {ex}")
            print(f"   ПРОВАЛ: {ex}")
    catalog = []
    for item in seed:
        path = os.path.join(LES, item["id"] + ".json")
        if not os.path.exists(path):
            continue
        les = json.load(open(path, encoding="utf-8"))
        catalog.append({"id": item["id"], "kind": item["kind"], "title": item["title"],
                        "artist": item.get("artist"), "why": item.get("why"), "videoId": les["videoId"],
                        "n": len(les["lines"]), "uk": sum(1 for l in les["lines"] if l.get("uk"))})
    json.dump(catalog, open(os.path.join(APP, "catalog.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    open(os.path.join(ROOT, "build-report.txt"), "w", encoding="utf-8").write("\n".join(report) + "\n")
    print(f"\nГотово: у каталозі {len(catalog)} уроків, провалів {len(report)} (див. build-report.txt)")


if __name__ == "__main__":
    main()
