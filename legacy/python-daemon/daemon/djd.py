#!/usr/bin/env python3
"""djd — Apple Music DJ 心跳 daemon。
維持「🎧 DJ」播放清單的佇列深度、吃小 app 的回饋、把現在播什麼寫給 app。"""
import json, os, sys, time, traceback
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import music, dj

ROOT = Path(__file__).resolve().parent.parent
STATE_DIR = ROOT / "state"
STATE = STATE_DIR / "state.json"
FEEDBACK = STATE_DIR / "feedback.jsonl"
HISTORY = STATE_DIR / "history.jsonl"
NOWPLAYING = STATE_DIR / "nowplaying.json"
ARTWORK = STATE_DIR / "artwork.jpg"
LOG = STATE_DIR / "djd.log"

HEARTBEAT = 15
DEFAULTS = {
    "vibe": "",
    "enabled": False,
    "queue_target": 12,
    "refill_threshold": 8,
    "feedback_offset": 0,
    "feedback": {"banned_tracks": {}, "artist_weight": {},
                 "album_weight": {}, "genre_weight": {}},
}


def log(msg: str):
    line = f"{time.strftime('%H:%M:%S')} {msg}"
    print(line, flush=True)
    try:
        with LOG.open("a") as f:
            f.write(line + "\n")
        if LOG.stat().st_size > 2_000_000:
            LOG.write_text("")
    except OSError:
        pass


def load_state() -> dict:
    s = dict(DEFAULTS)
    if STATE.exists():
        try:
            s.update(json.loads(STATE.read_text()))
        except (json.JSONDecodeError, OSError):
            pass
    for k, v in DEFAULTS["feedback"].items():
        s["feedback"].setdefault(k, dict(v))
    return s


def save_state(s: dict):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = STATE.with_suffix(".tmp")
    tmp.write_text(json.dumps(s, ensure_ascii=False, indent=2))
    tmp.replace(STATE)


def load_history(limit: int = 400) -> list[dict]:
    if not HISTORY.exists():
        return []
    out = []
    for line in HISTORY.read_text().splitlines()[-limit:]:
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return out


def append_jsonl(path: Path, rec: dict):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with path.open("a") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")


# ── 回饋處理 ────────────────────────────────────────────────
def bump(d: dict, key: str, delta: float, cap: float = 6.0):
    if not key:
        return
    d[key] = max(-cap, min(cap, d.get(key, 0.0) + delta))


def process_feedback(state: dict, lib_by_id: dict) -> list[str]:
    """讀 app 新寫入的回饋行，更新權重。回傳需要執行的動作。"""
    if not FEEDBACK.exists():
        return []
    lines = FEEDBACK.read_text().splitlines()
    off = state.get("feedback_offset", 0)
    new = lines[off:]
    if not new:
        return []
    state["feedback_offset"] = len(lines)
    fb = state["feedback"]
    actions = []
    for line in new:
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        act = rec.get("action")
        tid = str(rec.get("id", ""))
        t = lib_by_id.get(tid, {})
        artist = rec.get("artist") or t.get("artist", "")
        album = rec.get("album") or t.get("album", "")
        genre = t.get("genre", "")
        if act == "up":
            bump(fb["artist_weight"], artist, 2.0)
            bump(fb["album_weight"], album, 1.2)
            bump(fb["genre_weight"], genre, 0.6)
            log(f"👍 {artist} — 同類加權")
        elif act == "down":
            fb["banned_tracks"][tid] = True
            bump(fb["artist_weight"], artist, -1.5)
            bump(fb["genre_weight"], genre, -0.4)
            actions.append("skip")
            log(f"👎 {rec.get('name')} — 封鎖並跳過")
        elif act == "keep":
            bump(fb["artist_weight"], artist, 1.0)
            actions.append(f"keep:{tid}")
            log(f"＋ {rec.get('name')} → 存入精選")
        elif act == "skip":
            actions.append("skip")
        elif act == "vibe":
            state["vibe"] = rec.get("vibe", state["vibe"])
            state["enabled"] = True
            actions.append("revibe")
            log(f"🎚 vibe 改為：{state['vibe']}")
    return actions


def recent_played(limit: int = 12, exclude_id: str = "") -> list[dict]:
    """最近播過的，新到舊、去掉正在播的那首、同曲不重複列。"""
    out, seen = [], set()
    for h in reversed(load_history(300)):
        tid = h.get("id", "")
        if tid == exclude_id or tid in seen:
            continue
        seen.add(tid)
        out.append({"name": h.get("name", ""), "artist": h.get("artist", ""),
                    "at": h.get("at", 0)})
        if len(out) >= limit:
            break
    return out


