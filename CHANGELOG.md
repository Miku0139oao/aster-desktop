# 更新紀錄

## 0.5.0 — 2026-11-27 — 原生桌面介面

- Windows、macOS 與 Linux 桌面介面改為 MyGo 原生 Go UI：沿用紫色淺色／深色主題、Noto Sans TC 字型、側欄與首頁卡片，共用原有 Go 橋接層與使用者資料；桌面程式不再隨附 Flutter 執行環境。
- macOS 版在簽章過的 App 內以 Swift XPC 用戶端連接既有特權助手，系統代理與 TUN 授權流程不變。
- 修正首頁連線按鈕被背景載入鎖住：Windows 的 TUN 網卡探索、應用程式清單與流量歷史不再阻擋連線操作，大字級下的匯入操作仍可點擊。
- 特權 TUN 啟動與回滾加入有界的服務逾時與啟動診斷；桌面端斷線時會釋放服務 session。
- 明確退出若無法停止核心或還原系統代理，Aster 會保留視窗並顯示原因，可在恢復後重試。
- Windows CI 新增乾淨 runner 上的實際安裝器、原生視窗、卸載，以及經 LocalSystem 服務的 TUN 請求／回應轉送驗證。
- 新增 [iOS 自簽安裝教學](docs/IOS_SELF_SIGN.md)：付費 Apple Developer Program 需求、從原始碼建置並簽章、重新簽章官方 unsigned zip、識別碼調整與常見錯誤。

## 0.4.0 — 2026-11-22 — iOS 客戶端基礎

- 首次在同一個版本同時提供 Windows、macOS（Intel／Apple Silicon）、Linux、Android 與 iOS 產物；iOS 為未簽章 CI 建置，安裝仍需 Apple Developer Program 簽章。
- 同步 Android 0.3.1–0.3.5 的手機版導覽、多語系、圖示與核心生命週期修正。
- iOS 新增 NetworkExtension Packet Tunnel、App Group 共用狀態與 Siri／捷徑入口；iOS 不支援 Android 的套件層級分流，介面會說明並改用網域／IP／規則。
- 修正 iOS 斷線後過早重開 in-app host 造成 App Group 鎖衝突、Flutter 輪詢與連線／斷線交錯、tunnel 啟動失敗長時間無回應、從系統設定或捷徑啟動 tunnel 時被 App 內的 core 擋住，以及 App Intent 連線失敗仍顯示成功。
- App 進入背景時釋放 in-app host；Connect 失敗會回報原因，tunnel 錯誤訊息改為可操作的在地化提示。
- iOS tunnel 在生效前擷取裝置當下的 DNS 解析器並注入 core，避免 tunnel 接管路由後無法解析節點網域；設定檔已自訂 `dns.nameserver` 時維持原設定。
- iOS 修正本機設定檔匯入（`file_selector_ios` 需要 UTI）與匯出（iOS 沒有儲存對話框，改存到 App 文件夾並在「檔案」App 顯示）。
- iOS 會自動更新訂閱（原本只有 macOS 會排程），且連線中不會因套用新設定而重建 TUN、讓流量中斷。
- Tunnel 回覆逾時不再永久卡住後續請求；核心回復 panic 時會回報失敗，不再誤顯示已連線。
- 手機版的原生錯誤改顯示實際原因（不再出現 `PlatformException` 包裝），逾時與 TUN 設定變更會提示先中斷再重新連線。
- Android 匯出改存到檔案管理員可瀏覽的 `Android/data/app.aster.desktop/files`，不再誤稱存到「檔案」App；iOS 維持 App 文件夾。
- 修正快取的 `GeoSite.dat` 缺少規則清單（例如 `geolocation-!cn`）時設定驗證永久失敗：現在會把舊檔移到 `.stale` 並重新下載目前版本後重試。
- 修正重複啟動時偶爾收不到「喚回視窗」確認而誤判逾時：啟動請求現在一定會收到成功或失敗回應，失敗會記錄原因並立即重試。
- CI 新增 iOS 產物檢查：Packet Tunnel extension point、bundle id、entitlement 與 app／extension 的 Mobileapi 連結。

## 0.3.5 — 2026-10-26

- 修正 Android in-process core 停止時只改狀態、沒有完整釋放 mixed proxy、UDP、Controller、DNS 與 TUN 的問題；通知列 Disconnect 後不會再繼續代理或留下 7890 listener，也不會把正常停止誤顯示成操作失敗。
- 停止與重連現在會等待 listener 釋放；同一個 mixed port 可立即重新使用，不再誤報「7890 已被佔用」。
- Android VPN 前景服務改為 sticky recovery：關閉 App 工作畫面後保持連線；程序被系統意外終止時會依已保存的連線意圖嘗試恢復一次。明確按停止或通知列 Disconnect 會清除恢復意圖。
- 手機規則頁改為可讀的規則卡片、狀態與出口標籤；排序、開關、複製、刪除移入操作選單，點卡片可查看完整規則，修復控制項把規則文字擠到看不見的問題。
- 新增 in-process core 停止、同 port 重連及手機規則頁回歸測試。

