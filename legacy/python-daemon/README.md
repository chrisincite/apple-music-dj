# 舊版：Python daemon（已歸檔）

第一版的架構是四塊分離的：浮動小窗 app、Python 心跳 daemon、launchd agent、CLI。
2.0 之後選曲腦與心跳都用 Swift 重寫進 app 本體，這個目錄只作為紀錄保留，不再維護。

留著它的理由是選曲邏輯的可讀性——`daemon/dj.py` 的詞典與計分比 Swift 版好讀，
要調整選曲行為時可以先在這裡試想法。兩邊的規則是等價的。

檔案裡的 `__HOME__` 與 `com.example.djd` 是佔位符，原本是寫死的個人路徑。

## 為什麼不再用 daemon

- **launchd 背景程序不能住 `~/Documents`**：碰到就撞 macOS TCC，而背景程序彈不出
  授權視窗，結果 daemon 在 **import 階段**無聲卡死，log 一行都不會有。
- 要分享給別人時，「app + Python + launchd + 安裝腳本」四塊沒辦法只靠拖進
  Applications 就能用；而各台 Mac 內建的是 Python 3.9，這份程式用了 3.10 的
  `dict | None` 語法。
- 心跳合進 app 之後，介面可以直接觀察引擎狀態，不必再靠輪詢 JSON 檔。
