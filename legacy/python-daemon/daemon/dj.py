"""DJ 選曲腦：把自由文字的 vibe 變成一份加權曲目清單。純規則、不燒 token。"""
import math, random, re, time
from collections import defaultdict

# vibe 關鍵字 → 曲風權重。中英並列，比對時用子字串。
LEXICON: list[tuple[tuple[str, ...], dict[str, float]]] = [
    (("專注", "工作", "寫程式", "coding", "focus", "deep work", "讀書", "看書"),
     {"Classical": 3.0, "New Age": 2.6, "Ambient": 2.6, "Piano": 2.4,
      "Smooth Jazz": 2.0, "Classical Crossover": 1.8, "Soundtrack": 1.6, "原聲帶": 1.6,
      "J-Pop": -1.2, "Rock": -2.0, "Mandopop": -1.2, "Anime": -1.5}),
    (("深夜", "夜晚", "凌晨", "night", "late", "睡前", "sleep", "失眠"),
     {"New Age": 2.8, "Ambient": 2.8, "Classical": 2.4, "Piano": 2.4,
      "Smooth Jazz": 2.2, "Bossa Nova": 1.8, "Rock": -2.5, "Anime": -1.5}),
    (("早晨", "早上", "morning", "咖啡", "coffee", "起床", "brunch"),
     {"Bossa Nova": 2.6, "Smooth Jazz": 2.2, "Classical Crossover": 1.8,
      "J-Pop": 1.2, "New Age": 1.2, "Reggae": 1.0, "Rock": -1.0}),
    (("放鬆", "chill", "relax", "耍廢", "慵懶", "下午"),
     {"Reggae": 2.4, "Bossa Nova": 2.2, "New Age": 2.0, "Smooth Jazz": 2.0,
      "Ambient": 1.6, "R&B/Soul": 1.4, "Rock": -1.2}),
    (("開心", "振奮", "有活力", "happy", "energetic", "運動", "workout", "通勤", "開車"),
     {"J-Pop": 2.2, "Rock": 2.2, "Pop": 2.0, "R&B/Soul": 1.8, "Reggae": 1.4,
      "Classical": -2.0, "New Age": -2.2, "Ambient": -2.2}),
    (("失戀", "傷心", "難過", "sad", "emo", "療傷", "哭"),
     {"Mandopop": 2.6, "J-Pop": 1.2, "Classical": 1.0, "Piano": 1.2,
      "Rock": -1.0, "Reggae": -1.5}),
    (("懷舊", "老歌", "nostalgia", "回憶", "以前"),
     {"Mandopop": 2.4, "Cantopop/HK-Pop": 1.8, "Chinese": 1.6, "Pop": 1.0}),
    (("日文", "日本", "jpop", "j-pop", "日語", "日劇"),
     {"J-Pop": 3.0, "Anime": 1.6, "Worldwide": 0.8, "Mandopop": -2.0}),
    (("華語", "中文", "國語", "mandopop", "台語"),
     {"Mandopop": 3.0, "Chinese": 2.0, "Cantopop/HK-Pop": 1.6, "J-Pop": -2.0}),
    (("古典", "classical", "鋼琴", "piano", "交響", "室內樂"),
     {"Classical": 3.2, "Piano": 3.0, "Classical Crossover": 2.4, "Opera": 1.2,
      "J-Pop": -2.0, "Rock": -2.5, "Reggae": -2.5}),
    (("抒情", "柔和", "舒緩", "溫柔", "慢板", "背景音樂", "bgm", "lyrical",
      "mellow", "soft", "gentle", "calm", "ballad", "不吵", "安靜"),
     {"New Age": 2.8, "Piano": 2.8, "Ambient": 2.4, "Classical": 2.0,
      "Classical Crossover": 2.0, "Smooth Jazz": 2.0, "Soundtrack": 1.4,
      "Rock": -3.0, "Reggae": -2.0, "Pop": -1.5, "Anime": -1.5}),
    (("爵士", "jazz", "bossa", "微醺", "小酒館"),
     {"Smooth Jazz": 3.0, "Jazz": 3.0, "Bossa Nova": 2.6, "R&B/Soul": 1.4}),
    (("雷鬼", "reggae", "夏天", "summer", "海邊", "度假"),
     {"Reggae": 3.2, "Bossa Nova": 2.0, "Worldwide": 1.4}),
    (("電影", "配樂", "soundtrack", "史詩", "動畫"),
     {"Soundtrack": 2.8, "原聲帶": 2.8, "Anime": 2.0, "Classical Crossover": 1.4}),
    (("r&b", "soul", "節奏藍調"),
     {"R&B/Soul": 3.0, "Smooth Jazz": 1.4, "Pop": 1.0}),
    (("搖滾", "rock", "熱血"),
     {"Rock": 3.0, "J-Pop": 1.2, "Pop": 1.0, "New Age": -2.0, "Ambient": -2.0}),
]

