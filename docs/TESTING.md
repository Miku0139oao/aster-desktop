# 0.2.0 日常操作

日期：2026-10-08。固定核心／轉換器提交維持 `a9a33503b39a03681bc52d9758907316a22df199`。

新增訂閱預覽與過期防護、個別排程、節點／群組／provider 表單、跨更新桌面覆寫、規則停用與排序、多程式批次出口、連線彙整／欄位與規則建立、歷史流量及分層診斷。原創 Aster 圖示涵蓋 GUI、托盤、Windows 安裝器與 Mac App。

本機 Flutter analyze、36 項單元／元件測試通過（Mac 專用一項跳過）。Windows 真實固定核心完整 Go 測試通過；原生 GUI 匯入／代理／程式分流／萬行 YAML／停止流程通過。Windows release 編譯、安裝器 payload 校驗及 9 項 PowerShell 5.1 安裝／回復測試通過，已確認 PE 安裝器含原創圖示。跨平台 CI 結果於完成後追加。測試使用獨立資料與 loopback，未變更使用者系統代理、TUN、DNS 或服務。新增回歸涵蓋訂閱失敗／過期、節點刪除引用驗證、批次交易、YAML 與 GUI metadata 一致性、流量重啟／重複取樣／清除／儲存、限制範圍的 DNS API，以及窄視窗放大字體操作。

流量分類為抽樣，短連線可能遺漏；異常退出可能遺失最近尚未寫入的資料（通常約 20 秒）。Mac 實機 TUN、系統代理、SMAppService 授權／拒絕、Gatekeeper 與睡眠喚醒仍待驗收，CI 不代替這些測試。使用者 Wi-Fi TUN 尚未重試，不宣稱已修復實際上網。

交付產品來源：`866e346b7af0795fc2344cb9ae5bd3932747b97d`。後續 `ecef464` 僅增加 Mac 安裝驗證的 GUI driver 選項；`lib`／`bridge`／資產及建置腳本與交付來源逐目錄比對一致。

