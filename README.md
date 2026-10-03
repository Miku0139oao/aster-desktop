# Aster Desktop 0.1.3 測試版

Flutter / Material 3 桌面代理客戶端，依賴獨立 Aster Core。預設繁體中文、紫色主題，支援英文與淺色／深色／跟隨系統。平台驗證狀態見 [測試紀錄](docs/TESTING.md)，各提交的建置與測試包見 [GitHub Actions](https://github.com/Miku0139oao/aster-desktop/actions/workflows/build.yml)。macOS 實機網路與權限驗收另列，不以 CI 編譯結果代替。

[下載 v0.1.3-beta.1](https://github.com/Miku0139oao/aster-desktop/releases/tag/v0.1.3-beta.1)。新增「進階設定 → 應用程式分流」：從正在執行的程式選取，或瀏覽執行檔，再搜尋並選擇代理群組、具體節點、直連或封鎖；可直接修改／刪除，GUI 新增的規則在訂閱更新後保留。遠端 provider 節點在連線後載入。

GitHub Actions 因帳號付款／花費上限未啟動；Ubuntu 及 Mac 新版套件仍待原生建置。[0.1.1 其他平台套件](https://github.com/Miku0139oao/aster-desktop/releases/tag/v0.1.1-beta.1) 尚未包含後續修正。此 repository 為私人專案，下載需登入有存取權的 GitHub 帳號。

0.1.2 修正遠端規則仍在載入時，15 秒啟動期限提前停止核心並誤報 TUN 未就緒的問題。大型 YAML 改用按可見行繪製的編輯器，避免背景輪詢反覆解析設定或重建整個應用程式，並顯示實際安裝版本。已安裝 Windows 背景服務者請使用新安裝器覆蓋更新，讓服務一起更新；只更換可攜版 GUI 仍會使用舊服務。訂閱與使用者設定會保留。

## 安裝與第一次使用

1. Windows：先從托盤退出 Aster Desktop，執行 `Aster-Desktop-0.1.3-windows-x64-setup.exe`，同意安裝權限，從開始功能表開啟。可攜版先將 ZIP 完整解壓到固定資料夾，再開啟 `aster_desktop.exe`。
2. macOS：開啟對應 Intel / Apple Silicon DMG，執行其中的 PKG，安裝到 `/Applications/Aster Desktop.app`。測試包使用本機簽署；若被系統阻擋，請在「系統設定 → 隱私權與安全性」允許開啟。此流程及背景服務授權需實機驗證。
3. Ubuntu：以系統套件安裝程式開啟 `.deb`。Arch：以套件管理員安裝 `.pkg.tar.zst`。可攜版解壓後執行 `aster_desktop`，需要 GTK 3、AppIndicator、polkit 授權代理。
4. 首頁按「匯入訂閱」，貼上 URL／節點連結／YAML，或選擇本機 YAML。匯入後到「節點」選擇節點，再按「連線」。不需要設定核心路徑、Controller 或密碼。
5. 預設使用系統代理。macOS 首次使用系統代理也會引導授權背景服務，由助手變更網路設定，一般核心仍以使用者權限執行。需要其他應用程式走代理時，開啟「代理所有應用程式」，按提示到進階設定安裝並授權背景服務，再連線。切換這項功能前先斷線。

一般使用只需要上述步驟。下方的建置指令提供給開發者。

## 日常操作

- **首頁**：連線／停止、目前設定與節點、速度、流量、模式、訂閱狀態，錯誤提供復原提示與可展開的細節。
- **節點**：搜尋、群組選擇、延遲測試。離線可選擇匯入的節點，連線時自動套用；遠端 HTTP provider 節點與測速在核心連線後載入。
- **訂閱／設定**：本機／URL Clash YAML、明文／Base64 訂閱、SS、VMess、VLESS、Trojan、HY2、TUIC、AnyTLS（包含 REALITY）。更新／切換／匯出／刪除；部分無效連結顯示行號，更新失敗保留舊內容。
- **連線**：搜尋程序、主機、IP 與規則，中止單一或目前顯示的連線。
- **日誌**：搜尋、等級過濾、複製／匯出，匯出遮蔽常見密碼與分享連結憑證。
- **進階**：DNS、連接埠、區域網路存取、網域／IP／程序分流、規則、背景服務、語言／外觀／自啟、更新；完整 YAML 編輯器提供驗證／套用／備份／還原。

**應用程式分流**：使用「代理所有應用程式」及規則模式，才能接管不遵循系統代理的程式；規則變更適用於新連線。GUI 用實際執行檔路徑比對，使用另一個執行檔的輔助程序可另外加入。選擇群組時跟隨該群組，選擇具體 provider 節點時每個應用各自固定節點，不更改共用群組；節點消失時封鎖流量，可在 GUI 改出口。Mac `.app` 選取與實機權限仍待 Mac 驗證。

使用者回報的 TUN「顯示已連線但無法上網」尚未定位根因；已有的隔離 TUN 測試不能代替故障當下的路由、DNS 及節點驗證。

關閉視窗保留在托盤。請用托盤「退出」停止核心並還原程式管理的系統代理；無托盤環境會在關窗時退出。開機自啟預設關閉，啟用後登入時自動連線。

原始 YAML 與桌面設定分開保存。節點、DNS、規則會保留；Controller、secret、執行位置、連接埠、模式、TUN 與對外管理介面由桌面程式控制。HTTP provider 快取位置改為管理目錄；本機 file provider 在從檔案匯入時內嵌。本機 MRS 規則檔需改為內嵌、文字／YAML 或 HTTP provider。高權限 TUN 不允許任意本機憑證／檔案路徑，憑證需內嵌。詳見 [架構及介面](docs/ARCHITECTURE.md)。

只有節點／provider 的 YAML 與分享連結訂閱會自動產生節點選擇、自動測速群組與基本路由；既有 DNS 內容保留，重複或與內建群組衝突的節點名稱加上序號。已有群組或規則的完整設定會保留原內容。

## 更新與資料

GUI 與核心分開版本化。GUI 新版由使用者下載安裝包手動安裝；程式內提示使用公開的穩定 release API，目前的私人測試版請從上方下載連結取得。核心只在按下「更新核心」後追蹤官方 `Prerelease-main`，檢查 SHA-256、架構、設定與必要 API 欄位，保留上一版並在啟動失敗時回復。TUN 請先停止再更新。使用者核心與背景服務核心各自進行驗證與回復，其中一份失敗會明確報錯，另一份仍保留可用版本。

資料位於系統應用程式支援目錄，由 `path_provider` 取得，包含 `state.json`、`backup-*.yaml`／`backup-*.json`、`runtime/` 與 `cores/`。JSON 備份保存 GUI 分流 metadata，還原時一併復原。設定含訂閱 token、節點密碼，請勿公開。解除安裝保留使用者設定；服務私人狀態位於 ProgramData／`/var/lib/aster-desktop`／`/Library/Application Support/AsterDesktop/service`。

## 開發與建置

固定 Flutter **3.47.6**（`5fc346839b5d0eef006ed8404392afb4dfae428d`）、Go **1.26.3**，依賴固定在 `pubspec.lock` / `go.sum`。核心及轉換器固定 **`a9a33503b39a03681bc52d9758907316a22df199`**，核心使用 `with_gvisor`。單獨更新核心不會改變內嵌轉換器。參考 [Flutter 桌面建置文件](https://docs.flutter.dev/platform-integration/desktop)。

```powershell
# Windows：Visual Studio 2022 C++ 桌面工具鏈
./scripts/build.ps1 -Flutter 'path/to/flutter/bin/flutter.bat' -Installer
```

```sh
# Linux：clang, cmake, ninja, pkg-config, GTK 3/AppIndicator 開發套件；deb 另需 dpkg-deb
# macOS：Xcode CLI、CocoaPods，Intel/Apple Silicon 各自在目標機器建置
ASTER_FLUTTER=/path/to/flutter/bin/flutter bash scripts/build.sh
```

結果在 `dist/`，含套件、對應桌面／固定核心來源包及 `checksums.txt`。Windows 使用 Go 建置的原生安裝器，升權後在管理員專用目錄展開安裝資料。Linux 在 Ubuntu 24.04 建置 deb 與 Ubuntu 可攜包，在 Arch 建置 Arch 套件與 Arch 可攜包，各自連結對應的 AppIndicator 函式庫。Mac DMG 內含保護安裝所有權的 PKG。正式 Mac 簽署設定 `ASTER_SIGN_IDENTITY` 和 `ASTER_NOTARY_PROFILE`。CI 在 `.github/workflows/build.yml`，推送到 repository 後自動執行。

```sh
flutter pub get --enforce-lockfile
flutter analyze
flutter test
cd bridge
go test ./...
go vet ./...
# 設 ASTER_TEST_CORE=/absolute/path/to/pinned/core 啟用真實核心整合測試
```

Flutter 打包各自在該平台執行；Go 橋接層可以交叉編譯。原生代理、TUN、授權、睡眠喚醒需逐平台額外實測，不能以交叉編譯代替。

## 授權

GPL-3.0，見 [LICENSE](LICENSE)。[固定核心來源](https://github.com/Miku0139oao/aster-core/tree/a9a33503b39a03681bc52d9758907316a22df199)、[第三方聲明](NOTICE.md)。打包時包含 Go 依賴授權與版本清單；Flutter 第三方授權在 NOTICES 資源。對外散佈二進位包時，需提供對應桌面原始碼、固定核心原始碼及建置腳本。
