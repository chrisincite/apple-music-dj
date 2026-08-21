# Apple Music DJ

一支常駐在螢幕角落的小 app，依你打的一句「氛圍」持續幫 Apple Music 排歌。
說一句「深夜寫程式，安靜不要有人聲」，它就自己維持一份 12 首的佇列，播到剩不到 8 首自動補，
你按 👍👎 它會學。

> A tiny macOS menu-less app that DJs your Apple Music library from a plain-language vibe.
> Rule-based selection, no API keys, no LLM calls, no network.

靈感來自 [Nick Baumann 用 Codex DJ Spotify 的做法](https://x.com/nickbaumann_/status/2090551906657517876)。
差別在於 Spotify 有佇列 API 可用，Apple Music 沒有——所以這裡走的是 AppleScript 原生路線，
佇列的實體就是 Music.app 裡一個叫「🎧 DJ」的播放清單。

## 安裝

到 [Releases](../../releases) 下載 `AppleMusicDJ-*.dmg`，把 app 拖進 Applications。

第一次開啟會被 macOS 擋（「無法驗證開發者」）——這支 app 沒有經過 Apple 公證。
在 Applications 裡對它**按右鍵 →「打開」→ 再按一次「打開」**，只需做這一次。

啟動後會問「Apple Music DJ 想要控制『音樂』」，必須允許。

### 需求

- macOS 13 以上、Apple Silicon
- Apple Music 訂閱，且**「同步資料庫」要開啟**（音樂 App → 設定 → 一般 → 同步資料庫）
- 它只從你**已加入資料庫**的歌裡挑，不會去 Apple Music 目錄挖新歌

## 用法

展開小窗（右上 `⌄`），在輸入框打一句氛圍就好：

```
深夜寫程式，安靜不要有人聲
早晨咖啡
夏天海邊
放鬆但不要古典
想聽聖誕鋼琴
```

四顆按鈕：**👍** 之後多排這種／**👎** 封鎖這首並少排這類（同時跳過）／
**＋** 存進「🎧 DJ 精選」／**⏭** 跳過。展開區有「接下來／剛剛播過」兩個分頁。

### 命令列（選用）

`cli/dj` 是同一套狀態的遙控器，適合從終端機或腳本控制：

```bash
ln -s "$PWD/cli/dj" ~/.local/bin/dj

dj on "深夜寫程式"     # 設氛圍並開啟小窗
dj vibe "早晨咖啡"     # 換氛圍
dj now                 # 現在播什麼＋接下來 10 首
dj history             # 剛剛播過的歌
dj up / down / keep / skip
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

## 架構

```
Apple Music DJ.app
├─ Engine        15 秒心跳：補佇列、吃回饋、記錄播放歷史
├─ TrackPicker   選曲評分（上面那六層）
├─ MusicBridge   AppleScript 橋接（osascript 子行程）
└─ PanelView     SwiftUI 浮動小窗
        │
        └─→ ~/Library/Application Support/apple-music-dj/state/
              state.json · history.jsonl · feedback.jsonl · nowplaying.json
                        ↑ CLI 從這裡讀寫，所以 app 與 dj 指令共用同一份狀態
```

佇列的實體是 Music.app 裡的「🎧 DJ」播放清單。引擎**只往末端追加**，不動已播過的部分，
所以接歌是 Apple Music 原生的無縫播放，而不是逐首點播。
換 vibe 時也只清掉「正在播那首之後」的部分，當前這首會播完。

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

## 授權

MIT
