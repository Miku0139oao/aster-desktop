# 更新紀錄

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