- [最終四平台 CI 37694113783](https://github.com/Miku0139oao/aster-desktop/actions/runs/37694113783) 全部通過：Windows／Ubuntu 24.04／Mac Intel／Apple Silicon 原生 release 建置、Flutter analyze、單元／元件及平台圖片比對、Go 管理層與真實固定核心測試。Windows PowerShell 5.1 安裝器回歸、LocalSystem 服務／TUN 及原生 GUI；Ubuntu 原生 GUI 也通過。
- [Apple Silicon 安裝驗證](https://github.com/Miku0139oao/aster-desktop/actions/runs/37695199189) 與 [Intel 安裝驗證](https://github.com/Miku0139oao/aster-desktop/actions/runs/37695262923) 均通過：下載實際 DMG，核對全部套件 SHA-256、校驗 DMG、以 PKG 安裝到 `/Applications`、完整 codesign 驗證、GUI／Go／Swift 助手架構、root 所有權與目錄權限。本版兩處 Mac 原生 GUI driver 均明確跳過，沒有借用舊版通過結果；Mac Widget／Go／建置／安裝與實機網路驗收分開。
- WSL Arch 使用 Go 1.26.3、真實固定核心的完整 Go 測試通過；Flutter analyze、release GUI、Arch 可攜包與 `.pkg.tar.zst` 建置及 Xvfb 原生 GUI 流程通過。Xvfb 不代表 GNOME／KDE 的托盤、polkit 互動及桌面代理實機驗收。Arch bridge 的 VCS 記錄為產品提交，工作目錄差異是上述 CI 檔；產品來源一致。
- 首次圖片擷取 run 的 Windows 安裝器資源格式失敗，改以固定 akavel/rsrc v0.10.2 產生 Go 相容資源後，重新建置並通過安裝器與最終 CI。圖片擷取只用於人工檢視；已檢查 Linux／Mac 三種平台的明暗／繁中畫面並提交基準，最終 run 使用正常圖片比對。
- 加入訂閱新規則保持在 `MATCH` 前面的回歸後，重跑 Windows 全部真實核心測試與上述最終四平台 CI。來源 diff 經 gitleaks 遮蔽掃描，未發現秘密；私人診斷與建置資料未加入 Git。

發行資產附 `SHA256SUMS`、GPL-3.0 及對應桌面／固定核心來源。使用者 Wi-Fi TUN 未重試；Windows disposable runner 的服務測試不代表其實際節點連通性已驗收。

---

# 0.1.7 連線頁、流量與節點版面

日期：2026-10-08。主要為 Flutter 介面改動，核心與轉換器的固定版本不變。沒有修改系統代理、TUN 路由或背景服務權限。

- `flutter analyze --no-pub` 通過。
- `flutter test --no-pub test/client_test.dart` 30 項通過：包含原有 2,000 節點高文字縮放／3,000 節點出口選擇、10,000 連線惰性顯示／搜尋／中止，以及新加入的核心累計流量、暫停列表但持續更新速度、TCP／UDP 篩選、只中止篩選結果、連線明細、首頁累計、760×580 視窗／1.5 倍文字、IPv6 目的地及完整路徑搜尋。首頁無流量資料時的三份既有 golden 仍通過。
- 實際渲染並檢視繁中節點頁、出口選單及連線頁。示範資料與截圖位於忽略的本機 `.build/`，未讀取使用者訂閱或私人連線。
- 目前提供核心啟動後的累計，包含已結束連線，重啟核心歸零；沒有將活動連線流量相加冒充核心總量。每日／每月歷史尚未保存。本輪不等待跨平台 CI；Mac／Linux 新包與真實 TUN 實機驗證未執行。

---

# 0.1.6 節點與應用程式出口瀏覽

日期：2026-10-08。核心與轉換器維持固定提交 `a9a33503b39a03681bc52d9758907316a22df199`。這次改動主要為共用 Material 3 群組／卡片瀏覽器，以及清除自動群組的手動選擇；沒有變更 TUN 路由。

- 本機 `flutter test test/client_test.dart` 27 項通過，包含 2,000 節點高文字縮放的惰性顯示／搜尋、3,000 節點應用程式出口搜尋、進入群組選 provider 節點、不同群組獨立選擇及恢復自動、provider 同名節點測速身分隔離、輪詢保留測速結果與停止／dispose 後丟棄過期結果。原首頁三份 golden 仍通過。
- `go test ./internal/desktop -run TestForgetSelectionPersistsOnlyRequestedGroup -count=1` 通過，重新讀取磁碟設定確認只清除指定群組的手動選擇，保留其他群組，拒絕空群組。
- 用模擬設定渲染並檢視主節點頁及應用程式出口選單，截圖位於忽略的本機 `.build/`，不含使用者訂閱。更新原生 GUI 測試的卡片定位器；本輪未執行原生網路／TUN 測試或跨平台 CI。

使用者要求先交付可用 Windows 安裝器，不等待完整 CI。Mac／Linux 本輪尚未建置或實機驗證；既有平台與 TUN 驗證記錄列於下方，不視為 0.1.6 已通過。

---

# 0.1.5-beta.1 TUN 出口網路

日期：2026-10-07。產品程式提交 `5259ebe`；`38546df` 只修正測試 YAML 的 flow sequence 引號及原生 GUI 測試的捲動操作。核心與轉換器仍固定 `a9a33503b39a03681bc52d9758907316a22df199`。

使用者回報 Wi-Fi 下全部節點在 TUN 無法連線、系統代理正常，並確認有線網路無法上網。本機唯讀路由診斷看到：有線與 Wi-Fi 同時 Up，IPv4 預設路由總 metric 分別為 20／30；IPv6 預設路由在 Wi-Fi。固定 sing-tun 的 Windows 自動偵測只比較 IPv4 預設路由與介面 metric，沒有連通性檢查，因此會選有線。TUN 服務日誌記錄大量節點及直連 DNS 解析失敗，沒有據此認定節點故障或其他 VPN 衝突。之後有線介面已停用；以固定核心 dialer 綁定 Wi-Fi，測試一個已配置節點及一個 DNS HTTPS 伺服器的 TCP 443 連線成功。這不是使用者 TUN 流量的完整重現。

首頁 TUN 開關下新增出口網路清單；只讀取 OS 介面名稱，不需要輸入命令或改全域路由。`tunInterface` 經原有 Settings 傳至 Windows／Linux 服務及 Mac XPC；TUN Runtime 設定頂層 `interface-name`，關閉出口自動偵測但保留 `auto-route`。系統代理不使用這項桌面覆寫。自動模式保留原 YAML 的介面設定；個別節點的介面設定仍保留。所選介面消失、停用或為 loopback 時拒絕啟動並提示改選；連線時不可更改。僅 Up 不代表能上網，清單與提示沒有宣稱已通過連通性檢查。

- 本機 Flutter analyze 無問題，24 項元件／單元測試通過，一項 Mac 專用測試跳過；包含出口選取、保存、連線時鎖定、網路消失與改回自動。
- Windows Go 單元測試及 vet 通過；以真實固定核心驗證 Wi-Fi／中文介面、覆寫原 YAML、自動模式及系統代理設定相容性。測試 fixture 的 YAML 缺少引號曾使真實核心驗證失敗，已修正並重驗通過；首個 CI 取消，未當作交付驗證。
- Windows 原生 GUI 自動化通過：從實際 OS 網路清單選取、保存、關閉 TUN，再完成既有核心 HTTP／節點／應用程式分流／YAML／正常停止流程。該本機流程沒有啟用 TUN 或改動使用者系統代理。
- Windows 安裝器建置及 `--verify` 通過。服務的指定出口、真實 TUN、冷 provider 與停止清理另由 disposable Windows CI 回歸，不在使用者機器安裝測試服務。

Windows／WSL 完整核心結果與四平台 CI 交付結果於完成後補列。Mac 本次原生 GUI driver 跳過，保留 0.1.4 紀錄中的驗證限制；Mac 實機 TUN／網路／權限仍待驗收。使用者在停用有線後尚未重試 TUN，新版指定 Wi-Fi 後的實際上網結果待確認。本次沒有更動有線介面、WARP／Tailscale、DNS 伺服器、防毒排除或使用者節點憑證；故障日誌與探測資料留在忽略的私人建置目錄。

---
# 0.1.4-beta.1 應用程式選取

日期：2026-10-05。新版清單合併已安裝／正在執行的程式，使用易讀名稱、圖示、執行狀態與篩選；程式路徑保留在詳細資訊。Core／轉換器提交維持 `a9a33503b39a03681bc52d9758907316a22df199`。

交付程式來源 `9e21074ea7ce4fea07109183f8341fa8a9d5919a`，其產品程式碼與 `08ad1576ab2368ad27b7cbc446d274ed18424e54` 相同，差異只有 Windows 路徑別名測試及 CI 平台選擇。驗證 harness `92df856` 加入 Flutter 官方 integration driver 與完成標記；`6ba3128` 將套件保存提前、加入 GUI 步驟期限及獨立建置選項，產品程式碼均不變。

- 本機 Flutter analyze、23 項元件／單元測試及 Windows／WSL Go 單元測試、vet 通過。涵蓋未啟動程式、背景程序篩選、鍵盤 Enter、防止同名誤選、2,500 筆清單、原有 provider 節點自由選擇、含空格路徑與既有 YAML 編輯測試。
- Windows 中文捷徑／路徑與短路徑別名測試通過；改用 Unicode Shell.Application 讀取捷徑，以實際檔案身分驗證別名。WScript.Shell 的 ANSI fixture 寫入限制已隔離於測試建立步驟，探索不啟動程式。
- [Windows CI](https://github.com/Miku0139oao/aster-desktop/actions/runs/37235393501) 全部通過：原生編譯、安裝器 9 項 PowerShell 5.1 回歸、真實核心分流／更新回復、LocalSystem／TUN 及原生 GUI。
- [Ubuntu CI](https://github.com/Miku0139oao/aster-desktop/actions/runs/37235035823/job/111532332147) 與 [Apple Silicon CI](https://github.com/Miku0139oao/aster-desktop/actions/runs/37235035823/job/111532331958) 成功；包含 Go 真實核心、原生 GUI 與套件建置。Mac 24 項元件／單元測試通過。
- Intel 的原生 GUI 在 `flutter test` 操作執行後，工具發生 listener 暫存目錄收尾錯誤（退出 79、計數 0），沒有將該結果列為通過。改用官方 `flutter drive`，檢查 allTestsPassed 及最後一項斷線／連接埠關閉檢查後送出的完成標記；[Intel 重驗](https://github.com/Miku0139oao/aster-desktop/actions/runs/37237233641) 驅動器未完成連線，等待後取消，仍列為未通過。另以 [Intel 建置 CI](https://github.com/Miku0139oao/aster-desktop/actions/runs/37240456510) 成功通過原生編譯、24 項元件／單元測試、Go／真實核心與套件建置，跳過原生 GUI；建置通過不代表 Intel GUI 已驗證。
- 本機 Windows 原生 GUI 及 driver（完成標記 true）通過；WSL 使用校驗過的 Ubuntu CI 核心進行真實核心完整 Go 測試通過。本機兩個更新回復案例被 Defender 拒絕執行，已保留私人測試紀錄；未更動防護設定，乾淨 Windows CI 的對應案例通過。

[下載 0.1.4-beta.1](https://github.com/Miku0139oao/aster-desktop/releases/tag/v0.1.4-beta.1)。Windows 安裝器／可攜版、Ubuntu deb／可攜版、Mac Intel／Apple Silicon DMG、桌面／固定核心來源及 SHA256SUMS 共九份 release 資產，GitHub SHA-256 digest 均與本機檔案相符；Intel 下載亦逐份核對 CI checksums.txt。標籤指向上述交付提交，Intel 套件建置提交為 `6ba3128`，差異只有測試與 CI。

Mac 0.1.4 原生 GUI／建置測試與 0.1.3 的實際 DMG／PKG 安裝驗證分開記錄。Mac 實機系統代理／TUN、SMAppService 授權、Gatekeeper、睡眠喚醒，以及 GNOME／KDE 完整桌面仍依下方表格待驗收。Arch 安裝包目前維持 beta.1 的 0.1.3；0.1.4 提供 Ubuntu 套件及可自行建置的來源。

# 0.1.3-beta.2 Mac 交付

日期：2026-10-04。Repository 已依使用者指示公開；公開前 gitleaks 掃描既有 18 筆提交，未發現秘密。GitHub Actions 隨後恢復執行。

交付程式來源：`0bede51d4281b96c46a44fc49c3068df54616595`。[四平台 CI 37190314007](https://github.com/Miku0139oao/aster-desktop/actions/runs/37190314007) 全部成功。Windows、Ubuntu 24.04、Mac Intel／Apple Silicon 原生編譯、Flutter analyze、Go 管理層與真實核心測試通過；Mac 22 項元件／單元測試，Windows／Linux 21 項加一項 Mac 專用跳過。Windows PowerShell 5.1 安裝器、LocalSystem／TUN 回歸與原生 GUI，Ubuntu 原生 GUI 也通過。先前本機 Defender 攔截仍保留在 beta.1 紀錄，沒有變更防毒設定；本次乾淨 Windows runner 的更新／回復測試通過。

Mac 程序清單改用 `PROC_PIDPATHINFO`，與固定核心取得執行檔路徑的方式一致。原先 `ps comm` 取到的是啟動名稱，Mac 暫存目錄別名也可能與核心路徑不同；現在以實際執行檔身份測試。新增含空格執行檔／不同 argv[0] 的程序列舉回歸。Mac `.app` 解析、執行檔及 bundle 別名、非法 CFBundleExecutable 路徑的 Flutter 測試通過。真實核心的 PROCESS-NAME／PROCESS-PATH 放行／阻擋、provider 精確節點與更新持久化在兩種 Mac 架構上通過。

[Mac 安裝及 GUI CI 37191793412](https://github.com/Miku0139oao/aster-desktop/actions/runs/37191793412) Intel／Apple Silicon 兩個 job 全部成功。使用實際 DMG 的 PKG 在乾淨 runner 安裝到 `/Applications`；DMG 校驗、PKG 安裝、完整 codesign 驗證、GUI／核心／bridge／Swift 助手架構、root 所有權與目錄權限通過。GUI 由套件來源編譯，搭配已安裝套件的核心／bridge，驗證匯入、OS 程式選取、搜尋節點、改直連、刪除規則、萬行 YAML 編輯／undo／驗證／套用、loopback HTTP 代理、停止後連接埠關閉。驗證 harness `57ef60a` 只補上搜尋可見節點的操作，應用程式來源維持套件提交。Intel job 確認退出碼為 0，不能用先前非零退出碼但列出 passing tests 的結果代替。

交付 Mac Intel／Apple Silicon DMG、Windows 安裝器／可攜版、Ubuntu deb／可攜版、對應桌面／固定核心來源及 SHA256SUMS。下載後核對各平台 CI 校驗碼；上傳後九份 release assets 的 GitHub SHA-256 digest 均與本機檔案相符。對應來源包中的 Mac 執行檔識別、`.app` 解析、測試及建置腳本與交付提交逐檔比對相符。[下載 beta.2](https://github.com/Miku0139oao/aster-desktop/releases/tag/v0.1.3-beta.2)。Arch 套件仍使用 beta.1。兩份 Mac DMG 的公開、未登入 HTTP 下載檢查均回傳 200；release tag 指向上述已驗證程式提交。

Mac 的實際網路系統代理／TUN、SMAppService／XPC 授權與拒絕、Gatekeeper 互動、既有安裝升級、睡眠喚醒仍待 Mac 實機。CI 使用 Mac 15、獨立資料與 loopback，沒有代替 Mac 13+ 使用者環境驗收。本機簽署測試包尚未正式簽章／公證，保留既有簽署／公證建置入口。

---
# 0.1.3-beta.1 應用程式分流（原始交付紀錄）

日期：2026-10-04。

新增進階設定的應用程式管理器：列出目前使用者工作階段中可讀取的執行檔，支援名稱／路徑搜尋及瀏覽其他執行檔。每列可搜尋選取群組、節點、DIRECT 或 REJECT；3,000 節點使用延遲建立清單。沿用核心 PROCESS-PATH／PROCESS-NAME 與 find-process-mode: strict，GUI 不需要輸入程序名稱。

GUI 規則與 provider 選擇有獨立 metadata，更新訂閱時重新合併；同一應用的 GUI 規則覆蓋原出口而不重複，刪除原始訂閱規則有移除紀錄，避免更新後恢復。手動 YAML 明確重新加入該規則時解除移除紀錄。JSON 備份／還原包含 metadata。指定 provider 節點使用獨立、精確 filter 的隱藏群組，節點消失時 empty-fallback=REJECT，不改變共用群組，也不增加核心公開 API。

- Windows Flutter analysis 無問題，21 項元件／單元測試通過，包含大型出口清單搜尋、直接節點／群組／直連／封鎖切換、provider 節點 typed request、應用程式選取與刪除。
- Windows 真實固定核心測試通過：依測試程式實際名稱／路徑阻擋或允許 loopback HTTP 流量；GUI 改出口、訂閱更新保留、YAML 刪除／還原 metadata、GUI 刪除後更新不復活。HTTP provider 節點不在全域 proxies，仍可選擇且流量正確；含正規表達式特殊字元及反引號名稱只匹配選定節點，遠端節點消失時阻擋。
- WSL Arch Go race 全部測試與 vet 通過（含真實核心）；Darwin Intel／Apple Silicon Go bridge 交叉編譯通過。這不是 macOS Flutter／Swift 原生建置或應用程式選取實機驗收。
- Windows 原生 GUI 自動化通過：從實際 OS 清單選擇桌面執行檔、選節點、改直連、刪除規則，再執行既有大型 YAML 編輯與代理流程；只使用獨立資料目錄及 loopback 代理，不修改使用者全域代理或 TUN。WSL Arch／Xvfb 的同一原生 GUI 流程及 21 項元件測試也通過；Arch release GUI、可攜包與 pkg.tar.zst 建置通過。Xvfb 不代表 GNOME／KDE 完整桌面授權與托盤驗收。Windows PowerShell 5.1 安裝器九項回歸通過，含完整 0.1.1 升級檔案雜湊、ACL、鎖定檔與錯誤回復；實際 UAC／SCM 升級互動未測。

Windows 完整真實核心回歸的 TestVerifiedUpdateAndDeferredStartupRollback 兩個 case 未通過：Defender Operational 1116／1117 對其核心驗證啟動命令回報 Trojan:Win32/Commando.A!ml，exec 回報 Access is denied。未停用 Defender／修改排除清單；本版與 0.1.2 核心 SHA-256 相同（6b29dfce3318c91807b76ec82ecb98fb6fbc057717e0363f7d135314a108996a）。保留 OS 執行錯誤、退出碼及回復失敗的兩個原因。其餘核心／管理層測試通過，包括 checksum、架構、下載中斷、API 不相容及新版啟動失敗保留舊核心。不能將此攔截判定為誤報，也不能以 Linux 結果代替 Windows 更新流程。

使用者本機 TUN 顯示已連線但不能上網仍待故障當下路由／DNS／服務日誌。診斷當時 TUN 關閉且核心未執行；WARP／Tailscale 介面存在不能證明路由衝突，沒有修改其設定，也沒有更改使用者 DNS 或節點憑證。

GitHub Actions 帳號付款／花費上限限制尚未解除；Mac／Ubuntu 新版原生建置及 Mac 實機網路／授權沒有完成。先前版本通過的 CI 不代表本版。

---
# 0.1.2-beta.2 Windows 安裝器修正

日期：2026-10-04。GUI／bridge／core 執行檔維持 0.1.2；此 hotfix 只修改 Windows 安裝器及打包／回歸腳本。

使用者截圖的 `Microsoft.PowerShell.Archive.psm1:411 / Remove-Item / LICENSE` 是 `Expand-Archive` 失敗後的清理錯誤。payload 內該授權檔案存在；原安裝包在獨立目錄首次解壓及重複覆蓋均通過，尚未確定使用者機器上最初觸發解壓失敗的原因。不能據此判定授權檔遺失或要求使用者刪除設定。

改為在同一磁碟的全新目錄完整解壓、保留既有安裝 ACL、等待服務 SCM Stopped **以及實際程序退出**後切換目錄。服務原本執行時才重新啟動，等待 Running；切換或啟動失敗回復舊目錄並嘗試重啟舊服務。回復失敗保留備份且回報兩個原因；清理拒絕路徑越界及 reparse point，遇到舊檔案鎖定可保留備份。移除固定「close the app」錯誤前綴及提權後重複的泛用錯誤對話框。使用者 AppData／服務 ProgramData 設定未參與目錄切換。

Windows PowerShell **5.1** 本機回歸通過：完整 payload 首次安裝、0.1.1 升級、殘缺舊目錄修復（每份安裝的全部檔案逐一 SHA-256 比對）；受保護 ACL 保留；真實 Windows 檔案鎖定；模擬服務無法停止／新版無法啟動及回復失敗；無效 ZIP 的原始錯誤；清理越界／根與子目錄 junction 拒絕。服務故障使用回呼 fixture，沒有改動本機服務或執行 UAC 安裝。這些測試不代表乾淨 Windows 10／11 的 SCM／UAC／解除安裝實機验收已完成。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/test-windows-installer.ps1 -PayloadPath "$pwd/packaging/windows/setup/payload.zip" -PreviousArchivePath "$pwd/dist/Aster-Desktop-0.1.1-windows-x64-portable.zip"
```

`PreviousArchivePath` 可省略，CI 使用同一測試腳本及 Windows PowerShell 5.1。新原生安裝器 `--verify`（ZIP 每個檔案 CRC、必要檔案及路徑）通過。本次沒有更動 Dart 或 Go 管理層，因此不重複前一版的介面／核心驗證；GitHub Actions 的帳號付款／花費上限問題仍另列，不宣稱本機檔案 fixture 等同 CI 系統服務驗證。

交付：[v0.1.2-beta.2](https://github.com/Miku0139oao/aster-desktop/releases/tag/v0.1.2-beta.2)，含新 Windows 安裝器、對應桌面及固定核心來源與 SHA-256。原 beta.1 可攜包／Arch 包不受本次安裝器修正影響。

---
# 0.1.2 啟動及 YAML 編輯修正

日期：2026-10-04。

根因已在獨立 Linux network namespace 使用使用者設定的私人副本重現：TUN adapter 成功建立，但核心要完成 HTTP rule/proxy provider 的初次載入才開 Controller。遠端 provider 的 20 秒下載逾時超過桌面原本 15 秒限制，導致桌面主動停止核心，並錯誤提示服務未安裝。修正後同一份設定約 20 秒完成 Controller 及 TUN 就緒檢查。沒有更動主機系統代理、路由、既有 VPN 或使用者原始設定；私人副本不納入來源與套件。

- 有 HTTP provider 的設定允許最多 75 秒啟動；沒有遠端 provider 仍維持 15 秒。保留 Controller、代理端口及實際 tun.enable 的就緒檢查，依等待階段區分錯誤。每次 Controller 探測有一秒期限。
- Windows 實際原核心回歸通過：延遲 17 秒的 HTTP 規則 provider 成功啟動並載入一條規則，重連沿用快取；Controller 正常但 TUN 失敗仍被拒絕。
- Windows Go 全部測試及 vet 通過；Dart analysis 無問題，14 項元件／單元測試通過。
- YAML 編輯器固定使用 Re-Editor 0.10.0，按可見行繪製、支援水平捲動及行號。設定解析按內容快取；流量事件不再重建 MaterialApp、Navigator 與對話框。
- 一萬行 YAML 的逐行編輯、中文輸入 delta、undo/redo、輪詢保留草稿、驗證期間唯讀及儲存回歸通過。此元件測試不代表所有實體 IME 都已驗證。
- 四平台 CI 加入慢速 provider 回歸；Windows LocalSystem TUN fixture 同時使用 mixed stack、warning 日誌、respect-rules/redir-host DNS、LAN listener 及 17 秒 HTTP 規則下載。Windows/Linux 原生 GUI 測試加入一萬行 YAML 編輯及真實核心儲存／套用。

程式提交：75cb40e93bb98ba5b4440fb15d4081b674092405。Windows 原生 GUI 測試通過，包含一萬行 YAML 輸入、輪詢期間草稿保存、undo、真實核心驗證／套用、HTTP 代理及停止；release GUI、安裝器、可攜 ZIP 與來源包已建置，安裝器嵌入 payload 驗證通過。

WSL Arch 的 Go race tests／vet、14 項元件測試、原生 GUI 流程、隔離 TUN DNS 攔截／路由還原及 root 服務身份驗證／EOF 清理全部通過。Arch release GUI、套件及可攜包已建置。

Windows widget debug harness 的 YAML 編輯更新中位數／p95（包含控制器更新與 pump frame；不是 release FPS）：1,800 行舊 TextField 68.14／80.51 ms，新 CodeEditor 5.41／9.59 ms；10,000 行舊 363.75／379.49 ms，新 4.53／6.38 ms。各取 5 次暖機後 30 次更新。可用 `flutter test scripts/benchmark_yaml.dart` 重現，數值隨機器及負載改變。

[本次四平台 CI 37142202463](https://github.com/Miku0139oao/aster-desktop/actions/runs/37142202463) **沒有啟動任何步驟**：GitHub annotation 回報 recent account payments have failed or your spending limit needs to be increased。因此本版 Windows LocalSystem 慢速 provider/TUN 回歸、Ubuntu 原生建置、Mac Intel/Apple Silicon 編譯與 DMG 尚未驗證，也未交付 0.1.2 的 Ubuntu/Mac 套件。先前 0.1.1 CI 結果不能替代本版驗證。macOS 實機網路與權限仍待 Mac 主機。使用者日誌中的遠端 REALITY authentication failed 與 TCP timeout 不代表 TUN 建立失敗；本修正沒有改寫遠端節點憑證。

---
# 0.1.1-beta.1 交付補充

交付程式／來源提交：8256e45d4f3086a1bb118b3c4bd0ae4738d6aab2。
最終四平台 CI 全部成功（Windows、Ubuntu 24.04、macOS Intel、macOS Apple Silicon）：https://github.com/Miku0139oao/aster-desktop/actions/runs/37059923869

Windows LocalSystem 服務回歸已通過：使用 owner SID 驗證的 named pipe，拒絕本機憑證檔案、保留錯誤；含 WebSocket 路徑與 YAML anchor 的設定啟動實際 gVisor TUN，確認 Controller tun.enable 為 true；拒絕 restart API；正常斷線／重連／client EOF 後停止核心；安裝及移除服務成功。這是一次性 GitHub Windows runner 的管理員測試，不涵蓋本機 UAC 互動、乾淨 Windows 10 或睡眠喚醒。

最新核心就緒檢查也在 WSL Arch 的實際隔離 TUN／DNS 攔截／路由還原與 root 服務身份驗證／EOF 清理測試通過。新增 controller 正常但 TUN 未就緒的回歸測試通過。

macOS 本機權限與網路驗證仍待 Mac 實機。

---
# Aster Desktop 0.1.1 修正驗證

日期：2026-10-03。此版修正 beta.1 的實際 TUN 匯入阻擋：WebSocket／HTTP／H2 request path、DNS geosite 分類及 YAML anchor 範本不再誤判為本機檔案；實際憑證檔案仍拒絕。WireGuard／MASQUE 的 inline private key 不再要求 PEM。節點 provider 的快取路徑仍由桌面管理。

- Windows `flutter analyze` 無問題；11 項元件／單元測試通過，新增舊輪詢不能覆蓋新連線、停止後保留核心錯誤並能查看日誌。
- Windows 實際原核心 Go 啟停／更新回復／設定測試與 `go vet` 通過；新增失敗的 TUN 啟動原因保存測試，以及 transport path／provider payload／YAML anchor／DNS 分類回歸測試。
- Windows 原生 Flutter GUI 匯入、選節點、HTTP 代理、三種模式、停止流程通過。
- 使用實際使用者設定的私人副本進行 TUN 設定驗證：固定核心 `alpha-main-a9a3350`、使用者已更新的 `alpha-main-56e24f5` 均通過。測試只執行核心 `-t`，未變更使用者設定、系統代理或主機路由；私人副本及診斷不納入 repository 或套件。
- 新增 TUN 就緒檢查與回歸測試：HTTP Controller／代理端口正常但 TUN 未建立時，不顯示連線成功，停止核心並保留失敗原因。
- 新增 GitHub Windows 一次性 runner 的 LocalSystem 服務／named pipe／gVisor TUN／拒絕操作／重連／EOF 清理回歸測試。預設不執行，明確拒絕覆寫既有 AsterDesktop 服務；不能當作本機 UAC 驗收。
- 本次 Linux、Mac 建置及 Windows 服務回歸 CI 結果將附於 release；尚未完成的實機項目仍以下列 beta.1 紀錄為準。

已安裝 Windows 背景服務者須使用 0.1.1 安裝器覆蓋更新，安裝器會停止並重新啟動既有服務；只換可攜 GUI 不會更新已安裝的服務程式。

---
# Aster Desktop 0.1.0 測試紀錄

日期：2026-10-03。本紀錄分開標示自動測試、實際核心／GUI 測試，以及尚未完成的作業系統驗收。測試包尚不代表全部平台驗收完成。

交付程式提交：`fa1589f7802708ce1302ed8eb41acedb55529318`。[最終四平台 CI 37041067426](https://github.com/Miku0139oao/aster-desktop/actions/runs/37041067426) 全部成功：Windows、Ubuntu 24.04、macOS Intel、macOS Apple Silicon。後續提交只整理文件；交付二進位及對應來源包使用這份已驗證程式。

## 環境與固定版本

- Windows x64 本機，Visual Studio 2022 C++ 工具鏈，非管理員帳號。
- WSL Arch Linux x64，systemd、GTK 3、AppIndicator、Xvfb。TUN 測試使用獨立 mount/network namespace；不更動主機網路路由。
- Ubuntu 24.04 GitHub runner；另以隔離 Ubuntu Base 24.04 rootfs 測試 GNOME／KDE 原生代理工具。
- GitHub macOS 15 Apple Silicon／Intel runner；實機權限與網路驗收仍需 Mac 主機。
- Flutter 3.47.6 / Dart 3.13.5；Flutter 提交 `5fc346839b5d0eef006ed8404392afb4dfae428d`。
- Go 1.26.3；核心與轉換器提交 `a9a33503b39a03681bc52d9758907316a22df199`。核心使用 `with_gvisor`。

## 已通過

| 測試 | 結果與範圍 |
|---|---|
| Dart 靜態分析 | `flutter analyze`：無問題 |
| Flutter 元件／單元測試 | 9 項通過：首次匯入／連線／停止、匯入失敗保留內容、離線選節點、全域模式沿用所選節點、六頁最小視窗、淺／深色／繁中畫面、2,000 節點搜尋與 150% 文字縮放、10,000 筆連線搜尋與中止、日誌匯出憑證遮蔽 |
| Windows 原生 GUI | `flutter test integration_test -d windows`：實際 Flutter 視窗啟動 Go／原核心，在 GUI 匯入只有節點的 YAML、離線選節點、連線、全域／規則模式沿用節點、透過代理存取本機 HTTP、巡覽六頁、停止後代理埠關閉；關窗進托盤仍保持核心執行。本機及 Windows CI 通過 |
| Linux 原生 GUI | Arch 本機與 Ubuntu CI 在 Xvfb 下通過相同匯入／選節點／切換模式／HTTP 代理／六頁／停止流程；此測試停用托盤生命週期，不等同 GNOME／KDE 托盤驗收 |
| Go 管理層與 vet | 匯入、設定管理、代理還原、單一管理程序鎖、更新與真實核心測試通過；Windows／Linux `go vet ./...` 通過。最終 Arch `go test -race ./... -count=1` 通過，約 173 秒 |
| 匯入格式 | SS、VMess、VLESS、Trojan、HY2、TUIC、AnyTLS；AnyTLS + REALITY、明文／Base64、Clash YAML、重複與群組保留名稱、部分無效連結、過大下載及 HTTP 失敗。節點／inline／HTTP／本機 file provider-only YAML 的基本群組產生、保留 DNS 與核心驗證亦通過 |
| 真實 Controller / 核心 | 本機 direct 節點與 select 群組切換／保存、延遲測試、流量／連線事件、連線中止、核心日誌、三種模式、訂閱更新失敗保留有效內容、無效 YAML 保留執行設定、備份／還原、崩潰後顯示停止並可重連 |
| Linux TUN | 實際 gVisor TUN 在隔離網路中建立介面與路由、DNS 攔截、停止後介面與路由清理 |
| Linux 權限服務 | 實際 root bridge 與 UID 1000 客戶端；UID 1001 拒絕、受限操作拒絕、TUN 啟動、客戶端直接斷開後清理核心與 TUN |
| GNOME／KDE 代理工具 | Arch 與 Ubuntu 24.04 隔離環境中的實際 GSettings／KConfig；設定／還原一致，連線期間外部修改的代理端點／連接埠保留。此結果不等同完整 KDE 6 桌面驗收 |
| 核心更新 | 真實舊核心執行期間模擬官方資產：checksum 錯誤、錯誤架構、下載中斷、API 欄位不相容、新版啟動失敗，全部保留舊核心；有效更新與下次啟動失敗回復通過 |
| 官方核心更新實測 | Windows 獨立測試資料目錄、系統代理與 TUN 關閉：從固定 `alpha-main-a9a3350` 實際下載官方 `aster-core-windows-amd64-v1-alpha-main-56e24f5.zip`，SHA-256／架構／API／設定驗證、更新後 `alpha-main-56e24f5` 重新啟動與停止全部通過。測試目錄已清理 |
| Go 跨平台編譯 | Windows amd64、Linux amd64、Darwin amd64 / arm64 通過；Darwin 編譯不代表 Swift／Flutter 或 macOS 權限已驗證 |
| Windows 打包 | Release GUI、獨立 bridge／gVisor core、VC runtime、第三方授權、可攜 ZIP 與原生安裝器；安裝器嵌入 ZIP 的完整性／必要檔案／路徑檢查通過 |
| Ubuntu 套件 | 最終 CI 通過分析、元件／真實核心測試、原生 GUI 與 deb／可攜包建置；下載後在 Ubuntu 24.04 rootfs 重新安裝 deb，依賴解析、核心啟動及套件內 GUI 在 Xvfb 持續執行通過 |
| macOS 原生畫面 | Intel／Apple Silicon 的 [畫面基準 CI](https://github.com/Miku0139oao/aster-desktop/actions/runs/37035312635) 通過；已人工檢視並納入各平台淺／深色／繁中基準 |
| macOS Intel／Apple Silicon | 最終 CI 的兩個 Mac job 均通過分析、9 項元件測試、Swift XPC 助手／Flutter／Go 原生編譯、真實核心／更新回復測試、本機簽署、PKG 與 DMG。兩份 DMG 已下載並核對 SHA-256；Mac 原生 GUI 與權限流程仍待實機驗收 |

分享連結測試證明轉換與核心設定驗證，不代表已與七種協議的遠端伺服器逐一完成網路互通。更新的失敗測試使用本機 HTTP fixture 與真實原核心，另有上表的官方下載實測；未為測試覆寫使用者已安裝核心。套件以私人 GitHub prerelease 交付，未作正式穩定發行。

## 尚待完成的驗收

| 項目 | 狀態／需要的環境 |
|---|---|
| macOS 網路／代理／TUN | 待 macOS 13+ 實機；包含授權拒絕、網路服務切換、既有 PAC／認證代理、TUN 清理與睡眠喚醒 |
| Windows 完整安裝／服務 | 已驗證安裝器 payload；尚未進行管理員 UAC 安裝／卸載、服務 named-pipe 權限、Windows TUN 與乾淨 Windows 10／11 機器驗收 |
| Windows 系統代理 | 原生 WinInet adapter 與所有權還原邏輯已實作／測試；未改動本機使用者的實際全域代理設定 |
| GNOME / KDE 桌面 | 待完整桌面環境中的托盤、GUI polkit 授權拒絕／安裝／卸載與通知；目前 Linux GUI 使用 Xvfb，代理工具在私人 DBus／KConfig 設定目錄測試 |
| 睡眠／喚醒／登入自啟 | 已實作自啟與輪詢重連狀態，實際作業系統登入／睡眠週期待實測 |
| 大量連線壓力 | 2,000 節點與 10,000 筆連線的元件測試已通過；大量真實活躍連線／長時間流量仍待壓力測試 |
| 非正常 broker 終止 | 正常退出、EOF、核心崩潰、服務客戶端斷開已驗證。Unix 一般低權限 broker 遭 SIGKILL 時的孤兒核心與設定回收仍需主機驗證 |

私人 repository 為 [Miku0139oao/aster-desktop](https://github.com/Miku0139oao/aster-desktop)。套件內文件是 CI 打包時的快照；本紀錄補充已完成的最終結果。正式 macOS 簽署／公證入口保留在建置腳本。

## 重現指令

```powershell
flutter pub get --enforce-lockfile
flutter analyze
flutter test
flutter test integration_test -d windows
$env:ASTER_TEST_CORE="$pwd/.build/aster-core.exe"
cd bridge
go test ./... -count=1
go vet ./...
```

```sh
# Linux，在已依 scripts/build.sh 建置的 checkout 執行
export GOTOOLCHAIN=go1.26.3
xvfb-run -a flutter test integration_test -d linux
(cd bridge && ASTER_TEST_CORE="$PWD/../.build/aster-core" CGO_ENABLED=1 go test -race ./... -count=1)
# root：下方腳本自行進入 mount/network namespace，不使用主機路由
sudo -E bash scripts/test-linux-isolated.sh
# GNOME 使用私人設定目錄／DBus，不修改登入桌面的設定
testconfig=$(mktemp -d)
(cd bridge && XDG_CONFIG_HOME="$testconfig" ASTER_TEST_GNOME=isolated-dbus dbus-run-session -- go test ./internal/desktop -run TestIsolatedGnomeProxyRestoration -count=1 -v)
rm -rf -- "$testconfig"
```

淺／深色與繁中畫面在 `evidence/`。每份最終交付包及對應來源包的 SHA-256 在 `dist/checksums.txt`。測試日誌保存於開發環境 `.build/`；其內容含本機路徑，不納入一般程式套件。
