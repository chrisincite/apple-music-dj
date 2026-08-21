import Foundation

struct LibTrack: Codable, Equatable {
    var id: String
    var name: String
    var artist: String
    var album: String
    var genre: String
    var duration: Double
}

struct Feedback: Codable {
    var bannedTracks: Set<String> = []
    var artistWeight: [String: Double] = [:]
    var albumWeight: [String: Double] = [:]
    var genreWeight: [String: Double] = [:]

    mutating func bump(_ keyPath: WritableKeyPath<Feedback, [String: Double]>,
                       _ key: String, _ delta: Double, cap: Double = 6) {
        guard !key.isEmpty else { return }
        let v = (self[keyPath: keyPath][key] ?? 0) + delta
        self[keyPath: keyPath][key] = min(cap, max(-cap, v))
    }
}

struct PlayedEntry: Codable {
    var id: String
    var name: String
    var artist: String
    var at: Double
}

/// DJ 選曲腦：把自由文字的 vibe 變成一份加權曲目清單。純規則、不呼叫模型。
enum TrackPicker {

    // vibe 關鍵字 → 曲風權重。中英並列，比對用子字串。
    static let lexicon: [(keys: [String], weights: [String: Double])] = [
        (["專注", "工作", "寫程式", "coding", "focus", "deep work", "讀書", "看書"],
         ["Classical": 3.0, "New Age": 2.6, "Ambient": 2.6, "Piano": 2.4,
          "Smooth Jazz": 2.0, "Classical Crossover": 1.8, "Soundtrack": 1.6,
          "J-Pop": -1.2, "Rock": -2.0, "Mandopop": -1.2, "Anime": -1.5]),
        (["深夜", "夜晚", "凌晨", "night", "late", "睡前", "sleep", "失眠"],
         ["New Age": 2.8, "Ambient": 2.8, "Classical": 2.4, "Piano": 2.4,
          "Smooth Jazz": 2.2, "Bossa Nova": 1.8, "Rock": -2.5, "Anime": -1.5]),
        (["早晨", "早上", "morning", "咖啡", "coffee", "起床", "brunch"],
         ["Bossa Nova": 2.6, "Smooth Jazz": 2.2, "Classical Crossover": 1.8,
          "J-Pop": 1.2, "New Age": 1.2, "Reggae": 1.0, "Rock": -1.0]),
        (["放鬆", "chill", "relax", "耍廢", "慵懶", "下午"],
         ["Reggae": 2.4, "Bossa Nova": 2.2, "New Age": 2.0, "Smooth Jazz": 2.0,
          "Ambient": 1.6, "R&B/Soul": 1.4, "Rock": -1.2]),
        (["開心", "振奮", "有活力", "happy", "energetic", "運動", "workout", "通勤", "開車"],
         ["J-Pop": 2.2, "Rock": 2.2, "Pop": 2.0, "R&B/Soul": 1.8, "Reggae": 1.4,
          "Classical": -2.0, "New Age": -2.2, "Ambient": -2.2]),
        (["失戀", "傷心", "難過", "sad", "emo", "療傷", "哭"],
         ["Mandopop": 2.6, "J-Pop": 1.2, "Classical": 1.0, "Piano": 1.2,
          "Rock": -1.0, "Reggae": -1.5]),
        (["懷舊", "老歌", "nostalgia", "回憶", "以前"],
         ["Mandopop": 2.4, "Cantopop/HK-Pop": 1.8, "Chinese": 1.6, "Pop": 1.0]),
        (["日文", "日本", "jpop", "j-pop", "日語", "日劇"],
         ["J-Pop": 3.0, "Anime": 1.6, "Worldwide": 0.8, "Mandopop": -2.0]),
        (["華語", "中文", "國語", "mandopop", "台語"],
         ["Mandopop": 3.0, "Chinese": 2.0, "Cantopop/HK-Pop": 1.6, "J-Pop": -2.0]),
        (["古典", "classical", "鋼琴", "piano", "交響", "室內樂"],
         ["Classical": 3.2, "Piano": 3.0, "Classical Crossover": 2.4, "Opera": 1.2,
          "J-Pop": -2.0, "Rock": -2.5, "Reggae": -2.5]),
        (["抒情", "柔和", "舒緩", "溫柔", "慢板", "背景音樂", "bgm", "lyrical",
          "mellow", "soft", "gentle", "calm", "ballad", "不吵", "安靜"],
         ["New Age": 2.8, "Piano": 2.8, "Ambient": 2.4, "Classical": 2.0,
          "Classical Crossover": 2.0, "Smooth Jazz": 2.0, "Soundtrack": 1.4,
          "Rock": -3.0, "Reggae": -2.0, "Pop": -1.5, "Anime": -1.5]),
        (["爵士", "jazz", "bossa", "微醺", "小酒館"],
         ["Smooth Jazz": 3.0, "Jazz": 3.0, "Bossa Nova": 2.6, "R&B/Soul": 1.4]),
        (["雷鬼", "reggae", "夏天", "summer", "海邊", "度假"],
         ["Reggae": 3.2, "Bossa Nova": 2.0, "Worldwide": 1.4]),
        (["電影", "配樂", "soundtrack", "史詩", "動畫"],
         ["Soundtrack": 2.8, "Anime": 2.0, "Classical Crossover": 1.4]),
        (["r&b", "soul", "節奏藍調"],
         ["R&B/Soul": 3.0, "Smooth Jazz": 1.4, "Pop": 1.0]),
        (["搖滾", "rock", "熱血"],
         ["Rock": 3.0, "J-Pop": 1.2, "Pop": 1.0, "New Age": -2.0, "Ambient": -2.0]),
    ]

