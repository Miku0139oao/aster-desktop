# 開發、建置與授權

桌面介面使用 MyGo 原生 UI 與 Go **1.27.3**，版本固定在根目錄的 `go.mod`。橋接層與核心使用 Go **1.26.3**。Android、iOS 使用 Flutter **3.47.6**（`5fc346839b5d0eef006ed8404392afb4dfae428d`）。核心及轉換器固定在 **`a9a33503b39a03681bc52d9758907316a22df199`**，核心使用 `with_gvisor`。單獨更新核心不會改變內嵌轉換器。

```powershell
# Windows x64
./scripts/build.ps1 -Installer
```

```sh
# Linux：GTK 3、AppIndicator 與 OpenGL 執行環境
# macOS：Xcode 命令列工具，用於編譯並簽署背景服務與 XPC 函式庫
bash scripts/build.sh
```

結果在 `dist/`，含套件、對應桌面／固定核心來源包及 `checksums.txt`。Windows 使用 Go 建置的原生安裝器，升權後在管理員專用目錄展開安裝資料。Linux 在 Ubuntu 24.04 建置 deb 與 Ubuntu 可攜包，在 Arch 建置 Arch 套件與 Arch 可攜包，各自連結對應的 AppIndicator 函式庫。Mac DMG 內含保護安裝所有權的 PKG。正式 Mac 簽署設定 `ASTER_SIGN_IDENTITY` 和 `ASTER_NOTARY_PROFILE`。CI 在 `.github/workflows/build.yml`，推送到 repository 後自動執行。

根目錄的 `go test ./...` 驗證 MyGo 介面與單一執行個體。設定 `ASTER_TEST_BRIDGE`、`ASTER_TEST_CORE` 為建置產物的絕對路徑，可測試真實的匯入、選節點與核心啟停。設定 `ASTER_TEST_ARTIFACTS` 為絕對目錄，可存下首頁的深色、淺色與繁體中文截圖。橋接層測試在 `bridge/` 執行 `go test ./...`。行動版沿用各自的 Flutter 建置說明。

Go 桌面程式與橋接層可交叉編譯。桌面打包工具、系統代理、TUN、授權與睡眠喚醒需在對應平台驗證。

## 使用文件打包

文件可獨立於已驗證的安裝包發佈，不需要重新建置 GUI。以下指令建立可離線閱讀的 HTML／Markdown ZIP，解壓後開啟 `index.html`：

```sh
python -m pip install -r scripts/docs-requirements.txt
python scripts/package-docs.py --output dist
```

`--version` 預設讀取 `pubspec.yaml`；只有要為舊版重製文件時才需要指定。桌面打包腳本（`build.sh`、`build.ps1`、`package-linux.sh`、`package-windows.ps1`）也從 `pubspec.yaml` 取得版本。Go 橋接層的預設版本在 `bridge/internal/desktop/model.go`：桌面建置會用 `-ldflags` 覆寫成 pubspec 版本，但 Android／iOS 的 gomobile 建置無法套用同一個旗標，所以 `TestVersionMatchesPubspec` 要求兩者相等，升版時必須一起改。

## 發佈

1. 更新 `pubspec.yaml` 的 `version`、`bridge/internal/desktop/model.go` 的 `Version` 預設值，以及 `CHANGELOG.md` 同版本小節（`go test ./...` 會檢查前兩者一致），合併到 `main`。
2. 在 `main` 建置通過後建立並推送 tag：`git tag v<version> && git push origin v<version>`。
3. tag 觸發 `.github/workflows/build.yml`：`release` job 只在 tag 上執行，等桌面四種 runner、Android 與 iOS 全部完成後，下載各平台 artifact、產生離線文件、合併重複的來源包、寫出 `SHA256SUMS`，再以 `gh release create` 發佈。tag 與 `pubspec.yaml` 版本不一致時會直接失敗。
4. 發佈後可用 `scripts/assemble-release.py` 在本機檢視同名資產如何彙整；建置結果在 workflow summary 與發佈頁。

## 授權

GPL-3.0，見 [LICENSE](../LICENSE)。[固定核心來源](https://github.com/Miku0139oao/aster-core/tree/a9a33503b39a03681bc52d9758907316a22df199)、[第三方聲明](../NOTICE.md)。打包時包含 Go 依賴授權與版本清單；Flutter 第三方授權在 NOTICES 資源。對外散佈二進位包時，需提供對應桌面原始碼、固定核心原始碼及建置腳本。