## 0.3.4 — 2026-10-26

- 修正 Android APK 仍使用 Flutter 範本圖標；桌面圖示、圓形圖示及 Android 8+ 自適應圖示現在統一使用 Aster 軌道 A 圖標。
- Android 13+ 主題圖標加入 monochrome 資源。
- 圖示產生腳本現在會輸出所有 Android 密度，Android release 建置在圖標仍是 Flutter 範本或尺寸錯誤時直接失敗。

## 0.3.3 — 2026-10-26

- 新安裝與尚未設定語言的裝置會跟隨系統語言，支援繁體中文、简体中文與 English。
- Android、Windows、macOS 與 Linux 共用同一套語言判斷；繁體中文系統顯示繁體中文，其他中文系統顯示简体中文，其他語言顯示 English。
- 「進階設定 → 介面語言」可選擇跟隨系統、繁體中文、简体中文或 English，切換後立即生效。
- 简体中文採內建 OpenCC 字典轉換既有繁體中文介面，並補上 OpenCC 的 Apache-2.0 授權聲明。

## 0.3.2 — 2026-10-26

- 修正 Android 匯入含 `GEOIP`／`GEOSITE` 規則的設定檔時，in-process core 未設定 runtime home，導致 MMDB 路徑為空並拒絕匯入。
- 補上 in-process core home 與 geodata 路徑的 Go 回歸測試。
- 已在 MuMu Android 15 重新匯入同一份含 `GEOIP` 規則的 YAML，確認 `geoip.metadb`／`GeoSite.dat` 正確下載到 App runtime 目錄。

## 0.3.1 — 2026-10-26

- Android 手機改用頂部頁面標題、底部五項導覽與「更多」頁面選單，不再把桌面側欄塞進手機寬度。
- 節點工具列、節點頁與手機流量卡片修正窄螢幕及放大字級溢位。
- 新增 390×844 手機尺寸、1.25 字級的完整頁面回歸測試。

## 0.3.0 — 2026-10-25

[Android 版下載](https://github.com/Miku0139oao/aster-desktop/releases/tag/v0.3.0)。

- 推出首個 Android 代理客戶端，內建 Aster Core，不需要自行安裝核心或設定 Controller。
- 支援訂閱／Clash YAML／分享連結匯入、節點測速與切換、連線、流量、日誌與診斷。
- Android 使用 VpnService 提供全裝置 VPN；對外 core sockets 透過 `protect()` 避免回圈。
- 應用程式頁面可從已安裝清單選擇代理、直連或排除的 App，設定不會因訂閱更新消失。
- Android 版本使用固定 release keystore，後續 APK 可直接覆蓋升級。
- APK 提供 arm64-v8a 與 x86_64，不包含沒有對應 Go core 的 32-bit ABI。

## 0.2.3 — 2026-10-19

[正式版下載](https://github.com/Miku0139oao/aster-desktop/releases/tag/v0.2.3)。此版將已驗證的 0.2.3 beta 1 提升為正式版，沿用相同二進位檔與來源包，補齊使用手冊、FAQ 與離線文件。

- Windows／macOS／Linux 共用程序鎖，重複啟動喚回既有視窗，不重開核心；支援隱藏／最小化與崩潰後恢復。
- 側欄分組、小視窗保留文字、各頁常駐啟停代理、首頁直接更換節點與設定。
- Ctrl+K／⌘K 搜尋頁面；外觀快速切換。
- 連線接管方式與出口模式分開說明，TUN 首次授權可在首頁操作。
- 整理托盤及 Mac 原生退出清理，Windows 關到托盤保留核心運作。

## 0.2.2 — 2026-10-18

- 日誌增加來源／層級／欄位搜尋、暫停快照、明細與篩選匯出。
- 連線增加程式完整路徑、出口與入口篩選、明細側欄、局部中止。
- 切頁保留操作狀態，移除全頁通用匯入加號。
- 核心持續查詢程序資訊；Windows 安裝器忽略已結束的程序殘影。

## 0.2.1 — 2026-10-08

- 核心可透過目前系統代理／TUN 下載更新，驗證後短暫重啟並恢復選點。
- 下載／驗證失敗保留原核心，新版啟動失敗自動回復。
- 慢速下載維持服務所有權，更新後恢復模式與連線狀態。

## 0.2.0 — 2026-10-08

- 節點收藏、最近使用、來源／協定篩選與表單管理。
- 訂閱變更預覽、個別排程、桌面覆寫與 JSON 備份。
- 多程式批次出口、規則排序／停用、連線彙整與規則建立。
- 每日歷史流量、分層診斷、DNS 查詢與 Aster 原創圖示。

## 0.1.x

建立 Flutter／Material 3 跨平台客戶端、核心管理與背景服務；陸續加入圖形程式選擇、群組／節點卡片、應用獨立出口、Wi-Fi／多網卡 TUN 出口選擇、大型 YAML 編輯、Mac／Linux 套件及 CI。早期版本與逐項驗證見[歷史發佈](https://github.com/Miku0139oao/aster-desktop/releases)及[測試紀錄](docs/TESTING.md)。