# 曲風別名：資料庫裡中英文並存
GENRE_ALIAS = {"原聲帶": "Soundtrack"}

CJK = re.compile(r"[一-鿿぀-ヿ]")

# 節慶曲：除非 vibe 明講，否則平常不該冒出來
SEASONAL = ("christmas", "xmas", "聖誕", "クリスマス", "santa", "jingle bell",
            "holy night", "winter wonderland", "新年", "賀歲")
SEASONAL_ASK = ("聖誕", "christmas", "xmas", "耶誕", "節慶", "過年", "新年", "賀歲")

# 否定式：「不要有人聲」「別放搖滾」「no rock」
NEGATION = ("不要", "不想", "別放", "別來", "避開", "沒有", "無", "not ", "no ", "without ")

INSTRUMENTAL_HINT = ("人聲", "vocal", "純音樂", "instrumental", "演奏", "bgm", "純樂器")

# 古典／演奏曲的曲名幾乎都標著速度與體裁，拿來當「這首吵不吵」的代理指標。
# 這是規則式選曲唯一能看出「同一曲風裡性格差很多」的地方。
TEMPO_FAST = ("allegro", "presto", "vivace", "vivo", "con brio", "schnell",
              "galopp", "galop", "polka", "marsch", "march", "スケルツォ",
              "scherzo", "furioso", "agitato", "tarantella", "rondo", "finale",
              "stürmisch", "energico", "molto mosso")
TEMPO_SLOW = ("adagio", "andante", "largo", "larghetto", "lento", "grave",
              "sostenuto", "cantabile", "sarabande", "nocturne", "notturno",
              "prélude", "prelude", "berceuse", "romance", "reverie", "rêverie",
              "träumerei", "elegy", "élégie", "aria", "air ", "pastorale",
              "barcarolle", "intermezzo", "siciliana", "lullaby", "serenade",
              "ave maria", "meditation", "méditation")

# 哪些 vibe 屬於「要安靜」
CALM_HINT = ("抒情", "柔和", "舒緩", "溫柔", "慢板", "背景", "bgm", "安靜", "不吵",
             "專注", "寫程式", "深夜", "睡前", "放鬆", "讀書", "看書", "chill",
             "calm", "focus", "relax", "sleep", "mellow", "soft", "gentle")
ENERGY_HINT = ("振奮", "有活力", "熱血", "運動", "workout", "energetic", "開心",
               "派對", "party", "通勤", "開車")


def _tokens(s: str) -> list[str]:
    """中文抽 2-gram、英文抽單字，讓 vibe 能跟清單/藝人名做模糊比對。"""
    s = s.lower()
    toks = re.findall(r"[a-z0-9']+", s)
    cjk = "".join(CJK.findall(s))
    toks += [cjk[i:i + 2] for i in range(len(cjk) - 1)]
    return [t for t in toks if len(t) >= 2]


def _negated_spans(v: str) -> list[str]:
    """抓出否定詞之後那一小段文字，這些內容要反向計分。"""
    spans = []
    for neg in NEGATION:
        i = 0
        while (i := v.find(neg, i)) != -1:
            spans.append(v[i + len(neg): i + len(neg) + 12])
            i += len(neg)
    return spans


def genre_weights(vibe: str) -> dict[str, float]:
    v = vibe.lower()
    negs = _negated_spans(v)
    w: dict[str, float] = defaultdict(float)
    for keys, weights in LEXICON:
        hit = any(k in v for k in keys)
        if not hit:
            continue
        # 命中的關鍵字若落在否定片語裡，整組權重反向
        sign = -0.8 if any(k in n for k in keys for n in negs) else 1.0
        for g, sc in weights.items():
            w[g] += sc * sign
    # 「不要有人聲」這類指令 → 明確偏向器樂曲風
    if any(h in v for h in INSTRUMENTAL_HINT) and any(
            h in n for h in INSTRUMENTAL_HINT for n in negs):
        for g, sc in {"Classical": 2.5, "New Age": 2.2, "Ambient": 2.2, "Piano": 2.5,
                      "Smooth Jazz": 1.6, "Soundtrack": 1.4, "Classical Crossover": 1.2,
                      "J-Pop": -2.5, "Mandopop": -2.5, "Rock": -2.5,
                      "R&B/Soul": -2.0, "Reggae": -2.0, "Pop": -2.5}.items():
            w[g] += sc
    return dict(w)


