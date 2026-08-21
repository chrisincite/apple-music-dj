import Foundation
import ApplicationServices

/// 探索到、但還沒進資料庫的候選曲。
struct Candidate: Equatable {
    var trackId: Int = 0
    var name: String = ""
    var artist: String = ""
    var album: String = ""
    var genre: String = ""          // 一律英文（lang=en_us），與資料庫的 genre 同一套詞彙
    var duration: Double = 0
    var url: String = ""            // music:// 深連結
    var source: String = ""         // artist / chart

    var key: String { Explorer.key(name, artist) }
}

/// 探索新曲目：iTunes Search API 找候選 → URL Scheme 導覽 Music.app →
/// 無障礙點「更多 → 加入資料庫」→ 歌進了資料庫就有真的 database ID，
/// 之後完全走既有的 DJ 佇列邏輯。
///
/// 為什麼要繞這一圈：直接用 URL Scheme 播目錄歌是可行的，但那首歌對
/// AppleScript 而言是 `URL track`（cloud status 是 missing value、container
/// 是 Scripting），既排不進播放清單也 duplicate 不了，👍👎 也綁不住 ID。
/// 只有真的加進資料庫，才拿得到可排隊的 track。
enum Explorer {

    // MARK: 基本工具

    static func key(_ name: String, _ artist: String) -> String {
        (name.lowercased().trimmed) + "|" + (artist.lowercased().trimmed)
    }

    /// iTunes Search API 的 storefront。用系統地區，找不到就退回 tw。
    static var storefront: String {
        let r = Locale.current.region?.identifier.lowercased() ?? "tw"
        return r.isEmpty ? "tw" : r
    }

