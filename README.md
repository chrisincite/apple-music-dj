# Apple Music DJ

<img src="docs/icon.png" width="104" align="right" alt="Apple Music DJ 圖示">

一支常駐在螢幕角落的小 app，依你打的一句「氛圍」持續幫 Apple Music 排歌。
說一句「深夜寫程式，安靜不要有人聲」，它就自己維持一份 12 首的佇列，播到剩不到 8 首自動補，
你按 👍👎 它會學。開著「探索新曲目」的話，它還會定期去 Apple Music 目錄挖一首你資料庫裡
沒有的歌，加進資料庫再排進佇列。

> A tiny macOS menu-less app that DJs your Apple Music library from a plain-language vibe.
> Rule-based selection, no API keys, no LLM calls, no network.

<p align="center">
  <img src="docs/panel.png" width="420" alt="展開的小窗：正在播的歌與進度、👍👎＋⏭ 四顆按鈕、目前氛圍、換氛圍的輸入框，下面是接下來的佇列">
</p>

靈感來自 [Nick Baumann 用 Codex DJ Spotify 的做法](https://x.com/nickbaumann_/status/2090551906657517876)。
差別在於 Spotify 有佇列 API 可用，Apple Music 沒有——所以這裡走的是 AppleScript 原生路線，
佇列的實體就是 Music.app 裡一個叫「🎧 DJ」的播放清單。

## 安裝

到 [Releases](../../releases) 下載 `AppleMusicDJ-*.dmg`，把 app 拖進 Applications。

第一次開啟會被 macOS 擋（「無法驗證開發者」）——這支 app 沒有經過 Apple 公證。
在 Applications 裡對它**按右鍵 →「打開」→ 再按一次「打開」**，只需做這一次。

啟動後會問「Apple Music DJ 想要控制『音樂』」，必須允許。

要用〈探索新曲目〉的話還要設定一次 Apple Music token，見下面。沒設定的話探索會自己
關掉，並在小窗與 `dj now` 顯示原因，不會靜靜失敗。

### 需求

- macOS 13 以上、Apple Silicon
- Apple Music 訂閱，且**「同步資料庫」要開啟**（音樂 App → 設定 → 一般 → 同步資料庫）
- 排歌本身只用你**已加入資料庫**的歌；要它去目錄挖新歌，見下面的〈探索新曲目〉
  （那個功能要設定一次 Apple Music token）

## 用法

展開小窗（右上 `⌄`），在輸入框打一句氛圍就好：

```
深夜寫程式，安靜不要有人聲
早晨咖啡
夏天海邊
放鬆但不要古典
想聽聖誕鋼琴
```

六顆按鈕，左邊三顆是走帶控制、右邊三顆是回饋：

**▶︎/⏸** 播放／暫停 —— 沒在播的時候按下去就是**從 app 啟動 DJ**（不必重打氛圍）／
**⏹** 停止播放並關掉 DJ（必須同時關 DJ，否則下一次心跳會自己把音樂接回去）／
**⏭** 跳過｜**👍** 之後多排這種／**👎** 封鎖這首並少排這類（同時跳過）／
**＋** 存進「🎧 DJ 精選」。

展開區有「接下來／剛剛播過」兩個分頁，以及探索的開關。佇列裡開頭是 ✨ 的，
就是探索挖回來的新歌。

### 命令列（選用）

`cli/dj` 是同一套狀態的遙控器，適合從終端機或腳本控制：

```bash
ln -s "$PWD/cli/dj" ~/.local/bin/dj

dj on "深夜寫程式"     # 設氛圍並開啟小窗
dj vibe "早晨咖啡"     # 換氛圍
dj now                 # 現在播什麼＋接下來 10 首
dj history             # 剛剛播過的歌
dj up / down / keep / skip
dj play / stop         # ▶︎/⏸ 切換播放、⏹ 停止並關 DJ
dj explore             # ✨ 立刻探索一首新歌
dj explore on|off      # 自動探索開關
dj explore wide on|off # 探索是否也撈曲風排行榜
```

## 選曲怎麼決定

純規則、不呼叫模型、不連網。每首歌的分數來自六層：

1. **氛圍詞典** — 16 組關鍵字（專注／深夜／早晨／放鬆／振奮／失戀／懷舊／古典／
   爵士／雷鬼／抒情…）對應曲風加減分，中英皆可。
2. **你自己的播放清單名稱** — vibe 與清單名有共同詞就大幅加權。
   這是實測最強的訊號：「失戀時聽的周杰倫」這種清單名本身就是最好的語意標籤，
   比任何曲風分類都準。
3. **否定詞** — 「不要有人聲」「放鬆但不要古典」會反向計分（認得
   `不要／不想／別放／避開／no／without`）。
4. **速度標記** — 古典曲名本身就寫著這首吵不吵。`Allegro／Presto／Marsch／
   Polka schnell／Scherzo` 重罰，`Adagio／Andante／Largo／Sarabande／Nocturne／
   Prélude` 加分；vibe 屬於「要安靜」那類時自動啟用，要熱血時反向。
   這是規則式選曲唯一能看出「同一曲風裡性格差很多」的切入點。
5. **回饋學習** — 👍 加權該藝人＋專輯＋曲風，👎 封鎖該曲並降權該藝人。權重上下限 ±6。
6. **重複與時節** — 近 6 小時播過的指數衰減降權、同一批同藝人最多 2 首、
   同名同藝人去重；聖誕／賀歲曲平常重罰，除非 vibe 明講。

最後是**加權隨機抽樣**（分數平方為權重，只從前段候選抽），所以同一個 vibe
不會每次都給一模一樣的歌單。

## 探索新曲目

預設開著。**每補 10 首歌，其中 1 首**是你資料庫裡沒有的新歌 —— 它從 Apple Music 目錄
挑一首、加進你的資料庫，再排進佇列（佇列裡標成 ✨）。展開小窗可以關掉，或按 ✨
立刻跑一次。

為什麼是 1/10 而不是每首都探索：一首歌約 4 分鐘，每次補位都探索等於**每小時往你的
資料庫塞 15 首**。那不只讓資料庫變肥，還會稀釋掉「拿氛圍比對你自己的播放清單名稱」
這個最強的選曲訊號 —— 探索來的歌不在任何清單裡。

候選有兩條線：

- **同藝人延伸**（預設）— 由當下氛圍高分的藝人出發，取他們的代表曲，挑你還沒收的。
  命中率最高、風格最穩。
- **相似藝人**（勾「含相似藝人」才開）— 用 Apple 自己算的 similar-artists 再往外一層。
  這條才會冒出沒聽過的人，代價是命中率低一截。

候選一律再走一次 `TrackPicker` 的評分（曲風權重、否定詞、速度標記、節慶曲、回饋權重），
分數 ≤ 0 的不要 —— 探索不該把不合氛圍的東西塞進你的資料庫。同一位藝人最多兩首，
分數再加一點隨機擾動，否則同一個人會整批洗版。

### 設定 Apple Music token

只要做一次。目錄搜尋不需要它，**把歌加進資料庫**才需要。

在瀏覽器開 [music.apple.com](https://music.apple.com) 並確認已登入（這跟 Music.app
的登入是分開的），打開開發者工具的 Console，執行：

```js
copy(MusicKit.getInstance().musicUserToken)
```

`copy()` 是開發者工具的內建函式，會把值直接放進剪貼簿而不顯示出來。然後在終端機：

```bash
pbpaste > ~/.config/apple-music-dj/media_user_token
scripts/check-token.sh          # 應該回「✓ token 有效」與你的 storefront
```

`scripts/check-token.sh` 不會印出 token 內容，可以放心重跑。token 大約半年後過期，
到時探索會停下來並在 `dj now` 說明，重跑上面兩行即可。

另一個憑證（developer token）是 music.apple.com 網頁播放器的公開 token，app 會自己
從它的 JS bundle 抓、快取起來、快過期時自動換新，**不需要 Apple Developer 帳號**。

### 為什麼要「加進資料庫」這一步

目錄裡的歌用 URL Scheme 確實可以直接播，但那首歌對 AppleScript 而言是個幽靈：
`class` 是 `URL track`、`cloud status` 是 `missing value`、`container` 是 `Scripting`。
它排不進播放清單，`duplicate` 會被 `Can only duplicate subscription tracks to
library source` 擋掉，👍👎 也綁不住 ID。只有真的加進資料庫，才拿得到可排隊的曲目。

加入這一步走 Apple Music 的 web API（`POST /v1/me/library`），實測 1.3 秒、
全程不動前景。**2.1 曾經是用無障礙 API 去點 Music.app 的「更多 → 加入資料庫」**，
那條路要 21 秒、需要輔助使用權限、會把 Music 叫到前景打斷你手上的事，而且那顆選單
卡住時 Music.app 會停止回應 Apple Event、整個 DJ 跟著卡死。已經整段移除。

## 架構

```
Apple Music DJ.app
├─ Engine        15 秒心跳：補佇列、吃回饋、記錄播放歷史
├─ TrackPicker   選曲評分（上面那六層）
├─ Explorer      探索新曲目（挑候選、評分、加進資料庫）
├─ AppleMusicAPI Apple Music web API（目錄搜尋、加入資料庫、憑證管理）
├─ MusicBridge   AppleScript 橋接（osascript 子行程）
└─ PanelView     SwiftUI 浮動小窗
        │
        └─→ ~/Library/Application Support/apple-music-dj/state/
              state.json · history.jsonl · feedback.jsonl · nowplaying.json
                        ↑ CLI 從這裡讀寫，所以 app 與 dj 指令共用同一份狀態
```

佇列的實體是 Music.app 裡的「🎧 DJ」播放清單，維持 10 首待播。

**播過的歌會從清單裡移除**（保留緊鄰的前一首，讓 👍👎＋ 還來得及按、⏮ 還退得回去
一步），所以清單第一首永遠是「下一首沒播的」—— 關掉 app 再開就自然從那裡接下去，
不必記任何播放位置。2.1 以前不會移除，於是每次開 app 都從清單第一首重播，聽到的
永遠是同一批歌。

補歌**只往末端追加**，不動前面的部分，所以接歌是 Apple Music 原生的無縫播放，
而不是逐首點播。換氛圍時保住正在播的那首（不然會當場斷音），前後全清、重新補滿。

防重複有兩層：**4 天內播過的直接不選**，更久以前的才回到指數衰減降權。
（原本只有 6 小時衰減，跨天等於沒有保護。）

## 開發

```bash
scripts/build.sh          # 建置 build/Apple Music DJ.app
scripts/make-dmg.sh       # 建置並打包 build/AppleMusicDJ-<版本>.dmg
scripts/make-icon.py      # 重新產生圖示（需要 Pillow）
```

只需要系統內建的 `swiftc`，不需要 Xcode 專案檔。

## 踩過的坑

做這個東西時撞到幾個不會自己浮出來的問題，記在這裡：

- **borderless `NSPanel` 預設 `canBecomeKey = false`**，SwiftUI 的按鈕會完全收不到點擊，
  而且毫無錯誤訊息。必須子類化覆寫 `canBecomeKey`，再配一個覆寫 `acceptsFirstMouse`
  的 `NSHostingView` 讓第一下點擊就生效。
- **`NSPanel` 的 contentRect 是寫死的**，SwiftUI 內容長高時視窗不會跟著長，展開的清單
  會被無聲裁掉。解法是在 hosting view 的 `layout()` 裡按 `fittingSize` 重設視窗，
  並同步調整 `origin.y`（Cocoa 原點在左下），左上角才會待在原地。
- **設 `.accessory` 活動策略的 app，System Events 完全看不到**，AX 座標查不到，
  自動化測試只能靠截圖。
- **`swiftc -parse-as-library` 不准 top-level 程式碼**，要用 `@main struct`；
  且 `NSApplication.delegate` 是 weak，delegate 必須有人持有否則被回收。
- **`Picker` 會跟 SwiftUI 的 `Picker` 撞名**，錯誤訊息卻指向不相干的
  `.pickerStyle(.segmented)`。
- **浮動面板裡的文字輸入是三個問題疊在一起**，症狀是「點輸入框，整個 app 就消失」：
  1. `NSPanel` 的 `.utilityWindow` 預設 `hidesOnDeactivate = true`，app 一失去作用中
     狀態面板就自己隱藏；再配上 `applicationShouldTerminateAfterLastWindowClosed`
     回傳 `true`，等於**焦點一離開就自動退出**。而且離開碼是 0，不會留下當機報告，
     看起來就像憑空消失。
  2. `.nonactivatingPanel` 讓點擊不會使 app 變成作用中，鍵盤事件根本不會送到輸入框。
  3. `.accessory` 策略的 app 不作用中就沒有 text input context，中文輸入法接不上，
     console 會噴 `error messaging the mach port for IMKCFRunLoopWakeUpReliable`。

  解法是三個一起改：`hidesOnDeactivate = false`、終止判斷改回 `false`、拿掉
  `.nonactivatingPanel`，然後在輸入框取得焦點時 `NSApp.activate`、失焦與按完回饋鈕時
  `NSApp.deactivate` 把焦點還給原本在用的 app。
- **launchd 背景程序不能住 `~/Documents`**（見 `legacy/python-daemon/`）。
- **AppleScript 的 `item 2 of (position of e)` 會丟錯**，而錯誤被外層 `try` 吃掉之後
  症狀是「明明找得到那個元素，取座標卻永遠失敗」。`position` 必須先落成變數再取 item。
  同一類地雷還有保留字：`by`、`removed`、`st` 當變數名都會編譯失敗，訊息完全不知所云。
- **Swift 合成的 `Decodable` 不會拿屬性預設值當缺鍵的 fallback** —— 少一個 key 就整份
  throw。配上呼叫端的 `try?`，症狀是升級後整份狀態靜靜變回預設值：氛圍不見、回饋權重
  歸零，而且 `feedbackOffset` 一起歸零會讓 app 把 `feedback.jsonl` 裡的**整段歷史指令
  重播一遍**（舊的換氛圍、舊的開關全部重來一次）。每次替持久化 struct 加欄位都會觸發，
  所以 `init(from:)` 一定要手寫、每個欄位都 `decodeIfPresent ?? 預設值`。
- **Apple Music API 的 `l=` 語言標籤要看該地區支援哪些**。曲風名一定要英文才跟資料庫
  同一套詞彙，但台灣 storefront 只支援 `zh-Hant-TW` 與 `en-GB` —— 寫死 `l=en-US`
  會被**無聲忽略**，回傳中文曲風，於是所有評分都對不上、候選少一大截。先問
  `/v1/storefronts/<sf>` 的 `supportedLanguageTags` 再挑。
- **cookie 叫 `media-user-token`，header 卻叫 `Music-User-Token`**。用錯名字一律回
  `403 Invalid authentication`，跟 token 本身無效長得一模一樣。
- **未公證的 app 到別台 Mac 會被 Gatekeeper 擋**，要教使用者右鍵→打開兩次；公證需付費開發者帳號。

## 授權

MIT