    static let genreAlias = ["原聲帶": "Soundtrack"]

    // 節慶曲：除非 vibe 明講，否則平常不該冒出來
    static let seasonal = ["christmas", "xmas", "聖誕", "クリスマス", "santa",
                           "jingle bell", "holy night", "winter wonderland", "新年", "賀歲"]
    static let seasonalAsk = ["聖誕", "christmas", "xmas", "耶誕", "節慶", "過年", "新年", "賀歲"]

    static let negation = ["不要", "不想", "別放", "別來", "避開", "沒有", "無", "not ", "no ", "without "]
    static let instrumentalHint = ["人聲", "vocal", "純音樂", "instrumental", "演奏", "bgm", "純樂器"]

    // 古典／演奏曲的曲名幾乎都標著速度與體裁，是規則式選曲唯一能看出
    // 「同一曲風裡性格差很多」的地方。
    static let tempoFast = ["allegro", "presto", "vivace", "vivo", "con brio", "schnell",
                            "galopp", "galop", "polka", "marsch", "march", "scherzo",
                            "furioso", "agitato", "tarantella", "rondo", "finale",
                            "stürmisch", "energico", "molto mosso"]
    static let tempoSlow = ["adagio", "andante", "largo", "larghetto", "lento", "grave",
                            "sostenuto", "cantabile", "sarabande", "nocturne", "notturno",
                            "prélude", "prelude", "berceuse", "romance", "reverie", "rêverie",
                            "träumerei", "elegy", "élégie", "aria", "air ", "pastorale",
                            "barcarolle", "intermezzo", "siciliana", "lullaby", "serenade",
                            "ave maria", "meditation", "méditation"]
    static let calmHint = ["抒情", "柔和", "舒緩", "溫柔", "慢板", "背景", "bgm", "安靜", "不吵",
                           "專注", "寫程式", "深夜", "睡前", "放鬆", "讀書", "看書", "chill",
                           "calm", "focus", "relax", "sleep", "mellow", "soft", "gentle"]
    static let energyHint = ["振奮", "有活力", "熱血", "運動", "workout", "energetic", "開心",
                             "派對", "party", "通勤", "開車"]

    /// 中文抽 2-gram、英文抽單字，讓 vibe 能跟清單名／藝人名做模糊比對。
    static func tokens(_ s: String) -> Set<String> {
        let lower = s.lowercased()
        var out = Set<String>()
        for w in lower.components(separatedBy: CharacterSet.alphanumerics.inverted)
        where w.count >= 2 { out.insert(w) }
        let cjk = lower.unicodeScalars.filter {
            (0x4E00...0x9FFF).contains($0.value) || (0x3040...0x30FF).contains($0.value)
        }.map(Character.init)
        if cjk.count >= 2 {
            for i in 0..<(cjk.count - 1) { out.insert(String(cjk[i...i + 1])) }
        }
        return out
    }

    /// 抓出否定詞之後那一小段文字，這些內容要反向計分。
    static func negatedSpans(_ v: String) -> [String] {
        var spans: [String] = []
        for neg in negation {
            var search = v[v.startIndex...]
            while let r = search.range(of: neg) {
                let start = r.upperBound
                let end = v.index(start, offsetBy: 12, limitedBy: v.endIndex) ?? v.endIndex
                spans.append(String(v[start..<end]))
                search = v[r.upperBound...]
            }
        }
        return spans
    }

    static func genreWeights(_ vibe: String) -> [String: Double] {
        let v = vibe.lowercased()
        let negs = negatedSpans(v)
        var w: [String: Double] = [:]
        for entry in lexicon {
            guard entry.keys.contains(where: { v.contains($0) }) else { continue }
            // 命中的關鍵字若落在否定片語裡，整組權重反向
            let inNeg = entry.keys.contains { k in negs.contains { $0.contains(k) } }
            let sign = inNeg ? -0.8 : 1.0
            for (g, sc) in entry.weights { w[g, default: 0] += sc * sign }
        }
        // 「不要有人聲」這類指令 → 明確偏向器樂曲風
        let hintNegated = instrumentalHint.contains { h in negs.contains { $0.contains(h) } }
        if instrumentalHint.contains(where: { v.contains($0) }) && hintNegated {
            for (g, sc) in ["Classical": 2.5, "New Age": 2.2, "Ambient": 2.2, "Piano": 2.5,
                            "Smooth Jazz": 1.6, "Soundtrack": 1.4, "Classical Crossover": 1.2,
                            "J-Pop": -2.5, "Mandopop": -2.5, "Rock": -2.5,
                            "R&B/Soul": -2.0, "Reggae": -2.0, "Pop": -2.5] {
                w[g, default: 0] += sc
            }
        }
        return w
    }

