"""Music.app 的 AppleScript 橋接層。所有與 Apple Music 的往來都走這裡。"""
import json, subprocess, time
from pathlib import Path

SEP = "␟"          # 分隔符：曲名裡不可能出現
DJ_PLAYLIST = "🎧 DJ"
KEEP_PLAYLIST = "🎧 DJ 精選"


def osa(script: str, timeout: int = 60) -> str:
    r = subprocess.run(["osascript", "-e", script],
                       capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip())
    return r.stdout.strip()


def osa_multi(script: str, timeout: int = 180) -> str:
    r = subprocess.run(["osascript", "-"], input=script,
                       capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip())
    return r.stdout.strip()


def tell(body: str, timeout: int = 60) -> str:
    return osa(f'tell application "Music" to {body}', timeout)


# ── 資料庫快取 ───────────────────────────────────────────────
DUMP = f'''
tell application "Music"
  set AppleScript's text item delimiters to "{SEP}"
  set L to library playlist 1
  set a to (database ID of every track of L) as text
  set b to (name of every track of L) as text
  set c to (artist of every track of L) as text
  set d to (album of every track of L) as text
  set e to (genre of every track of L) as text
  set f to (duration of every track of L) as text
  return a & "␅" & b & "␅" & c & "␅" & d & "␅" & e & "␅" & f
end tell
'''


def dump_library() -> list[dict]:
    raw = osa_multi(DUMP)
    cols = raw.split("␅")
    ids, names, artists, albums, genres, durs = [c.split(SEP) for c in cols]
    out = []
    for i in range(len(ids)):
        try:
            dur = float(durs[i])
        except (ValueError, IndexError):
            dur = 0.0
        out.append({
            "id": ids[i].strip(),
            "name": names[i].strip(),
            "artist": artists[i].strip(),
            "album": albums[i].strip(),
            "genre": genres[i].strip(),
            "duration": dur,
        })
    return out


def playlists() -> dict[str, list[str]]:
    """播放清單名 → 該清單的 database ID 列表。清單名是 vibe 比對的重要訊號。"""
    script = f'''
tell application "Music"
  set AppleScript's text item delimiters to "{SEP}"
  set out to ""
  repeat with p in user playlists
    try
      if (count of tracks of p) > 0 then
        set out to out & (name of p) & "␆" & ((database ID of every track of p) as text) & "␅"
      end if
    end try
  end repeat
  return out
end tell
'''
    raw = osa_multi(script)
    res = {}
    for chunk in raw.split("␅"):
        if "␆" not in chunk:
            continue
        nm, idstr = chunk.split("␆", 1)
        res[nm.strip()] = [x.strip() for x in idstr.split(SEP) if x.strip()]
    return res


# ── 播放控制 ────────────────────────────────────────────────
def player_state() -> str:
    try:
        return tell("get player state")
    except RuntimeError:
        return "unknown"


def now_playing() -> dict | None:
    script = f'''
tell application "Music"
  if player state is stopped then return ""
  set AppleScript's text item delimiters to "{SEP}"
  set t to current track
  set pid to ""
  try
    set pid to (database ID of t) as text
  end try
  return (name of t) & "{SEP}" & (artist of t) & "{SEP}" & (album of t) & "{SEP}" & ¬
         ((player position) as text) & "{SEP}" & ((duration of t) as text) & "{SEP}" & ¬
         (player state as text) & "{SEP}" & pid
end tell
'''
    try:
        raw = osa_multi(script, timeout=20)
    except RuntimeError:
        return None
    if not raw:
        return None
    p = raw.split(SEP)
    if len(p) < 7:
        return None
    def num(x):
        try:
            return float(x)
        except ValueError:
            return 0.0
    return {"name": p[0], "artist": p[1], "album": p[2],
            "position": num(p[3]), "duration": num(p[4]),
            "state": p[5], "id": p[6]}


def save_artwork(dest: Path) -> bool:
    script = f'''
tell application "Music"
  if player state is stopped then return "no"
  try
    set d to raw data of artwork 1 of current track
  on error
    return "no"
  end try
  set f to open for access POSIX file "{dest}" with write permission
  set eof f to 0
  write d to f
  close access f
  return "ok"
end tell
'''
    try:
        return osa_multi(script, timeout=25) == "ok"
    except RuntimeError:
        return False


def ensure_playlist(name: str):
    osa_multi(f'''
tell application "Music"
  if not (exists user playlist "{name}") then make new user playlist with properties {{name:"{name}"}}
end tell
''')


def playlist_track_ids(name: str) -> list[str]:
    try:
        raw = osa_multi(f'''
tell application "Music"
  set AppleScript's text item delimiters to "{SEP}"
  if not (exists user playlist "{name}") then return ""
  set p to user playlist "{name}"
  if (count of tracks of p) is 0 then return ""
  return (database ID of every track of p) as text
end tell
''')
    except RuntimeError:
        return []
    return [x.strip() for x in raw.split(SEP) if x.strip()]


def append_to_playlist(pl: str, track_ids: list[str]):
    """把資料庫曲目加到播放清單末端（不動已在播的部分 → 接歌無縫）。"""
    if not track_ids:
        return
    ids = ", ".join(track_ids)
    osa_multi(f'''
tell application "Music"
  set p to user playlist "{pl}"
  set L to library playlist 1
  repeat with tid in {{{ids}}}
    try
      duplicate (first track of L whose database ID is tid) to p
    end try
  end repeat
end tell
''', timeout=180)


def clear_playlist(name: str):
    osa_multi(f'''
tell application "Music"
  if exists user playlist "{name}" then delete every track of user playlist "{name}"
end tell
''')


def trim_after_current(name: str, keep_id: str) -> bool:
    """只刪掉現正播放那首之後的曲目，保留它繼續播 → 換 vibe 不中斷。
    找不到 keep_id 就整份清空。回傳是否有保住當前曲目。"""
    ids = playlist_track_ids(name)
    if keep_id and keep_id in ids:
        n_after = len(ids) - ids.index(keep_id) - 1
        if n_after > 0:
            osa_multi(f'''
tell application "Music"
  set p to user playlist "{name}"
  repeat {n_after} times
    delete last track of p
  end repeat
end tell
''', timeout=120)
        return True
    clear_playlist(name)
    return False


def play_playlist(name: str):
    tell(f'play user playlist "{name}"')


def next_track():
    tell("next track")


def pause():
    tell("pause")


def resume():
    tell("play")