def score_library(lib, playlists, vibe, feedback, history, now=None):
    """回傳 [(score, track)]，分數已含 vibe 契合度、回饋學習、避免重複。"""
    now = now or time.time()
    gw = genre_weights(vibe)
    vtoks = set(_tokens(vibe))

    # 播放清單名稱比對：使用者自己的清單名是最強的語意訊號
    pl_boost: dict[str, float] = defaultdict(float)
    for pname, tids in playlists.items():
        if pname in ("音樂", "音樂影片"):
            continue
        overlap = vtoks & set(_tokens(pname))
        if overlap:
            b = 3.0 + 0.8 * len(overlap)
            for tid in tids:
                pl_boost[tid] = max(pl_boost[tid], b)

    vl = vibe.lower()
    want_seasonal = any(k in vl for k in SEASONAL_ASK)
    want_calm = any(k in vl for k in CALM_HINT)
    want_energy = any(k in vl for k in ENERGY_HINT)
    banned = feedback["banned_tracks"]
    art_w = feedback["artist_weight"]
    alb_w = feedback["album_weight"]
    gen_w = feedback["genre_weight"]
    recent = {h["id"]: h["at"] for h in history}

    scored = []
    for t in lib:
        if t["id"] in banned:
            continue
        d = t["duration"]
        if d < 45 or d > 900:          # 濾掉 SE/間奏與過長軌
            continue
        g = GENRE_ALIAS.get(t["genre"], t["genre"])
        s = gw.get(g, 0.0) + gw.get(t["genre"], 0.0)
        s += pl_boost.get(t["id"], 0.0)

        # vibe 直接命中藝人/專輯/曲名
        if vtoks:
            for field, mult in (("artist", 2.2), ("album", 1.2), ("name", 1.2)):
                if vtoks & set(_tokens(t[field])):
                    s += mult

        # 節慶曲：沒點名就重罰，點名了就重賞
        hay = (t["name"] + " " + t["album"]).lower()
        if any(k in hay for k in SEASONAL):
            s += 7.0 if want_seasonal else -12.0

        # 速度標記：同一個曲風裡，進行曲/快板 與 慢板/夜曲 是兩回事
        if want_calm or want_energy:
            fast = any(k in hay for k in TEMPO_FAST)
            slow = any(k in hay for k in TEMPO_SLOW)
            if want_calm:
                s += (-5.0 if fast else 0.0) + (2.5 if slow else 0.0)
            else:
                s += (2.0 if fast else 0.0) + (-3.0 if slow else 0.0)

        # 回饋學習
        s += art_w.get(t["artist"], 0.0)
        s += alb_w.get(t["album"], 0.0)
        s += gen_w.get(g, 0.0)

        # 近期播過的降權，隨時間回復（6 小時衰減完）
        if t["id"] in recent:
            age = now - recent[t["id"]]
            s -= 6.0 * math.exp(-age / 21600)

        scored.append((s, t))
    return scored


def pick(lib, playlists, vibe, feedback, history, n, exclude=()):
    """加權隨機抽 n 首：高分優先但保留意外性，同一藝人最多 2 首。"""
    scored = score_library(lib, playlists, vibe, feedback, history)
    scored = [(s, t) for s, t in scored if t["id"] not in exclude]
    if not scored:
        return []
    scored.sort(key=lambda x: -x[0])
    pool = scored[:max(n * 12, 120)]          # 只從前段抽，避免抽到完全不搭的
    lo = min(s for s, _ in pool)
    out, seen_artist, seen_song = [], defaultdict(int), set()
    tries = 0
    while len(out) < n and pool and tries < n * 60:
        tries += 1
        weights = [max(s - lo, 0.0) ** 2 + 0.35 for s, _ in pool]
        i = random.choices(range(len(pool)), weights=weights, k=1)[0]
        s, t = pool.pop(i)
        key = (t["name"].strip().lower(), t["artist"].strip().lower())
        if key in seen_song:          # 資料庫有重複收錄，同名同藝人只留一首
            continue
        if seen_artist[t["artist"]] >= 2:
            continue
        seen_song.add(key)
        seen_artist[t["artist"]] += 1
        out.append(t)
    return out