    /// 加權隨機抽 n 首：高分優先但保留意外性，同一藝人最多 2 首、同名同藝人去重。
    static func pick(library: [LibTrack], playlists: [String: [String]], vibe: String,
                     feedback: Feedback, history: [PlayedEntry], count n: Int,
                     exclude: Set<String> = []) -> [LibTrack] {
        guard n > 0, !library.isEmpty else { return [] }
        let now = Date().timeIntervalSince1970
        let gw = genreWeights(vibe)
        let vtoks = tokens(vibe)
        let vl = vibe.lowercased()
        let wantSeasonal = seasonalAsk.contains { vl.contains($0) }
        let wantCalm = calmHint.contains { vl.contains($0) }
        let wantEnergy = energyHint.contains { vl.contains($0) }

        // 播放清單名稱比對：使用者自己的清單名是最強的語意訊號
        var plBoost: [String: Double] = [:]
        for (pname, tids) in playlists where pname != "音樂" && pname != "音樂影片" {
            let overlap = vtoks.intersection(tokens(pname))
            guard !overlap.isEmpty else { continue }
            let b = 3.0 + 0.8 * Double(overlap.count)
            for tid in tids { plBoost[tid] = max(plBoost[tid] ?? 0, b) }
        }

        var recent: [String: Double] = [:]
        for h in history { recent[h.id] = max(recent[h.id] ?? 0, h.at) }

        var scored: [(Double, LibTrack)] = []
        scored.reserveCapacity(library.count)
        for t in library {
            if feedback.bannedTracks.contains(t.id) || exclude.contains(t.id) { continue }
            if t.duration < 45 || t.duration > 900 { continue }   // 濾掉 SE／間奏與過長軌
            let g = genreAlias[t.genre] ?? t.genre
            var s = (gw[g] ?? 0) + (g == t.genre ? 0 : (gw[t.genre] ?? 0))
            s += plBoost[t.id] ?? 0

            if !vtoks.isEmpty {
                if !vtoks.isDisjoint(with: tokens(t.artist)) { s += 2.2 }
                if !vtoks.isDisjoint(with: tokens(t.album))  { s += 1.2 }
                if !vtoks.isDisjoint(with: tokens(t.name))   { s += 1.2 }
            }

            let hay = (t.name + " " + t.album).lowercased()
            if seasonal.contains(where: { hay.contains($0) }) { s += wantSeasonal ? 7.0 : -12.0 }

            // 速度標記：同一曲風裡，進行曲/快板 與 慢板/夜曲 是兩回事
            if wantCalm || wantEnergy {
                let fast = tempoFast.contains { hay.contains($0) }
                let slow = tempoSlow.contains { hay.contains($0) }
                if wantCalm { s += (fast ? -5.0 : 0) + (slow ? 2.5 : 0) }
                else        { s += (fast ?  2.0 : 0) + (slow ? -3.0 : 0) }
            }

            s += feedback.artistWeight[t.artist] ?? 0
            s += feedback.albumWeight[t.album] ?? 0
            s += feedback.genreWeight[g] ?? 0

            // 近期播過的降權，6 小時衰減完
            if let at = recent[t.id] { s -= 6.0 * exp(-(now - at) / 21600) }

            scored.append((s, t))
        }
        guard !scored.isEmpty else { return [] }
        scored.sort { $0.0 > $1.0 }

        var pool = Array(scored.prefix(max(n * 12, 120)))   // 只從前段抽
        let lo = pool.map(\.0).min() ?? 0
        var out: [LibTrack] = []
        var artistCount: [String: Int] = [:]
        var seenSong = Set<String>()
        var tries = 0
        while out.count < n, !pool.isEmpty, tries < n * 60 {
            tries += 1
            let weights = pool.map { pow(max($0.0 - lo, 0), 2) + 0.35 }
            let total = weights.reduce(0, +)
            var r = Double.random(in: 0..<total)
            var idx = 0
            for (i, w) in weights.enumerated() {
                r -= w
                if r <= 0 { idx = i; break }
                idx = i
            }
            let (_, t) = pool.remove(at: idx)
            let key = t.name.lowercased().trimmed + "|" + t.artist.lowercased().trimmed
            if seenSong.contains(key) { continue }               // 資料庫有重複收錄
            if (artistCount[t.artist] ?? 0) >= 2 { continue }
            seenSong.insert(key)
            artistCount[t.artist, default: 0] += 1
            out.append(t)
        }
        return out
    }
}
