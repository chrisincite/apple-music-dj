import Foundation

/// Apple Music 的 HTTP 介面。
///
/// 探索原本是用無障礙 API 去點 Music.app 的「更多 → 加入資料庫」，
/// 那條路要 21 秒、需要輔助使用權限、會把 Music 叫到前景打斷你手上的事，
/// 而且那顆選單卡住時 Music.app 會停止回應 Apple Event，整個 DJ 跟著卡死。
/// 改走這裡之後同一件事是 1.3 秒的一個 POST，前景完全不動。
///
/// 兩個憑證：
/// - **developer token**：music.apple.com 網頁播放器的公開 token（`iss: AMPWebPlay`），
///   直接從它的 JS bundle 撈，不需要 Apple Developer 帳號。約兩個月效期，會自動重抓。
/// - **music user token**：你自己的憑證，要手動放進設定檔一次（見 README）。
///   只有寫入資料庫需要它；純目錄搜尋不用。
enum AppleMusicAPI {

    static let origin = "https://music.apple.com"
    static let ampHost = "https://amp-api.music.apple.com"

    /// 使用者 token 的位置。跟其他工具的慣例一致，放在 ~/.config 底下。
    static var userTokenURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/apple-music-dj/media_user_token")
    }

    /// 不直接用 Engine.dir：那個屬於 main actor，這裡跑在背景佇列。
    private static var cacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/apple-music-dj/state/web_token.json")
    }

    // MARK: 憑證

    static func userToken() -> String? {
        guard let raw = try? String(contentsOf: userTokenURL, encoding: .utf8) else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    static var hasUserToken: Bool { userToken() != nil }

    private struct CachedToken: Codable { var token: String; var exp: Double }

    /// 快取在 state 目錄。JWT 自己帶 exp，剩不到 15 天就提早換新的，
    /// 免得剛好在你聽歌時過期。
    private static func cachedDeveloperToken() -> String? {
        guard let d = try? Data(contentsOf: cacheURL),
              let c = try? JSONDecoder().decode(CachedToken.self, from: d) else { return nil }
        guard c.exp - Date().timeIntervalSince1970 > 15 * 86400 else { return nil }
        return c.token
    }

    private static func cache(_ token: String) {
        let exp = jwtExpiry(token) ?? (Date().timeIntervalSince1970 + 30 * 86400)
        guard let d = try? JSONEncoder().encode(CachedToken(token: token, exp: exp)) else { return }
        try? d.write(to: cacheURL, options: .atomic)
    }

    private static func jwtExpiry(_ jwt: String) -> Double? {
        let parts = jwt.components(separatedBy: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+")
                          .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = obj["exp"] as? Double else { return nil }
        return exp
    }

    /// 抓網頁播放器的 bundle，把裡面的 JWT 撈出來。bundle 檔名帶 hash 會隨改版變動，
    /// 所以要先讀首頁找出當下的檔名。
    private static func harvestDeveloperToken() -> String? {
        guard let page = get("\(origin)/tw/new", headers: [:], asString: true) as? String else { return nil }
        guard let r = page.range(of: #"/assets/index~[A-Za-z0-9]+\.js"#, options: .regularExpression)
        else { return nil }
        let bundlePath = String(page[r])
        guard let js = get(origin + bundlePath, headers: [:], asString: true) as? String else { return nil }
        let pattern = #"eyJ[A-Za-z0-9_-]{30,}\.[A-Za-z0-9_-]{30,}\.[A-Za-z0-9_-]{20,}"#
        guard let jr = js.range(of: pattern, options: .regularExpression) else { return nil }
        return String(js[jr])
    }

    static func developerToken(forceRefresh: Bool = false) -> String? {
        if !forceRefresh, let c = cachedDeveloperToken() { return c }
        guard let t = harvestDeveloperToken() else { return cachedDeveloperToken() }
        cache(t)
        return t
    }

    // MARK: HTTP

    private static func request(_ urlString: String, method: String = "GET",
                                headers: [String: String], timeout: TimeInterval = 15)
        -> (status: Int, data: Data?) {
        guard let url = URL(string: urlString) else { return (0, nil) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        var status = 0
        var body: Data?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { d, resp, _ in
            status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            body = d
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 3)
        return (status, body)
    }

    private static func get(_ url: String, headers: [String: String], asString: Bool = false) -> Any? {
        let (status, data) = request(url, headers: headers, timeout: 20)
        guard status == 200, let data else { return nil }
        return asString ? String(data: data, encoding: .utf8) : try? JSONSerialization.jsonObject(with: data)
    }

    /// 目錄讀取只需要 developer token。401/403 代表 token 過期，重抓一次再試。
    private static func amp(_ path: String, retrying: Bool = false) -> [String: Any]? {
        guard let dev = developerToken(forceRefresh: retrying) else { return nil }
        var h = ["Authorization": "Bearer \(dev)", "Origin": origin]
        if let mut = userToken() { h["Music-User-Token"] = mut }
        let (status, data) = request(ampHost + path, headers: h, timeout: 20)
        if (status == 401 || status == 403) && !retrying { return amp(path, retrying: true) }
        guard status == 200, let data else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: 加入資料庫

    enum AddError: Error, CustomStringConvertible {
        case noUserToken, unauthorized, failed(Int)
        var description: String {
            switch self {
            case .noUserToken:
                return "還沒設定 Apple Music token（見 README「探索新曲目」一節）"
            case .unauthorized:
                return "Apple Music token 失效了，請重新取得一次"
            case .failed(let s):
                return "Apple Music 回了 HTTP \(s)"
            }
        }
    }

    /// 把目錄裡的歌加進資料庫。回傳成功與否；歌要等 iCloud 同步才會出現在 Music.app，
    /// 呼叫端要自己輪詢 `MusicBridge.findTrack`。
    static func addToLibrary(songID: String, retrying: Bool = false) -> Result<Void, AddError> {
        guard let mut = userToken() else { return .failure(.noUserToken) }
        guard let dev = developerToken(forceRefresh: retrying) else { return .failure(.failed(0)) }
        let path = "/v1/me/library?ids%5Bsongs%5D=\(songID)"
        let (status, _) = request(ampHost + path, method: "POST", headers: [
            "Authorization": "Bearer \(dev)",
            "Music-User-Token": mut,
            "Content-Type": "application/json",
            "Origin": origin,
        ], timeout: 25)
        // 202 = 已接受（非同步入庫），200/204 也當成功
        if status == 202 || status == 200 || status == 204 { return .success(()) }
        if status == 401 || status == 403 {
            // token 可能只是過期，重抓 developer token 再試一次；還是不行才算失效
            if !retrying { return addToLibrary(songID: songID, retrying: true) }
            return .failure(.unauthorized)
        }
        return .failure(.failed(status))
    }

    /// 探索前先確認憑證還活著，免得整批失敗才發現。
    static func sessionOK() -> Bool {
        guard hasUserToken else { return false }
        guard let dev = developerToken() else { return false }
        var h = ["Authorization": "Bearer \(dev)", "Origin": origin]
        h["Music-User-Token"] = userToken()
        let (status, _) = request(ampHost + "/v1/me/storefront", headers: h, timeout: 15)
        if status == 200 { return true }
        guard let dev2 = developerToken(forceRefresh: true) else { return false }
        h["Authorization"] = "Bearer \(dev2)"
        return request(ampHost + "/v1/me/storefront", headers: h, timeout: 15).status == 200
    }

    // MARK: 目錄查詢

    static var storefront: String {
        let r = Locale.current.region?.identifier.lowercased() ?? "tw"
        return r.isEmpty ? "tw" : r
    }

    /// 曲風名一定要英文，才跟資料庫（Music.app 回的是英文 genre）與 TrackPicker
    /// 的曲風詞典同一套詞彙。但**各地區支援的語言標籤不一樣**：台灣只有
    /// `zh-Hant-TW` 與 `en-GB`，寫死 `l=en-US` 會被無聲忽略、回中文曲風，
    /// 於是所有評分都對不上。所以要先問這個 storefront 支援哪個英文標籤。
    private nonisolated(unsafe) static var cachedLang: String?
    static var englishTag: String {
        if let c = cachedLang { return c }
        var tag = "en-GB"
        if let root = amp("/v1/storefronts/\(storefront)"),
           let data = root["data"] as? [[String: Any]],
           let attrs = data.first?["attributes"] as? [String: Any],
           let tags = attrs["supportedLanguageTags"] as? [String] {
            if tags.contains("en-US") { tag = "en-US" }
            else if let en = tags.first(where: { $0.lowercased().hasPrefix("en") }) { tag = en }
        }
        cachedLang = tag
        return tag
    }

    private static func esc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }

    /// Apple 自己的曲目物件 → 我們的候選。
    static func songs(from json: [String: Any]?) -> [Candidate] {
        guard let arr = json?["data"] as? [[String: Any]] else { return [] }
        return arr.compactMap { item in
            guard let id = item["id"] as? String,
                  let a = item["attributes"] as? [String: Any],
                  let name = a["name"] as? String,
                  let artist = a["artistName"] as? String else { return nil }
            // 沒有 playParams 代表這首在你的區域不能播
            if a["playParams"] == nil { return nil }
            let ms = (a["durationInMillis"] as? Double) ?? 0
            let genres = (a["genreNames"] as? [String]) ?? []
            return Candidate(songID: id, name: name, artist: artist,
                             album: (a["albumName"] as? String) ?? "",
                             genre: genres.first ?? "",
                             allGenres: genres,
                             duration: ms / 1000, source: "")
        }
    }

    static func searchSongs(_ term: String, limit: Int = 25) -> [Candidate] {
        let path = "/v1/catalog/\(storefront)/search?term=\(esc(term))&types=songs&limit=\(limit)&l=\(englishTag)"
        guard let root = amp(path),
              let results = root["results"] as? [String: Any],
              let songs = results["songs"] as? [String: Any] else { return [] }
        return AppleMusicAPI.songs(from: songs).map { var c = $0; c.source = "search"; return c }
    }

    /// 先用搜尋找到藝人，再取他的代表曲。這是「你已經在聽的人，還有什麼你沒收」。
    static func artistTopSongs(_ artist: String, limit: Int = 20) -> [Candidate] {
        let path = "/v1/catalog/\(storefront)/search?term=\(esc(artist))&types=artists&limit=1&l=\(englishTag)"
        guard let root = amp(path),
              let results = root["results"] as? [String: Any],
              let artists = results["artists"] as? [String: Any],
              let data = artists["data"] as? [[String: Any]],
              let aid = data.first?["id"] as? String else { return [] }
        let p2 = "/v1/catalog/\(storefront)/artists/\(aid)/view/top-songs?limit=\(limit)&l=\(englishTag)"
        return songs(from: amp(p2)).map { var c = $0; c.source = "artist"; return c }
    }

    /// Apple 自己算的相似藝人 —— iTunes Search API 沒有這個，
    /// 這是「冒出沒聽過的人」但又不至於離題的來源。
    static func similarArtists(_ artist: String, limit: Int = 6) -> [String] {
        let path = "/v1/catalog/\(storefront)/search?term=\(esc(artist))&types=artists&limit=1&l=\(englishTag)"
        guard let root = amp(path),
              let results = root["results"] as? [String: Any],
              let artists = results["artists"] as? [String: Any],
              let data = artists["data"] as? [[String: Any]],
              let aid = data.first?["id"] as? String else { return [] }
        let p2 = "/v1/catalog/\(storefront)/artists/\(aid)/view/similar-artists?limit=\(limit)&l=\(englishTag)"
        guard let r2 = amp(p2), let arr = r2["data"] as? [[String: Any]] else { return [] }
        return arr.compactMap { ($0["attributes"] as? [String: Any])?["name"] as? String }
    }
}
