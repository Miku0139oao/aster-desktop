# 開發、建置與授權

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

## 使用文件打包

文件可獨立於已驗證的安裝包發佈，不需要重新建置 GUI。以下指令建立可離線閱讀的 HTML／Markdown ZIP，解壓後開啟 `index.html`：

```sh
python -m pip install -r scripts/docs-requirements.txt
python scripts/package-docs.py --version 0.2.3 --output dist
```

## 授權

GPL-3.0，見 [LICENSE](../LICENSE)。[固定核心來源](https://github.com/Miku0139oao/aster-core/tree/a9a33503b39a03681bc52d9758907316a22df199)、[第三方聲明](../NOTICE.md)。打包時包含 Go 依賴授權與版本清單；Flutter 第三方授權在 NOTICES 資源。對外散佈二進位包時，需提供對應桌面原始碼、固定核心原始碼及建置腳本。