    private static func httpJSON(_ urlString: String, timeout: TimeInterval = 12) -> Any? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.setValue("AppleMusicDJ/2.1", forHTTPHeaderField: "User-Agent")
        var result: Any?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, _, _ in
            defer { sem.signal() }
            guard let data, !data.isEmpty else { return }
            result = try? JSONSerialization.jsonObject(with: data)
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 2)
        return result
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func urlEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
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
            // 只累加正貢獻，避免大量中性曲目把冷門好藝人稀釋掉
            score[t.artist] = max(score[t.artist] ?? -99, s)
        }
        return score.filter { $0.value > 0.5 }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map(\.key)
    }

    private static func parseResults(_ json: Any?, source: String) -> [Candidate] {
        guard let obj = json as? [String: Any],
              let arr = obj["results"] as? [[String: Any]] else { return [] }
        return arr.compactMap { r in
            guard (r["wrapperType"] as? String) == "track" || r["trackId"] != nil,
                  let name = r["trackName"] as? String,
                  let artist = r["artistName"] as? String,
                  let view = r["trackViewUrl"] as? String,
                  let tid = r["trackId"] as? Int else { return nil }
            if let streamable = r["isStreamable"] as? Bool, streamable == false { return nil }
            let ms = (r["trackTimeMillis"] as? Double) ?? 0
            return Candidate(trackId: tid, name: name, artist: artist,
                             album: (r["collectionName"] as? String) ?? "",
                             genre: (r["primaryGenreName"] as? String) ?? "",
                             duration: ms / 1000,
                             url: deepLink(view), source: source)
        }
    }

    /// trackViewUrl → music:// 深連結。用 music:// 而非 https://，
    /// 才不會被瀏覽器攔截（實測兩者在 Music.app 內行為一致：只導覽、不播放、不中斷正在播的歌）。
    private static func deepLink(_ viewURL: String) -> String {
        var s = viewURL
        // uo=4 是 affiliate 參數；l=en 是 lang=en_us 帶出來的，留著會讓 Music.app
        // 用英文渲染那一頁，無障礙比對的按鈕描述就對不上了
        for junk in ["&uo=4", "?uo=4", "&l=en", "?l=en"] {
            s = s.replacingOccurrences(of: junk, with: "")
        }
        if s.hasPrefix("https://") { s = "music://" + s.dropFirst("https://".count) }
        return s
    }

    /// 同藝人的未收錄曲。實測這是品質最穩的一條：
    /// 泛用關鍵字搜尋（例如 "ambient piano"）回來的多半是罐頭音樂。
    private static func byArtist(_ artist: String, limit: Int = 50) -> [Candidate] {
        let u = "https://itunes.apple.com/search?term=\(urlEncode(artist))"
            + "&attribute=artistTerm&entity=song&limit=\(limit)"
            + "&country=\(storefront)&lang=en_us"
        return parseResults(httpJSON(u), source: "artist")
            // artistTerm 會把合輯／同名藝人也撈進來，名字要對得起來
            .filter { $0.artist.lowercased().trimmed == artist.lowercased().trimmed }
    }

    /// 曲風排行榜：真正會冒出「沒聽過的藝人」的那條，代價是命中率較低。
    private static func byGenreChart(_ genreID: Int, limit: Int = 40) -> [Candidate] {
        let u = "https://itunes.apple.com/\(storefront)/rss/topsongs/limit=\(limit)/genre=\(genreID)/json"
        guard let obj = httpJSON(u) as? [String: Any],
              let feed = obj["feed"] as? [String: Any] else { return [] }
        let entries = (feed["entry"] as? [[String: Any]]) ?? []
        let ids: [String] = entries.compactMap {
            (($0["id"] as? [String: Any])?["attributes"] as? [String: Any])?["im:id"] as? String
        }
        guard !ids.isEmpty else { return [] }
        // RSS 只給本地化曲風名，補一次 lookup 才拿得到英文 genre 與時長
        let u2 = "https://itunes.apple.com/lookup?id=\(ids.prefix(40).joined(separator: ","))"
            + "&country=\(storefront)&lang=en_us"
        return parseResults(httpJSON(u2, timeout: 15), source: "chart")
    }

    /// vibe 命中的曲風 → iTunes RSS 的 genre id（TW/JP storefront 實測對照）
    static let chartGenreID: [String: Int] = [
        "Classical": 5, "Opera": 5, "Classical Crossover": 5,
        "New Age": 13, "Ambient": 13, "Piano": 53,
        "Jazz": 11, "Smooth Jazz": 11, "Bossa Nova": 12,
        "Reggae": 24, "Rock": 21, "Pop": 14, "R&B/Soul": 15,
        "Soundtrack": 16, "Anime": 29, "J-Pop": 27,
        "Worldwide": 19, "Easy Listening": 25,
    ]

    // MARK: 篩選

    /// 用同一套 TrackPicker 規則替候選打分；<= 0 的直接不要，
    /// 免得探索把不合 vibe 的東西塞進你的資料庫。
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
            if c.duration < 45 || c.duration > 900 { continue }
            if libraryKeys.contains(c.key) || seen.contains(c.key) { continue }
            if dedup.contains(c.key) { continue }
            let g = TrackPicker.genreAlias[c.genre] ?? c.genre
            var s = gw[g] ?? 0
            s += feedback.artistWeight[c.artist] ?? 0
            s += feedback.genreWeight[g] ?? 0
            // 同藝人延伸本身就是強訊號：曲風中性也放行，但曲風被 vibe 明確排斥就不行
            if c.source == "artist" {
                if s <= -1.0 { continue }
                s += 1.5
            } else if s <= 0 {
                continue
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

    /// 完整的候選蒐集。回傳已排序、已過濾的候選。
    static func candidates(library: [LibTrack], playlists: [String: [String]],
                           vibe: String, feedback: Feedback,
                           seen: Set<String>, wide: Bool) -> [Candidate] {
        guard !vibe.isEmpty, !library.isEmpty else { return [] }
        let libraryKeys = Set(library.map { key($0.name, $0.artist) })
        var pool: [Candidate] = []

        let seeds = seedArtists(library: library, playlists: playlists,
                                vibe: vibe, feedback: feedback, limit: 14)
        for a in seeds.shuffled().prefix(3) { pool += byArtist(a) }

        if wide {
            let gw = TrackPicker.genreWeights(vibe)
            let topGenres = gw.filter { $0.value > 0 }.sorted { $0.value > $1.value }.prefix(3)
            var usedIDs = Set<Int>()
            for (g, _) in topGenres {
                guard let gid = chartGenreID[g], !usedIDs.contains(gid) else { continue }
                usedIDs.insert(gid)
                pool += byGenreChart(gid)
                if usedIDs.count >= 2 { break }
            }
        }

        let scored = filter(pool, vibe: vibe, feedback: feedback,
                            libraryKeys: libraryKeys, seen: seen)
        return diversify(scored)
    }

    /// 同一位藝人最多兩首，並加一點隨機擾動 ——
    /// 不這樣做的話 artistTerm 會讓某一位藝人整批洗版，
    /// 每次探索都從同一個人身上挖，等於沒在探索。
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

    // MARK: 加進資料庫

    enum AddError: Error, CustomStringConvertible {
        case noWindow, notFound, menuFailed, notAdded, noAccessibility
        var description: String {
            switch self {
            case .noWindow: return "Music.app 沒有可用視窗"
            case .notFound: return "頁面上找不到這首歌"
            case .menuFailed: return "點不到「更多」選單"
            case .notAdded: return "按了但資料庫沒長出這首歌"
            case .noAccessibility: return "需要「輔助使用」權限"
            }
        }
    }

    /// 是否已取得輔助使用權限。
    ///
    /// 注意這裡不能只問「System Events 回不回話」—— 送 Apple Event 給 System Events
    /// 屬於「自動化」權限，讀別的 app 的 UI 元素才是「輔助使用」，兩者是分開的兩格。
    /// 只檢查前者的話，探索會在 app 裡整批靜靜失敗，而在終端機跑的測試程式卻正常
    /// （因為那時被歸屬的是終端機，它早就有權限了）。
    /// `prompt: true` 會叫出系統授權對話框，並把本 app 列進「輔助使用」清單。
    static func accessibilityGranted(prompt: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        guard AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary) else { return false }
        // 再確認真的讀得到別的 app 的 UI 樹（權限剛撤銷時 AXIsProcessTrusted 會慢半拍）
        return MusicBridge.run("""
        tell application "System Events"
          try
            return (count of windows of process "Music") as text
          on error
            return "no"
          end try
        end tell
        """, timeout: 20) != "no"
    }

    /// 讓介面能主動請求權限（第一次開探索時用）。
    @discardableResult
    static func requestAccessibility() -> Bool { accessibilityGranted(prompt: true) }

    /// 把候選曲加進資料庫，成功則回傳它在資料庫裡的 LibTrack。
    ///
    /// 有幾個實測出來的前提：
    /// 1. 導覽不會中斷正在播的歌 —— 探索可以在 DJ 播歌的同時進行。
    /// 2. 專輯頁的「加入資料庫」按鈕是整張加（實測 13 首），所以要走單曲列的「更多」選單。
    /// 3. 那顆選單 Music.app 沒有暴露給無障礙 API，只能用鍵盤選第一項；
    ///    因此呼叫端必須確定這首歌「不在資料庫裡」（在的話第一項會變成移除）。
    /// 4. 曲目清單是虛擬化的，只有畫面內的列在無障礙樹裡 → 必須捲動掃描。
    /// 5. 古典樂誌面只寫樂章名（頁面是「II. Adagio」，API 是
    ///    「Violin Concerto in E Major, BWV 1042: II. Adagio」）→ 比對要放寬，
    ///    再用時長把同名樂章區分開。
    static func add(_ c: Candidate) -> Result<LibTrack, AddError> {
        guard accessibilityGranted() else { return .failure(.noAccessibility) }

        // 記住原本在前景的 app，做完還回去：探索不該打斷手上的工作
        let front = MusicBridge.run(
            "tell application \"System Events\" to return name of first process whose frontmost is true",
            timeout: 10) ?? ""

        _ = MusicBridge.run("do shell script \"open \" & quoted form of \"\(esc(c.url))\"", timeout: 15)
        Thread.sleep(forTimeInterval: 4.5)

        let alt = movementTitle(c.name)
        let durs = durationLabels(c.duration)
        let pressed = MusicBridge.run(locateAndAddScript(
            full: c.name, alt: alt, durations: durs), timeout: 150)

        restoreFront(front)

        guard pressed == "ok" else {
            // 選單可能開著沒關，補一下 Esc 免得卡住後續操作
            _ = MusicBridge.run("tell application \"System Events\" to key code 53", timeout: 10)
            return .failure(pressed == "notfound" ? .notFound : .menuFailed)
        }

        // iCloud 同步要幾秒才看得到，實測約 5～10 秒
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            if let t = MusicBridge.findTrack(name: c.name, artist: c.artist) { return .success(t) }
            Thread.sleep(forTimeInterval: 1.2)
        }
        return .failure(.notAdded)
    }

    /// 「Violin Concerto…: II. Adagio」→「II. Adagio」。誌面上只印樂章名。
    static func movementTitle(_ name: String) -> String {
        for sepStr in [": ", " - ", " – "] {
            if let r = name.range(of: sepStr, options: .backwards) {
                let tail = String(name[r.upperBound...]).trimmed
                if tail.count >= 3 { return tail }
            }
        }
        return ""
    }

    /// Music.app 顯示的時長字串。API 的毫秒跟誌面偶爾差一秒，兩種都收。
    static func durationLabels(_ seconds: Double) -> [String] {
        guard seconds > 0 else { return [] }
        let candidates = [Int(seconds), Int(seconds.rounded())]
        var out: [String] = []
        for s in Set(candidates).sorted() {
            out.append("\(s / 60):" + String(format: "%02d", s % 60))
        }
        return out
    }

    /// 捲動掃描 → 找到那一列 → 點「更多」→ 鍵盤選第一項（加入資料庫）。
    /// 全部塞在同一支 AppleScript 裡跑：分次呼叫的話畫面會在中間變動，
    /// 上一次拿到的座標就作廢了。
    private static func locateAndAddScript(full: String, alt: String,
                                           durations: [String]) -> String {
        let durList = durations.map { "\"\(esc($0))\"" }.joined(separator: ", ")
        return """
        tell application "Music" to activate
        delay 1.0
        tell application "System Events"
          tell process "Music"
            if (count of windows) is 0 then return "notfound"
            set fullName to "\(esc(full))"
            set altName to "\(esc(alt))"
            set durs to {\(durList.isEmpty ? "\"\"" : durList)}

            -- 內容區是最寬的那個 scroll area（另一個是側邊欄）
            set contentSA to missing value
            set widest to 0
            repeat with sa in (every scroll area of splitter group 1 of window 1)
              try
                set sz to (size of sa)
                if (item 1 of sz) > widest then
                  set widest to (item 1 of sz)
                  set contentSA to sa
                end if
              end try
            end repeat

            set positions to {0.0, 0.15, 0.32, 0.5, 0.7, 0.92}
            repeat with idx from 1 to (count of positions)
              if contentSA is not missing value and idx > 1 then
                try
                  set value of scroll bar 1 of contentSA to (item idx of positions)
                end try
                delay 0.7
              end if

              if contentSA is missing value then
                set ec to entire contents of window 1
              else
                set ec to entire contents of contentSA
              end if
              -- 先收集所有靜態文字的 y 與內容
              set ys to {}
              set vs to {}
              repeat with e in ec
                try
                  if (class of e) is static text then
                    set v to ""
                    try
                      set v to (value of e)
                    end try
                    if v is not "" then
                      set p to (position of e)
                      set end of ys to (item 2 of p)
                      set end of vs to v
                    end if
                  end if
                end try
              end repeat

              -- 找標題列：完整曲名 / 樂章名 / 被截斷的前綴
              set bestY to -1
              set exactY to -1
              repeat with i from 1 to (count of vs)
                set v to (item i of vs)
                set hit to false
                if v is fullName then
                  set hit to true
                else if altName is not "" and v is altName then
                  set hit to true
                else if (length of v) ≥ 10 and fullName starts with v then
                  set hit to true
                end if
                if hit then
                  set thisY to (item i of ys)
                  if bestY is -1 then set bestY to thisY
                  -- 同一列若也印著預期時長，就是唯一解（同名樂章用這招分辨）
                  if (count of durs) > 0 then
                    repeat with j from 1 to (count of vs)
                      set dy to (item j of ys)
                      if dy ≥ (thisY - 4) and dy ≤ (thisY + 4) then
                        if durs contains (item j of vs) then set exactY to thisY
                      end if
                    end repeat
                  end if
                end if
              end repeat
              if exactY is not -1 then set bestY to exactY

              if bestY is not -1 then
                repeat with e in ec
                  try
                    if (class of e) is button then
                      set d to ""
                      try
                        set d to (description of e)
                      end try
                      if d is "更多" or d is "More" then
                        set p to (position of e)
                        set yy to (item 2 of p)
                        if yy ≥ (bestY - 4) and yy ≤ (bestY + 4) then
                          click e
                          delay 1.2
                          key code 125
                          delay 0.35
                          key code 36
                          return "ok"
                        end if
                      end if
                    end if
                  end try
                end repeat
                return "nomenu"
              end if
            end repeat
            return "notfound"
          end tell
        end tell
        """
    }

    private static func restoreFront(_ name: String) {
        guard !name.isEmpty, name != "Music", name != "音樂" else { return }
        _ = MusicBridge.run(
            "tell application \"System Events\" to set frontmost of process \"\(esc(name))\" to true",
            timeout: 10)
    }

}
