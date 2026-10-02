# Aster Desktop 0.1.0 測試紀錄

日期：2026-10-03。本紀錄分開標示自動測試、實際核心／GUI 測試，以及尚未完成的作業系統驗收。測試包尚不代表全部平台驗收完成。

## 環境與固定版本

- Windows x64 本機，Visual Studio 2022 C++ 工具鏈，非管理員帳號。
- WSL Arch Linux x64，systemd、GTK 3、AppIndicator、Xvfb。TUN 測試使用獨立 mount/network namespace；不更動主機網路路由。
- Ubuntu 24.04 建置／測試環境正在隔離 rootfs 中驗證，最終結果於此處記錄。
- Flutter 3.47.6 / Dart 3.13.5；Flutter 提交 `5fc346839b5d0eef006ed8404392afb4dfae428d`。
- Go 1.26.3；核心與轉換器提交 `a9a33503b39a03681bc52d9758907316a22df199`。核心使用 `with_gvisor`。

## 已通過

| 測試 | 結果與範圍 |
|---|---|
| Dart 靜態分析 | `flutter analyze`：無問題 |
| Flutter 元件／單元測試 | 6 項通過：首次匯入／連線／停止、匯入失敗保留內容、六頁最小視窗、淺／深色／繁中畫面、2,000 節點搜尋與 150% 文字縮放、日誌匯出憑證遮蔽 |
| Windows 原生 GUI | `flutter test integration_test -d windows`：實際 Flutter 視窗啟動 Go／原核心，在 GUI 匯入 YAML、連線、透過代理存取本機 HTTP、巡覽六頁、停止後代理埠關閉；關窗進托盤仍保持核心執行 |
| Linux 原生 GUI | Xvfb 下相同匯入／HTTP 代理／六頁／停止流程通過；此測試停用托盤生命週期，不等同 GNOME／KDE 托盤驗收 |
| Go 管理層與 vet | 匯入、設定管理、代理還原、單一管理程序鎖、更新與真實核心測試通過；`go vet ./...` 通過 |
| 匯入格式 | SS、VMess、VLESS、Trojan、HY2、TUIC、AnyTLS；AnyTLS + REALITY、明文／Base64、Clash YAML、重複與群組保留名稱、部分無效連結、過大下載及 HTTP 失敗 |
| 真實 Controller / 核心 | 本機 direct 節點與 select 群組切換／保存、延遲測試、流量／連線事件、連線中止、核心日誌、三種模式、訂閱更新失敗保留有效內容、無效 YAML 保留執行設定、備份／還原、崩潰後顯示停止並可重連 |
| Linux TUN | 實際 gVisor TUN 在隔離網路中建立介面與路由、DNS 攔截、停止後介面與路由清理 |
| Linux 權限服務 | 實際 root bridge 與 UID 1000 客戶端；UID 1001 拒絕、受限操作拒絕、TUN 啟動、客戶端直接斷開後清理核心與 TUN |
| GNOME 代理 | 私人 DBus / dconf 環境中的實際 GSettings；設定／還原一致，連線期間外部修改的代理端點／連接埠保留 |
| 核心更新 | 真實舊核心執行期間模擬官方資產：checksum 錯誤、錯誤架構、下載中斷、API 欄位不相容、新版啟動失敗，全部保留舊核心；有效更新與下次啟動失败回復通過 |
| Go 跨平台編譯 | Windows amd64、Linux amd64、Darwin amd64 / arm64 通過；Darwin 編譯不代表 Swift／Flutter 或 macOS 權限已驗證 |
| Windows 打包 | Release GUI、獨立 bridge／gVisor core、VC runtime、第三方授權、可攜 ZIP 與原生安裝器；安裝器嵌入 ZIP 的完整性／必要檔案／路徑檢查通過 |

分享連結測試證明轉換與核心設定驗證，不代表已與七種協議的遠端伺服器逐一完成網路互通。更新的失敗測試使用本機 HTTP fixture 與真實原核心；未為測試覆寫使用者已安裝核心，未在正式 GitHub release 發佈資產。

## 尚待完成的驗收

| 項目 | 狀態／需要的環境 |
|---|---|
| macOS Intel / Apple Silicon | 已提供原生 Swift XPC / SMAppService、建置腳本與 CI matrix；沒有 Mac 主機，CI 尚未執行、DMG 尚未產生。Swift／Flutter 原生編譯、簽署、安裝與背景服務授權結果均待實際 Mac CI／主機 |
| macOS 網路／代理／TUN | 待 macOS 13+ 實機；包含授權拒絕、網路服務切換、既有 PAC／認證代理、TUN 清理與睡眠喚醒 |
| Windows 完整安裝／服務 | 已驗證安裝器 payload；尚未進行管理員 UAC 安裝／卸載、服務 named-pipe 權限、Windows TUN 與乾淨 Windows 10／11 機器驗收 |
| Windows 系統代理 | 原生 WinInet adapter 與所有權還原邏輯已實作／測試；未改動本機使用者的實際全域代理設定 |
| GNOME / KDE 桌面 | 待完整桌面環境中的托盤、GUI polkit 授權拒絕／安裝／卸載、KDE 代理設定與通知；目前 Linux GUI 使用 Xvfb |
| 睡眠／喚醒／登入自啟 | 已實作自啟與輪詢重連狀態，實際作業系統登入／睡眠週期待實測 |
| 大量連線壓力 | 使用 lazy list 與限制併發；2,000 節點的元件測試已通過，大量活躍連線／長時間流量仍待壓力測試 |
| 非正常 broker 終止 | 正常退出、EOF、核心崩潰、服務客戶端斷開已驗證。Unix 一般低權限 broker 遭 SIGKILL 時的孤兒核心與設定回收仍需主機驗證 |

本機 repository 已建立，未設定 GitHub 遠端，沒有宣稱遠端 CI 已通過。正式 macOS 簽署／公證入口保留在建置腳本。

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
