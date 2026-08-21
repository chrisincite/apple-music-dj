import Foundation

/// 探索到、但還沒進資料庫的候選曲。
struct Candidate: Equatable {
    var songID: String = ""          // Apple Music 目錄 ID
    var name: String = ""
    var artist: String = ""
    var album: String = ""
    var genre: String = ""           // 主要曲風，英文（l=en-US），與資料庫同一套詞彙
    var allGenres: [String] = []
    var duration: Double = 0
    var source: String = ""          // artist / similar / search

    var key: String { Explorer.key(name, artist) }
}

/// 探索新曲目：用 Apple Music 目錄找出你資料庫裡沒有的歌，加進資料庫，
/// 再交給既有的佇列邏輯排歌。
///
/// 為什麼一定要「加進資料庫」而不是直接播：目錄裡的歌對 AppleScript 而言是幽靈
/// （`class` 是 `URL track`、`cloud status` 是 `missing value`），排不進播放清單、
/// `duplicate` 會被 `Can only duplicate subscription tracks to library source` 擋掉，
/// 👍👎 也綁不住 ID。只有真的入庫才拿得到可排隊的曲目。
enum Explorer {

    static func key(_ name: String, _ artist: String) -> String {
        (name.lowercased().trimmed) + "|" + (artist.lowercased().trimmed)
    }

    // MARK: 找候選

    /// 由 vibe 挑出「值得延伸」的藝人：曲風權重 × 回饋權重 × 播放清單命中。
    private static func seedArtists(library: [LibTrack], playlists: [String: [String]],
                                    vibe: String, feedback: Feedback, limit: Int) -> [String] {
        let gw = TrackPicker.genreWeights(vibe)
        let vtoks = TrackPicker.tokens(vibe)

        var plBoost: [String: Double] = [:]
        for (pname, tids) in playlists where pname != "音樂" && pname != "音樂影片" {
            let overlap = vtoks.intersection(TrackPicker.tokens(pname))
            guard !overlap.isEmpty else { continue }
            let b = 3.0 + 0.8 * Double(overlap.count)
            for tid in tids { plBoost[tid] = max(plBoost[tid] ?? 0, b) }
        }

        var score: [String: Double] = [:]
        for t in library where !t.artist.isEmpty {
            let g = TrackPicker.genreAlias[t.genre] ?? t.genre
            var s = (gw[g] ?? 0)
            s += plBoost[t.id] ?? 0
            s += (feedback.artistWeight[t.artist] ?? 0)
            score[t.artist] = max(score[t.artist] ?? -99, s)
        }
        return score.filter { $0.value > 0.5 }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map(\.key)
    }

    // MARK: 篩選

    /// 用同一套 TrackPicker 規則替候選打分；<= 0 的不要 ——
    /// 探索不該把不合 vibe 的東西塞進你的資料庫。
    static func filter(_ cands: [Candidate], vibe: String, feedback: Feedback,
                       libraryKeys: Set<String>, seen: Set<String>) -> [(Double, Candidate)] {
        let gw = TrackPicker.genreWeights(vibe)
        let vl = vibe.lowercased()
        let wantSeasonal = TrackPicker.seasonalAsk.contains { vl.contains($0) }
        let wantCalm = TrackPicker.calmHint.contains { vl.contains($0) }
        let wantEnergy = TrackPicker.energyHint.contains { vl.contains($0) }

        var out: [(Double, Candidate)] = []
        var dedup = Set<String>()
        for c in cands {
            if c.songID.isEmpty { continue }
            if c.duration < 45 || c.duration > 900 { continue }
            if libraryKeys.contains(c.key) || seen.contains(c.key) { continue }
            if dedup.contains(c.key) { continue }

            // Apple 一首歌會給多個曲風，取最合 vibe 的那個
            var s = -99.0
            let genres = c.allGenres.isEmpty ? [c.genre] : c.allGenres
            for g0 in genres {
                let g = TrackPicker.genreAlias[g0] ?? g0
                s = max(s, gw[g] ?? 0)
            }
            if s == -99 { s = 0 }
            s += feedback.artistWeight[c.artist] ?? 0
            s += feedback.genreWeight[TrackPicker.genreAlias[c.genre] ?? c.genre] ?? 0

            switch c.source {
            case "artist":
                // 同藝人延伸本身就是強訊號：曲風中性也放行，被 vibe 明確排斥才擋
                if s <= -1.0 { continue }
                s += 1.5
            case "similar":
                if s <= -0.5 { continue }
                s += 0.5
            default:
                if s <= 0 { continue }
            }

            let hay = (c.name + " " + c.album).lowercased()
            if TrackPicker.seasonal.contains(where: { hay.contains($0) }) {
                if !wantSeasonal { continue }
                s += 5
            }
            if wantCalm || wantEnergy {
                let fast = TrackPicker.tempoFast.contains { hay.contains($0) }
                let slow = TrackPicker.tempoSlow.contains { hay.contains($0) }
                if wantCalm { s += (fast ? -5.0 : 0) + (slow ? 2.5 : 0) }
                else { s += (fast ? 2.0 : 0) + (slow ? -3.0 : 0) }
            }
            if s <= 0 { continue }
            dedup.insert(c.key)
            out.append((s, c))
        }
        return out.sorted { $0.0 > $1.0 }
    }

