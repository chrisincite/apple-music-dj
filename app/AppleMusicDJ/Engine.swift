import Foundation
import AppKit

struct Track: Codable, Equatable {
    var name: String = ""
    var artist: String = ""
    var album: String = ""
    var position: Double = 0
    var duration: Double = 0
    var state: String = ""
    var id: String = ""
}

struct QueueItem: Codable, Equatable {
    var id: String = ""
    var name: String = ""
    var artist: String = ""
    var explored: Bool = false      // 由「探索新曲目」加進資料庫的
}

struct RecentItem: Codable, Equatable {
    var name: String = ""
    var artist: String = ""
    var at: Double = 0
}

private struct PersistedState: Codable {
    var vibe: String = ""
    var enabled: Bool = false
    var queueTarget: Int = 12
    var refillThreshold: Int = 8
    var feedbackOffset: Int = 0
    var feedback = Feedback()
    // 探索新曲目
    var exploreEnabled: Bool = true
    var exploreWide: Bool = false        // 除了同藝人延伸，也撈曲風排行榜
    var exploreCooldown: Double = 420    // 兩次探索之間至少隔這麼久（秒）
    var lastExploreAt: Double = 0
    var exploreSeen: [String] = []       // 試過的 "曲名|藝人"，不重複試
    var exploredIDs: Set<String> = []    // 探索加進來的曲目 database ID
    var lastExploreNote: String = ""     // 最後一次探索的結果，CLI 也讀得到
}

/// 心跳引擎：維持佇列深度、吃回饋、把狀態推給介面。
/// 一切都在 app 內跑，不需要 daemon、launchd 或 Python。
@MainActor
final class Engine: ObservableObject {

    @Published private(set) var track: Track?
    @Published private(set) var queue: [QueueItem] = []
    @Published private(set) var recent: [RecentItem] = []
    @Published private(set) var artwork: NSImage?
    @Published private(set) var busy = false
    @Published private(set) var exploring = false
    @Published private(set) var exploreNote: String?
    // loading 期間要抑制 persist：否則 vibe 的 didSet 會在 enabled 還沒載入時
    // 就把 enabled:false 寫回檔案，害每次啟動 DJ 都被關掉。
    private var loading = false
    @Published var vibe = "" { didSet { if !loading, vibe != oldValue { persist() } } }
    @Published var enabled = false { didSet { if !loading, enabled != oldValue { persist() } } }
    @Published var exploreEnabled = true {
        didSet { if !loading, exploreEnabled != oldValue { st.exploreEnabled = exploreEnabled; persist() } }
    }
    @Published var exploreWide = false {
        didSet { if !loading, exploreWide != oldValue { st.exploreWide = exploreWide; persist() } }
    }

    private var st = PersistedState()
    private var library: [LibTrack] = []
    private var playlists: [String: [String]] = [:]
    private var libraryStamp: Date = .distantPast
    private var history: [PlayedEntry] = []
    private var lastTrackID = ""
    private var timer: Timer?
    private let work = DispatchQueue(label: "dj.engine", qos: .utility)
    // 探索要按 UI、等 iCloud 同步，動輒十幾秒；獨立佇列才不會卡住心跳
    private let exploreQueue = DispatchQueue(label: "dj.explore", qos: .utility)

    // 檔案位置與 Python 版相同 → 既有的 `dj` CLI 仍然可用
    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/apple-music-dj/state")
    private var stateURL: URL { Self.dir.appendingPathComponent("state.json") }
    private var feedbackURL: URL { Self.dir.appendingPathComponent("feedback.jsonl") }
    private var historyURL: URL { Self.dir.appendingPathComponent("history.jsonl") }
    private var nowURL: URL { Self.dir.appendingPathComponent("nowplaying.json") }
    private var artURL: URL { Self.dir.appendingPathComponent("artwork.jpg") }