def write_nowplaying(np: dict | None, state: dict, queue: list[dict]):
    payload = {
        "track": np,
        "vibe": state.get("vibe", ""),
        "enabled": state.get("enabled", False),
        "queue": queue[:10],
        "recent": recent_played(exclude_id=(np or {}).get("id", "")),
        "updated": time.time(),
    }
    tmp = NOWPLAYING.with_suffix(".tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False))
    tmp.replace(NOWPLAYING)


def main():
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    log("djd 啟動")
    lib, pls, lib_at = [], {}, 0.0
    last_track_id = None

    while True:
        try:
            state = load_state()

            # 資料庫快取每 10 分鐘更新一次
            if time.time() - lib_at > 600:
                lib = music.dump_library()
                pls = music.playlists()
                lib_at = time.time()
                log(f"資料庫快取：{len(lib)} 首 / {len(pls)} 個清單")
            lib_by_id = {t["id"]: t for t in lib}

            actions = process_feedback(state, lib_by_id)
            np = music.now_playing()

            # 記錄播過的曲目
            if np and np.get("id") and np["id"] != last_track_id:
                last_track_id = np["id"]
                append_jsonl(HISTORY, {"id": np["id"], "name": np["name"],
                                       "artist": np["artist"], "at": time.time()})
                music.save_artwork(ARTWORK)

            for a in actions:
                if a == "skip":
                    try:
                        music.next_track()
                    except RuntimeError:
                        pass
                elif a.startswith("keep:"):
                    music.ensure_playlist(music.KEEP_PLAYLIST)
                    music.append_to_playlist(music.KEEP_PLAYLIST, [a.split(":", 1)[1]])
                elif a == "revibe":
                    # 保住正在播的那首，只清掉它後面的舊 vibe 佇列
                    music.ensure_playlist(music.DJ_PLAYLIST)
                    np = music.now_playing()
                    cur_id = np.get("id", "") if np else ""
                    kept = music.trim_after_current(music.DJ_PLAYLIST, cur_id)
                    log("換 vibe：" + ("保留當前曲目、清空後續佇列" if kept
                                      else "當前曲目不在 DJ 清單，整份重排"))

            if not state.get("enabled") or not state.get("vibe"):
                write_nowplaying(np, state, [])
                save_state(state)
                time.sleep(HEARTBEAT)
                continue

            music.ensure_playlist(music.DJ_PLAYLIST)
            ids = music.playlist_track_ids(music.DJ_PLAYLIST)

            # 算佇列剩餘：現在播的那首在清單中的位置之後還有幾首
            cur = np["id"] if np else None
            idx = ids.index(cur) if cur in ids else -1
            remaining = len(ids) - idx - 1
            upcoming = [lib_by_id.get(i, {"name": "?", "artist": ""})
                        for i in ids[idx + 1:]]

            if remaining < state["refill_threshold"]:
                need = state["queue_target"] - remaining
                history = load_history()
                picks = dj.pick(lib, pls, state["vibe"], state["feedback"],
                                history, need, exclude=set(ids[idx + 1:]))
                if picks:
                    music.append_to_playlist(music.DJ_PLAYLIST, [p["id"] for p in picks])
                    log(f"補 {len(picks)} 首（剩 {remaining} → {remaining + len(picks)}）："
                        + "、".join(p["name"] for p in picks[:3]) + " …")
                    upcoming += picks

            # 接管播放：沒在播、或播的東西已經飄出 DJ 清單，都要拉回來
            st = music.player_state()
            ids_now = music.playlist_track_ids(music.DJ_PLAYLIST)
            drifted = st == "playing" and cur is not None and cur not in ids_now
            if ids_now and (st not in ("playing", "paused") or drifted):
                try:
                    music.play_playlist(music.DJ_PLAYLIST)
                    log("接管播放" + ("（原本播的不在 DJ 清單）" if drifted else ""))
                    time.sleep(2)
                    np = music.now_playing() or np
                except RuntimeError as e:
                    log(f"開播失敗：{e}")

            write_nowplaying(np, state, upcoming)
            save_state(state)

        except Exception:
            log("錯誤：\n" + traceback.format_exc())
        time.sleep(HEARTBEAT)


if __name__ == "__main__":
    main()