    /// 同一位藝人最多兩首，並加一點隨機擾動 ——
    /// 不這樣做的話單一藝人會整批洗版，每次都從同一個人身上挖，等於沒在探索。
    static func diversify(_ scored: [(Double, Candidate)], perArtist: Int = 2,
                          limit: Int = 40) -> [Candidate] {
        let jittered = scored.map { (s, c) in (s + Double.random(in: 0...1.5), c) }
            .sorted { $0.0 > $1.0 }
        var count: [String: Int] = [:]
        var out: [Candidate] = []
        for (_, c) in jittered {
            let a = c.artist.lowercased().trimmed
            if (count[a] ?? 0) >= perArtist { continue }
            count[a, default: 0] += 1
            out.append(c)
            if out.count >= limit { break }
        }
        return out
    }

    /// 蒐集候選。`wide` 打開才會去找相似藝人（會冒出沒聽過的人，命中率低一截）。
    static func candidates(library: [LibTrack], playlists: [String: [String]],
                           vibe: String, feedback: Feedback,
                           seen: Set<String>, wide: Bool) -> [Candidate] {
        guard !vibe.isEmpty, !library.isEmpty else { return [] }
        let libraryKeys = Set(library.map { key($0.name, $0.artist) })
        var pool: [Candidate] = []

        let seeds = seedArtists(library: library, playlists: playlists,
                                vibe: vibe, feedback: feedback, limit: 14).shuffled()
        for a in seeds.prefix(3) { pool += AppleMusicAPI.artistTopSongs(a) }

        if wide, let seed = seeds.first {
            for other in AppleMusicAPI.similarArtists(seed).prefix(3) {
                pool += AppleMusicAPI.artistTopSongs(other, limit: 12)
                    .map { var c = $0; c.source = "similar"; return c }
            }
        }

        let scored = filter(pool, vibe: vibe, feedback: feedback,
                            libraryKeys: libraryKeys, seen: seen)
        return diversify(scored)
    }

    // MARK: 加進資料庫

    enum AddError: Error, CustomStringConvertible {
        case api(AppleMusicAPI.AddError)
        case notSynced
        var description: String {
            switch self {
            case .api(let e): return e.description
            case .notSynced: return "已送出加入資料庫，但 iCloud 還沒同步下來"
            }
        }
    }

    /// 一個 POST 加進資料庫，然後等 iCloud 把它同步進 Music.app。
    /// 實測 POST 約 1.3 秒、同步約數秒到十幾秒；全程不動前景。
    static func add(_ c: Candidate) -> Result<LibTrack, AddError> {
        if case .failure(let e) = AppleMusicAPI.addToLibrary(songID: c.songID) {
            return .failure(.api(e))
        }
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
            if let t = MusicBridge.findTrack(name: c.name, artist: c.artist) { return .success(t) }
            Thread.sleep(forTimeInterval: 1.5)
        }
        return .failure(.notSynced)
    }
}