    init() {
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        load()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.beat() }
        }
        // 介面的播放進度要更即時，每秒只做一次輕量查詢
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshNowPlaying() }
        }
        beat()
    }

    // MARK: 狀態存取

    private func load() {
        loading = true
        defer { loading = false }
        if let d = try? Data(contentsOf: stateURL),
           let s = try? JSONDecoder().decode(PersistedState.self, from: d) {
            st = s
        }
        vibe = st.vibe
        enabled = st.enabled
        exploreEnabled = st.exploreEnabled
        exploreWide = st.exploreWide
        history = (try? String(contentsOf: historyURL, encoding: .utf8))?
            .split(separator: "\n").suffix(400).compactMap {
                try? JSONDecoder().decode(PlayedEntry.self, from: Data($0.utf8))
            } ?? []
        rebuildRecent()
    }

    private func persist() {
        st.vibe = vibe
        st.enabled = enabled
        st.exploreEnabled = exploreEnabled
        st.exploreWide = exploreWide
        guard let d = try? JSONEncoder().encode(st) else { return }
        try? d.write(to: stateURL, options: .atomic)
    }

    private func appendHistory(_ e: PlayedEntry) {
        history.append(e)
        if history.count > 600 { history.removeFirst(history.count - 600) }
        guard let d = try? JSONEncoder().encode(e),
              var line = String(data: d, encoding: .utf8) else { return }
        line += "\n"
        if let h = try? FileHandle(forWritingTo: historyURL) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(to: historyURL, atomically: true, encoding: .utf8)
        }
    }

    private func rebuildRecent() {
        var out: [RecentItem] = []
        var seen = Set<String>()
        for h in history.reversed() {
            if h.id == (track?.id ?? "") || seen.contains(h.id) { continue }
            seen.insert(h.id)
            out.append(RecentItem(name: h.name, artist: h.artist, at: h.at))
            if out.count >= 12 { break }
        }
        recent = out
    }

    // MARK: 對外動作（介面與 CLI 共用同一組語意）

    func setVibe(_ v: String) {
        let t = v.trimmed
        guard !t.isEmpty else { return }
        vibe = t
        enabled = true
        work.async { [weak self] in
            let np = MusicBridge.nowPlaying()
            MusicBridge.ensurePlaylist(MusicBridge.djPlaylist)
            // 保住正在播的那首，只清掉它後面的舊 vibe 佇列
            MusicBridge.trimAfterCurrent(MusicBridge.djPlaylist, keepID: np?.id ?? "")
            Task { @MainActor in self?.beat() }
        }
    }

    func thumbsUp() {
        guard let t = track else { return }
        st.feedback.bump(\.artistWeight, t.artist, 2.0)
        st.feedback.bump(\.albumWeight, t.album, 1.2)
        if let g = libTrack(t.id)?.genre { st.feedback.bump(\.genreWeight, g, 0.6) }
        persist()
    }

    func thumbsDown() {
        guard let t = track else { return }
        st.feedback.bannedTracks.insert(t.id)
        st.feedback.bump(\.artistWeight, t.artist, -1.5)
        if let g = libTrack(t.id)?.genre { st.feedback.bump(\.genreWeight, g, -0.4) }
        persist()
        skip()
    }

    func keep() {
        guard let t = track else { return }
        st.feedback.bump(\.artistWeight, t.artist, 1.0)
        persist()
        let id = t.id
        work.async {
            MusicBridge.ensurePlaylist(MusicBridge.keepPlaylist)
            MusicBridge.append([id], to: MusicBridge.keepPlaylist)
        }
    }

    func skip() { work.async { MusicBridge.nextTrack() } }

    var isPlaying: Bool { track?.state == "playing" }

    /// ▶︎/⏸：在播就暫停；沒在播就把 DJ 打開並接上「🎧 DJ」清單。
    /// 這是從 app 啟動 DJ 的入口 —— 以前只能靠輸入氛圍才會開始。
    func playPause() {
        if isPlaying {
            work.async { [weak self] in
                MusicBridge.pause()
                Task { @MainActor in self?.refreshNowPlaying() }
            }
            return
        }
        if !vibe.isEmpty { enabled = true }
        work.async { [weak self] in
            let ps = MusicBridge.playerState()
            if ps == "paused" {
                MusicBridge.resume()
            } else {
                MusicBridge.ensurePlaylist(MusicBridge.djPlaylist)
                if MusicBridge.playlistTrackIDs(MusicBridge.djPlaylist).isEmpty {
                    MusicBridge.resume()        // 佇列還空著，下一次心跳會補歌並接管
                } else {
                    MusicBridge.playPlaylist(MusicBridge.djPlaylist)
                }
            }
            Task { @MainActor in
                self?.refreshNowPlaying()
                self?.beat()
            }
        }
    }

    /// ⏹：停止播放並關掉 DJ。
    /// 必須同時關 DJ —— 否則下一次心跳看到「沒在播」會自己把音樂接回去。
    func stopAll() {
        enabled = false
        work.async { [weak self] in
            MusicBridge.stop()
            Task { @MainActor in self?.refreshNowPlaying() }
        }
    }

    private func libTrack(_ id: String) -> LibTrack? { library.first { $0.id == id } }

    // MARK: 心跳

    private func refreshNowPlaying() {
        work.async { [weak self] in
            let np = MusicBridge.nowPlaying()
            Task { @MainActor in
                guard let self else { return }
                if np?.id != self.track?.id {
                    self.onTrackChanged(np)
                }
                self.track = np
            }
        }
    }

    private func onTrackChanged(_ np: Track?) {
        guard let np, !np.id.isEmpty, np.id != lastTrackID else { return }
        lastTrackID = np.id
        appendHistory(PlayedEntry(id: np.id, name: np.name, artist: np.artist,
                                  at: Date().timeIntervalSince1970))
        rebuildRecent()
        let artPath = artURL
        work.async { [weak self] in
            let ok = MusicBridge.saveArtwork(to: artPath)
            Task { @MainActor in
                self?.artwork = ok ? NSImage(contentsOf: artPath) : nil
            }
        }
    }

    func beat() {
        guard !busy else { return }
        busy = true
        // CLI 寫進來的回饋先在主執行緒消化，快照才會帶到新的 vibe
        applyCLI(readCLIFeedback())
        let needLibrary = Date().timeIntervalSince(libraryStamp) > 600
        let snapshotVibe = vibe, snapshotEnabled = enabled
        let fb = st.feedback, hist = history
        let target = st.queueTarget, threshold = st.refillThreshold
        let exploredSnapshot = st.exploredIDs

        let snapLib = library, snapPls = playlists
        work.async { [weak self] in
            guard let self else { return }
            var lib = snapLib, pls = snapPls
            if needLibrary || lib.isEmpty {
                let l = MusicBridge.dumpLibrary()
                if !l.isEmpty { lib = l; pls = MusicBridge.userPlaylists() }
            }
            let np = MusicBridge.nowPlaying()
            var upcoming: [QueueItem] = []
            if snapshotEnabled && !snapshotVibe.isEmpty {
                MusicBridge.ensurePlaylist(MusicBridge.djPlaylist)
                var ids = MusicBridge.playlistTrackIDs(MusicBridge.djPlaylist)
                let cur = np?.id ?? ""
                let idx = ids.firstIndex(of: cur) ?? -1
                let after = Array(ids[(idx + 1)...])
                let remaining = after.count

                var picks: [LibTrack] = []
                if remaining < threshold {
                    picks = TrackPicker.pick(library: lib, playlists: pls, vibe: snapshotVibe,
                                        feedback: fb, history: hist,
                                        count: target - remaining,
                                        exclude: Set(after))
                    if !picks.isEmpty {
                        MusicBridge.append(picks.map(\.id), to: MusicBridge.djPlaylist)
                        ids = MusicBridge.playlistTrackIDs(MusicBridge.djPlaylist)
                    }
                }
                let byID = Dictionary(uniqueKeysWithValues: lib.map { ($0.id, $0) })
                upcoming = (after + picks.map(\.id)).prefix(10).map {
                    QueueItem(id: $0, name: byID[$0]?.name ?? "?",
                              artist: byID[$0]?.artist ?? "",
                              explored: exploredSnapshot.contains($0))
                }

                // 接管播放：沒在播、或播的東西已飄出 DJ 清單，都要拉回來
                let ps = MusicBridge.playerState()
                let drifted = ps == "playing" && !cur.isEmpty && !ids.contains(cur)
                if !ids.isEmpty && (ps != "playing" && ps != "paused" || drifted) {
                    MusicBridge.playPlaylist(MusicBridge.djPlaylist)
                }
            }

            let finalNP = MusicBridge.nowPlaying() ?? np
            Task { @MainActor in
                self.library = lib
                self.playlists = pls
                if needLibrary && !lib.isEmpty { self.libraryStamp = Date() }
                if finalNP?.id != self.track?.id { self.onTrackChanged(finalNP) }
                self.track = finalNP
                if !upcoming.isEmpty || (self.enabled && !self.vibe.isEmpty) {
                    self.queue = upcoming
                }
                self.writeNowPlaying()
                self.busy = false
                self.maybeExplore()
            }
        }
    }

    // MARK: 探索新曲目

    /// 條件到齊才跑：DJ 開著、有 vibe、探索沒被關掉、冷卻過了、沒有正在跑。
    /// 探索本身是背景工作，失敗不影響既有的排歌。
    private func maybeExplore() {
        guard exploreEnabled, enabled, !vibe.isEmpty, !exploring, !library.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        guard now - st.lastExploreAt >= st.exploreCooldown else { return }
        st.lastExploreAt = now
        persist()
        exploring = true

        let lib = library, pls = playlists, snapVibe = vibe
        let fb = st.feedback, wide = exploreWide
        let seen = Set(st.exploreSeen)

        exploreQueue.async { [weak self] in
            guard Explorer.accessibilityGranted(prompt: true) else {
                Task { @MainActor in
                    guard let self else { return }
                    self.exploring = false
                    self.exploreEnabled = false
                    let msg = "探索需要「輔助使用」權限：系統設定 → 隱私權與安全性 → "
                            + "輔助使用 → 打開「Apple Music DJ」，然後重新開啟探索"
                    self.st.lastExploreNote = msg
                    self.persist()
                    self.exploreNote = msg
                }
                return
            }
            let cands = Explorer.candidates(library: lib, playlists: pls, vibe: snapVibe,
                                            feedback: fb, seen: seen, wide: wide)
            var added: LibTrack?
            var tried: [String] = []
            var note = ""
            var fatal = false

            for c in cands.prefix(3) {
                tried.append(c.key)
                switch Explorer.add(c) {
                case .success(let t):
                    added = t
                    note = "✨ 探索加入：\(t.name) — \(t.artist)"
                case .failure(let e):
                    note = "探索失敗：\(e.description)"
                    if case .noAccessibility = e {
                        fatal = true
                        note = "探索需要「輔助使用」權限：系統設定 → 隱私權與安全性 → "
                             + "輔助使用 → 打開「Apple Music DJ」，然後重新開啟探索"
                    }
                }
                if added != nil || fatal { break }
            }
            if cands.isEmpty { note = "探索：這個氛圍暫時找不到新曲目" }

            // 加成功就直接排進佇列，不必等下一輪整份資料庫重掃
            if let t = added {
                MusicBridge.ensurePlaylist(MusicBridge.djPlaylist)
                MusicBridge.append([t.id], to: MusicBridge.djPlaylist)
            }

            Task { @MainActor in
                guard let self else { return }
                self.exploring = false
                if let t = added, !self.library.contains(where: { $0.id == t.id }) {
                    self.library.append(t)
                    self.st.exploredIDs.insert(t.id)
                }
                self.st.exploreSeen.append(contentsOf: tried)
                if self.st.exploreSeen.count > 800 {
                    self.st.exploreSeen.removeFirst(self.st.exploreSeen.count - 800)
                }
                if fatal { self.exploreEnabled = false }   // 沒權限就別再空轉
                self.persist()
                self.st.lastExploreNote = note
                self.exploreNote = note.isEmpty ? nil : note
                if added != nil { self.beat() }
            }
        }
    }

    /// 手動觸發一次探索（介面的 ✨ 鈕、CLI 的 `dj explore now`）。
    func exploreNow() {
        guard !exploring else { return }
        st.lastExploreAt = 0
        if !enabled, !vibe.isEmpty { enabled = true }
        maybeExplore()
    }

    func clearExploreNote() { exploreNote = nil }

    // MARK: 與 `dj` CLI 的相容層

    private enum CLIAction {
        case up, down, keep, skip, vibe(String)
        case playpause, stop, explore, exploreOn(Bool), exploreWide(Bool)
    }

    private func readCLIFeedback() -> [CLIAction] {
        guard let text = try? String(contentsOf: feedbackURL, encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let off = st.feedbackOffset
        guard lines.count > off else { return [] }
        var acts: [CLIAction] = []
        for line in lines[off...] {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                    as? [String: Any], let a = obj["action"] as? String else { continue }
            switch a {
            case "up": acts.append(.up)
            case "down": acts.append(.down)
            case "keep": acts.append(.keep)
            case "skip": acts.append(.skip)
            case "vibe": if let v = obj["vibe"] as? String { acts.append(.vibe(v)) }
            case "playpause": acts.append(.playpause)
            case "stop": acts.append(.stop)
            case "explore": acts.append(.explore)
            case "explore_on": acts.append(.exploreOn((obj["value"] as? Bool) ?? true))
            case "explore_wide": acts.append(.exploreWide((obj["value"] as? Bool) ?? true))
            default: break
            }
        }
        st.feedbackOffset = lines.count
        return acts
    }

    private func applyCLI(_ acts: [CLIAction]) {
        guard !acts.isEmpty else { persist(); return }
        for a in acts {
            switch a {
            case .up: thumbsUp()
            case .down: thumbsDown()
            case .keep: keep()
            case .skip: skip()
            case .vibe(let v): setVibe(v)
            case .playpause: playPause()
            case .stop: stopAll()
            case .explore: exploreNow()
            case .exploreOn(let v): exploreEnabled = v
            case .exploreWide(let v): exploreWide = v
            }
        }
        persist()
    }

    private func writeNowPlaying() {
        var payload: [String: Any] = [
            "vibe": vibe, "enabled": enabled,
            "explore": exploreEnabled, "explore_wide": exploreWide,
            "exploring": exploring,
            "explore_note": st.lastExploreNote,
            "updated": Date().timeIntervalSince1970,
        ]
        if let t = track,
           let d = try? JSONEncoder().encode(t),
           let o = try? JSONSerialization.jsonObject(with: d) { payload["track"] = o }
        if let d = try? JSONEncoder().encode(queue),
           let o = try? JSONSerialization.jsonObject(with: d) { payload["queue"] = o }
        if let d = try? JSONEncoder().encode(recent),
           let o = try? JSONSerialization.jsonObject(with: d) { payload["recent"] = o }
        guard let out = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? out.write(to: nowURL, options: .atomic)
    }
}
