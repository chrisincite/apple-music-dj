import Foundation

/// Music.app 的 AppleScript 橋接。所有與 Apple Music 的往來都走這裡。
/// 用子行程跑 osascript（而非 NSAppleScript）：TCC 仍然歸屬本 app，
/// 但不必擔心 NSAppleScript 的執行緒限制。
enum MusicBridge {

    static let sep = "\u{241F}"        // ␟ 欄位分隔，曲名不可能出現
    static let rec = "\u{2405}"        // ␅ 區塊分隔
    static let sub = "\u{2406}"        // ␆ 次分隔
    static let djPlaylist = "🎧 DJ"
    static let keepPlaylist = "🎧 DJ 精選"

    @discardableResult
    static func run(_ script: String, timeout: TimeInterval = 120) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-"]
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe
        do { try p.run() } catch { return nil }
        inPipe.fileHandleForWriting.write(script.data(using: .utf8)!)
        try? inPipe.fileHandleForWriting.close()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        _ = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: out, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    static func tell(_ body: String) -> String? {
        run("tell application \"Music\" to \(body)")
    }

    // MARK: 資料庫

    static func dumpLibrary() -> [LibTrack] {
        let script = """
        tell application "Music"
          set AppleScript's text item delimiters to "\(sep)"
          set L to library playlist 1
          set a to (database ID of every track of L) as text
          set b to (name of every track of L) as text
          set c to (artist of every track of L) as text
          set d to (album of every track of L) as text
          set e to (genre of every track of L) as text
          set f to (duration of every track of L) as text
          return a & "\(rec)" & b & "\(rec)" & c & "\(rec)" & d & "\(rec)" & e & "\(rec)" & f
        end tell
        """
        guard let raw = run(script, timeout: 300) else { return [] }
        let cols = raw.components(separatedBy: rec).map { $0.components(separatedBy: sep) }
        guard cols.count >= 6 else { return [] }
        let n = cols.map(\.count).min() ?? 0
        return (0..<n).map { i in
            LibTrack(id: cols[0][i].trimmed, name: cols[1][i].trimmed,
                     artist: cols[2][i].trimmed, album: cols[3][i].trimmed,
                     genre: cols[4][i].trimmed, duration: Double(cols[5][i].trimmed) ?? 0)
        }
    }

    /// 播放清單名 → 曲目 database ID。清單名是 vibe 比對最強的訊號。
    static func userPlaylists() -> [String: [String]] {
        let script = """
        tell application "Music"
          set AppleScript's text item delimiters to "\(sep)"
          set out to ""
          repeat with p in user playlists
            try
              if (count of tracks of p) > 0 then
                set out to out & (name of p) & "\(sub)" & ((database ID of every track of p) as text) & "\(rec)"
              end if
            end try
          end repeat
          return out
        end tell
        """
        guard let raw = run(script, timeout: 300) else { return [:] }
        var res: [String: [String]] = [:]
        for chunk in raw.components(separatedBy: rec) {
            let parts = chunk.components(separatedBy: sub)
            guard parts.count == 2 else { continue }
            res[parts[0].trimmed] = parts[1].components(separatedBy: sep)
                .map(\.trimmed).filter { !$0.isEmpty }
        }
        return res
    }

    // MARK: 播放狀態

    static func playerState() -> String { tell("get player state") ?? "unknown" }

    static func nowPlaying() -> Track? {
        let script = """
        tell application "Music"
          if player state is stopped then return ""
          set AppleScript's text item delimiters to "\(sep)"
          set t to current track
          set pid to ""
          try
            set pid to (database ID of t) as text
          end try
          return (name of t) & "\(sep)" & (artist of t) & "\(sep)" & (album of t) & "\(sep)" & ¬
                 ((player position) as text) & "\(sep)" & ((duration of t) as text) & "\(sep)" & ¬
                 (player state as text) & "\(sep)" & pid
        end tell
        """
        guard let raw = run(script, timeout: 30), !raw.isEmpty else { return nil }
        let p = raw.components(separatedBy: sep)
        guard p.count >= 7 else { return nil }
        return Track(name: p[0], artist: p[1], album: p[2],
                     position: Double(p[3]) ?? 0, duration: Double(p[4]) ?? 0,
                     state: p[5], id: p[6])
    }

    @discardableResult
    static func saveArtwork(to url: URL) -> Bool {
        let script = """
        tell application "Music"
          if player state is stopped then return "no"
          try
            set d to raw data of artwork 1 of current track
          on error
            return "no"
          end try
          set f to open for access POSIX file "\(url.path)" with write permission
          set eof f to 0
          write d to f
          close access f
          return "ok"
        end tell
        """
        return run(script, timeout: 40) == "ok"
    }

    // MARK: 播放清單操作

    static func ensurePlaylist(_ name: String) {
        run("""
        tell application "Music"
          if not (exists user playlist "\(name)") then make new user playlist with properties {name:"\(name)"}
        end tell
        """)
    }

    static func playlistTrackIDs(_ name: String) -> [String] {
        let script = """
        tell application "Music"
          set AppleScript's text item delimiters to "\(sep)"
          if not (exists user playlist "\(name)") then return ""
          set p to user playlist "\(name)"
          if (count of tracks of p) is 0 then return ""
          return (database ID of every track of p) as text
        end tell
        """
        guard let raw = run(script, timeout: 60), !raw.isEmpty else { return [] }
        return raw.components(separatedBy: sep).map(\.trimmed).filter { !$0.isEmpty }
    }

    /// 只往末端追加 → 已播過的部分不動，接歌才會是原生無縫。
    static func append(_ ids: [String], to playlist: String) {
        guard !ids.isEmpty else { return }
        run("""
        tell application "Music"
          set p to user playlist "\(playlist)"
          set L to library playlist 1
          repeat with tid in {\(ids.joined(separator: ", "))}
            try
              duplicate (first track of L whose database ID is tid) to p
            end try
          end repeat
        end tell
        """, timeout: 300)
    }

    static func clearPlaylist(_ name: String) {
        run("""
        tell application "Music"
          if exists user playlist "\(name)" then delete every track of user playlist "\(name)"
        end tell
        """, timeout: 120)
    }

    /// 只刪掉現正播放那首之後的曲目 → 換 vibe 不中斷。
    /// 找不到 keepID 就整份清空；回傳是否保住當前曲目。
    @discardableResult
    static func trimAfterCurrent(_ name: String, keepID: String) -> Bool {
        let ids = playlistTrackIDs(name)
        if !keepID.isEmpty, let idx = ids.firstIndex(of: keepID) {
            let after = ids.count - idx - 1
            if after > 0 {
                run("""
                tell application "Music"
                  set p to user playlist "\(name)"
                  repeat \(after) times
                    delete last track of p
                  end repeat
                end tell
                """, timeout: 180)
            }
            return true
        }
        clearPlaylist(name)
        return false
    }

    static func playPlaylist(_ name: String) { tell("play user playlist \"\(name)\"") }
    static func nextTrack() { tell("next track") }
    static func previousTrack() { tell("previous track") }
    static func pause() { tell("pause") }
    static func resume() { tell("play") }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
