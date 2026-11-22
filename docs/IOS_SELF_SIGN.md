# iOS 自簽安裝教學

這份教學說明如何用自己的 Apple 開發者身分簽章 Aster iOS 版，並安裝到自己的 iPhone。內容對應 `0.4.0` 的專案結構；其他版本請以該版本的原始碼為準。

> **先講最重要的限制**：Aster iOS 以 NetworkExtension Packet Tunnel 執行核心，`com.apple.developer.networking.networkextension`（`packet-tunnel-provider`）只提供給付費 Apple Developer Program 的 App ID。免費 Apple ID、Personal Team、AltStore／SideStore 的免費 7 天簽章都**無法**讓 tunnel 運作，也不是這份教學的適用情境。自簽需要有效的付費會員資格。

## 需要準備什麼

| 項目 | 需求 |
| --- | --- |
| Mac | macOS 14.5 以上。Xcode 16.0–16.2 需 macOS 14.5；Xcode 16.3 需 macOS 15.2；Xcode 16.4 需 macOS 15.3（Xcode 26 以上需 macOS 15.6）。請安裝 Flutter 3.47.6 支援且符合你的 macOS 版本的 Xcode |
| Apple 帳號 | 已加入付費 Apple Developer Program（個人或組織），可在 [developer.apple.com](https://developer.apple.com/account) 登入，並在 Xcode → Settings → Accounts 加入同一個 Apple ID |
| iPhone | iOS 16 以上（建置腳本設定的 deployment target 為 16.0），可連接 Mac |
| Flutter | 3.47.6（版本記錄於 `toolchain.json`） |
| Go | 1.26.3（用來產生 iOS 的 gomobile XCFramework） |
| 其他 | Xcode Command Line Tools、Ruby（含 `xcodeproj` gem；macOS 已不內建系統 Ruby，可用 Homebrew 安裝）、Python 3、CocoaPods（若 Flutter 要求） |

先在終端機確認：

```bash
xcodebuild -version     # Xcode 16 以上，且符合上方 macOS 版本需求
flutter --version       # 3.47.6
go version              # go1.26.3
pod --version           # 沒有安裝時：brew install cocoapods
```

## 兩種自簽方式

| 方式 | 適用情況 | 能否改識別碼 |
| --- | --- | --- |
| **A. 從原始碼建置（建議）** | 有 Mac 與 Xcode，想完整控制簽章與識別碼 | 可以 |
| B. 重新簽章官方 unsigned zip | 不想建置，且預設識別碼仍可註冊在你的帳號下 | 不可以 |

發佈頁的 `Aster-Desktop-<版本>-ios-unsigned.zip` 是 CI 以 `--no-codesign` 產生的 `Runner.app`，**不能直接安裝**，也不能上傳 TestFlight。以下兩種方式都會在你的 Mac 上完成簽章。

## 識別碼的關係

Aster iOS 由兩個 binary 組成，另有一個共用的 App Group：

| 用途 | 預設值 | 定義位置 |
| --- | --- | --- |
| App bundle id | `app.aster.desktop` | `scripts/configure-ios.rb`（建置時寫入 Runner target） |
| Tunnel extension bundle id | `app.aster.desktop.tunnel` | `scripts/configure-ios.rb`（建置時寫入 AsterTunnel target） |
| App Group | `group.app.aster.desktop` | 兩個 `.entitlements` 檔與 `ios/Shared/AsterIOSRuntime.swift` |

App ID 與 App Group 的名稱是全 Apple 開發者帳號共用的。若預設值已被其他人註冊，就必須換成你專屬的前綴（例如 `com.yourname.aster`）。bundle id 與 App Group 會編譯進 App，**換了字串就必須重新建置**，不能只改簽章。

尚未執行 `scripts/build-ios.py` 時，Xcode 專案仍是 Flutter 的預設值（`app.aster.asterDesktop`、deployment target 15.0），也還沒有 AsterTunnel target 與 entitlements 設定；這些都由建置腳本寫入，屬正常現象。

---

## 路線 A：從原始碼建置

### A1. 取得原始碼

```bash
git clone https://github.com/Miku0139oao/aster-desktop.git
cd aster-desktop
git checkout v0.4.0
```

### A2. 決定識別碼（可沿用預設）

若入口網站的 App IDs 與 App Groups 都還能使用預設值，直接跳到 A3。若已被佔用，先設定一個你控制的前綴，例如 `com.yourname.aster`，並**一次改完以下四個檔案中的識別碼**：

1. `scripts/configure-ios.rb:19`：Runner 的 `PRODUCT_BUNDLE_IDENTIFIER`
2. `scripts/configure-ios.rb:59`：AsterTunnel 的 `PRODUCT_BUNDLE_IDENTIFIER`
3. `ios/Shared/AsterIOSRuntime.swift:5-6`：`appGroup` 與 `tunnelBundleIdentifier`
4. `ios/Runner/Runner.entitlements`、`ios/AsterTunnel/AsterTunnel.entitlements`：`group.*` 字串

以 `com.yourname.aster` 為例，各處會變成：

```text
App：        com.yourname.aster
Extension：  com.yourname.aster.tunnel
App Group：  group.com.yourname.aster
```

`configure-ios.rb` 每次執行都會把 Xcode 專案裡的 bundle id 重設成腳本中的值，所以請改腳本（或改完 Xcode 後不要再跑建置腳本），不要只改 Xcode 介面。`.entitlements` 與 `AsterIOSRuntime.swift` 不經由腳本改寫，直接編輯即生效。

### A3. 建置 XCFramework 與未簽章 App

```bash
flutter pub get --enforce-lockfile
# 系統 Ruby 沒有寫入權限時，改用 gem install --user-install xcodeproj --no-document
# 找不到 ruby／gem 時，先安裝 Ruby（例如 brew install ruby）並把其 bin 目錄加入 PATH
sudo gem install xcodeproj --no-document
python3 scripts/build-ios.py
```

`scripts/build-ios.py` 會：

1. 用固定版本的 gomobile／gobind 產生 `ios/mobileapi.xcframework`（第一次會下載工具與相依套件）。
2. 執行 `scripts/configure-ios.rb`，把 AsterTunnel extension、entitlements 與 framework 連結寫進 Xcode 專案。
3. 執行 `flutter build ios --release --no-codesign`，產出 `build/ios/iphoneos/Runner.app`。

Flutter 或 Go 不在 `PATH` 時，可用環境變數指定。兩者都要指向**可執行檔**，不是 SDK 根目錄：

```bash
ASTER_FLUTTER=/path/to/flutter/bin/flutter ASTER_GO=/path/to/go/bin/go python3 scripts/build-ios.py
```

這一步不需要簽章，成功後再進 Xcode 設定簽章即可。

### A4. 在 Apple Developer 建立 App ID 與 App Group

到 [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources)：

1. **Devices → +**：註冊要安裝的 iPhone UDID；Development 與 Ad Hoc 描述檔只包含已註冊的裝置。Flutter 的 `flutter devices` 或 Xcode 連接裝置時都能查到 UDID。
2. **Identifiers → App IDs → +**
   - 選 App，Bundle ID 選 Explicit，填入 App 的 bundle id（例如 `com.yourname.aster`）。
   - 勾選 **App Groups** 與 **Network Extensions**；Network Extensions 的類型需包含 **Packet Tunnel**。
   - 儲存。
3. 再建立一個 App ID，填入 extension 的 bundle id（例如 `com.yourname.aster.tunnel`），同樣啟用 **App Groups** 與 **Network Extensions（Packet Tunnel）**。
4. **Identifiers → App Groups → +** 建立 `group.com.yourname.aster`（或預設的 `group.app.aster.desktop`），回到兩個 App ID 的 Configure 頁面把它指派給兩者。
5. 描述檔交給 Xcode 的自動簽章建立即可（見 A5）。若你偏好手動簽章，才需要到 **Profiles → +** 為兩個 bundle id 各建立 **iOS App Development** 描述檔，選擇憑證與已註冊的裝置後下載。

Xcode 的自動簽章也能代為建立描述檔，但前提是 App ID 已啟用上述 capability；先完成入口網站設定可避免 Xcode 產生缺少 entitlement 的描述檔。

### A5. 在 Xcode 設定簽章

```bash
open ios/Runner.xcworkspace
```

先到 **Xcode → Settings → Accounts → +**，用付費 Apple ID 登入並選取團隊。沒有這一步，下列 Team 下拉選單會是空的，自動簽章也無法建立描述檔。

1. 左側選 **Runner** target → **Signing & Capabilities**：
   - Team 選你的開發者團隊，勾選 **Automatically manage signing**。
   - Bundle Identifier 必須與入口網站的 App ID 完全一致。
   - 確認 capability 清單有 **App Groups**（含你的 group）與 **Network Extensions → Packet Tunnel**。專案的 `.entitlements` 已宣告這些項目；若介面沒列出，按 **+ Capability** 補上，不要刪除既有項目。
2. 選 **AsterTunnel** target，重複上述設定：同一個 Team、extension 的 bundle id、同樣的 App Groups 與 Network Extensions。
3. 若 Xcode 顯示 *Personal development teams do not support the Network Extensions capability*，代表目前是免費 Personal Team，必須改用付費會員。

### A6. 安裝到 iPhone

1. 用傳輸線連接 iPhone，解鎖並在手機上按「信任這部電腦」。
2. 在 Xcode 的 **Window → Devices and Simulators** 或執行目標下拉選單中選一次你的 iPhone，讓 Xcode 辨識這台裝置。
3. 回到手機的 **設定 → 隱私權與安全性 → 開發者模式** 開啟；這個選項要在 Xcode 連接過裝置後才會出現。重新開機後確認開啟，並重新連接、信任這台 Mac。
4. 在 Xcode 上方選擇你的 iPhone 作為執行目標，按 **Run**（⌘R）。
5. 第一次按下 App 內的連線時，系統會詢問是否允許 Aster 新增 VPN 設定，選擇 **允許**；可能需要 Face ID／Touch ID 確認。
6. 匯入訂閱或設定檔，選擇節點後連線。VPN 狀態應出現在 **設定 → 一般 → VPN 與裝置管理**。

若首次開啟顯示「未受信任的開發者」，到 **設定 → 一般 → VPN 與裝置管理 → 開發者 App** 選擇你的開發者憑證並按 **信任**，再重新開啟 App。

要長期使用或備份，可在 Xcode 選 **Any iOS Device (arm64)** → **Product → Archive** → **Distribute App**，選 Ad Hoc 或 App Store Connect。Ad Hoc 只能安裝在已註冊的裝置；TestFlight／App Store 需要 App Store Connect 的 App 記錄。

---

## 路線 B：重新簽章官方 unsigned zip

這條路線不重新編譯，直接把發佈頁的 zip 換成你的簽章。**只能沿用下列預設識別碼**，而且三個名稱都必須尚未被其他帳號註冊：

```text
app.aster.desktop
app.aster.desktop.tunnel
group.app.aster.desktop
```

只要其中一個已被佔用，就只能走路線 A。

### B1. 下載與驗證

將 `Aster-Desktop-0.4.0-ios-unsigned.zip` 與 `Aster-Desktop-0.4.0-ios-checksums.txt` 放在同一資料夾：

```bash
grep -v '^#' Aster-Desktop-0.4.0-ios-checksums.txt | shasum -a 256 -c -
unzip Aster-Desktop-0.4.0-ios-unsigned.zip
```

解壓後會得到 `Runner.app`（內含 `PlugIns/AsterTunnel.appex`）。校驗檔第一行是引擎的 SHA-256 註解，`grep -v '^#'` 會略過它。

### B2. 準備憑證與描述檔

1. 在入口網站建立 `app.aster.desktop` 與 `app.aster.desktop.tunnel` 兩個 App ID，兩者都要有 **App Groups** 與 **Network Extensions（Packet Tunnel）**。
2. 建立 `group.app.aster.desktop` 並指派給兩個 App ID。若名稱已被佔用，此路線不可行。
3. **Devices → +** 註冊要安裝的 iPhone UDID（Xcode 連接裝置時也會顯示）。Development 與 Ad Hoc 描述檔只包含已註冊的裝置。
4. **Profiles → +** 為兩個 bundle id 各建立一份描述檔：
   - **iOS App Development**：搭配 **Apple Development** 憑證，適合直接安裝測試。
   - **Ad Hoc**：搭配 **Apple Distribution** 憑證，只能安裝在已註冊的裝置。
   確認 `Entitlements` 內含：
   - `application-identifier` = `<TEAMID>.app.aster.desktop`（extension 則是 `.tunnel`）
   - `com.apple.developer.networking.networkextension` = `packet-tunnel-provider`
   - `com.apple.security.application-groups` = `group.app.aster.desktop`
5. 把對應的簽章憑證安裝到 Mac 的鑰匙圈：**Xcode → Settings → Accounts → +** 登入 Apple ID，再用 **Manage Certificates → +** 建立 Apple Development 或 Apple Distribution 憑證。確認身分名稱：

```bash
security find-identity -v -p codesigning
```

6. 雙擊下載的 `.mobileprovision` 安裝，或直接保留檔案供下一步使用。

### B3. 由描述檔產生簽章用 entitlements

不要只拿專案的 `.entitlements` 檔簽章：那裡面沒有 `application-identifier` 與 team identifier，安裝時可能被拒絕。直接使用描述檔內的 `Entitlements`，可確保簽章內容與描述檔完全一致：

```bash
security cms -D -i runner.mobileprovision > runner-profile.plist
plutil -extract Entitlements xml1 -o runner.entitlements runner-profile.plist

security cms -D -i tunnel.mobileprovision > tunnel-profile.plist
plutil -extract Entitlements xml1 -o tunnel.entitlements tunnel-profile.plist
```

`runner.mobileprovision`／`tunnel.mobileprovision` 換成你下載的檔名。可先用下列指令確認描述檔對應的 App ID：

```bash
plutil -extract Name raw runner-profile.plist
plutil -extract Entitlements.application-identifier raw runner-profile.plist
```

### B4. 重新簽章（由內而外）

```bash
# Development 描述檔用這個；Ad Hoc 描述檔改成 "Apple Distribution: Your Name (XXXXXXXXXX)"
IDENTITY="Apple Development: Your Name (XXXXXXXXXX)"
TIMESTAMP=--timestamp=none
APP=Runner.app

# 1. 先簽所有內嵌 framework（Flutter 與 Dart 程式碼）
find "$APP" -type d -name '*.framework' -print0 |
  while IFS= read -r -d '' bundle; do
    codesign --force --sign "$IDENTITY" "$TIMESTAMP" "$bundle"
  done

# 2. 放入描述檔：extension 與主 App 各一份
cp tunnel.mobileprovision "$APP/PlugIns/AsterTunnel.appex/embedded.mobileprovision"
cp runner.mobileprovision "$APP/embedded.mobileprovision"

# 3. 先簽 extension，再簽主 App
codesign --force --sign "$IDENTITY" "$TIMESTAMP" \
  --entitlements tunnel.entitlements "$APP/PlugIns/AsterTunnel.appex"
codesign --force --sign "$IDENTITY" "$TIMESTAMP" \
  --entitlements runner.entitlements "$APP"

# 4. 驗證
codesign --verify --deep --strict --verbose=2 "$APP"
```

時間戳不是 iOS 開發或 Ad Hoc 安裝的必要條件，App Store 發佈時也會重新簽章；上面的 `--timestamp=none` 可直接沿用。只有需要讓簽章在憑證到期後仍有效（例如 Developer ID／公證）時，才改成 `--timestamp`。

簽章後原本 zip 的 SHA-256 當然不再相符，這是預期行為；請保留原始 zip 以便重來。

### B5. 安裝到 iPhone

- **Xcode**：Window → Devices and Simulators → 選 iPhone → Installed Apps 下的 **+** → 選 `Runner.app`。
- **命令列**（Xcode 15 以上）：

```bash
xcrun devicectl list devices
xcrun devicectl device install app --device <裝置識別碼> Runner.app
```

- 或把 `Runner.app` 拖進 Apple Configurator 的裝置視窗。

安裝後若 App 閃退或 tunnel 啟動失敗，先確認描述檔的 App Group 與 Network Extension 是否齊全，以及裝置是否已登錄在描述檔中。使用 development 描述檔時，手機也要開啟開發者模式（步驟同 A6）並信任這台 Mac。

---

## 常見錯誤

| 訊息／現象 | 原因與處理 |
| --- | --- |
| `Personal development teams ... do not support the Network Extensions capability` | 免費 Personal Team 不支援 Network Extension；需付費 Apple Developer Program |
| `Provisioning profile ... doesn't include the com.apple.developer.networking.networkextension entitlement` | App ID 沒開 Network Extensions，或描述檔是在開啟前建立的；開啟 capability 後重新產生描述檔 |
| `An App ID with Identifier ... is not available` | bundle id 已被其他帳號註冊；改用你自己的前綴（路線 A） |
| `App Group ... is not available` | App Group 名稱已被佔用；改用你自己的 group（路線 A） |
| 安裝成功但啟動即閃退，日誌出現 App Group 無法取得 | `AsterIOSRuntime.appGroup` 與兩個 entitlements 的 group 不一致；這三個檔案要一起改並重新建置 |
| Tunnel 啟動失敗，日誌提到 provider 或 entitlement | 描述檔缺少 `packet-tunnel-provider`，或 extension 的 App ID 沒開 Network Extensions |
| 安裝時顯示 `Application is missing the application-identifier entitlement` | 重新簽章時沒有使用描述檔內的 Entitlements；回到 B3 重新產生 |
| 安裝時被拒絕，提示 device 不符或未包含 UDID | 裝置未註冊，或描述檔建立後才加入；到 **Devices** 註冊 UDID 後重新產生描述檔，再重新簽章 |
| `code object is not signed at all` | 有內嵌 framework 漏簽；確認 B4 的第一步有涵蓋 `Runner.app` 內所有 `.framework`，且順序是由內而外 |
| 手機找不到 VPN 設定 | 首次連線必須允許 VPN 設定；可到 **設定 → 一般 → VPN 與裝置管理** 檢查 |
| App 過一段時間後無法開啟 | 描述檔到期；Apple 未保證確切期限，通常不超過一年。到期前要重新簽章並**重新安裝**到 iPhone（Xcode Run、`xcrun devicectl device install app` 或 Apple Configurator，見 B5），因為已安裝的 App 內嵌自己的描述檔，只重新簽章 Mac 上的 `Runner.app` 不會更新手機上的那一份 |

## 注意事項

- 自簽只供你在自己擁有或已註冊的裝置上使用。不要公開散布帶有你簽章、描述檔或 Team ID 的 IPA。
- 只簽署你信任的原始碼或校驗過的官方產物；重新簽章不會改變 App 內執行的程式碼。
- Aster Desktop 以 GPL-3.0 授權釋出；自簽不改變授權條款，也不代表取得 Aster 專案的簽章或背書。
- 這份教學涉及 Apple 開發者帳號與憑證，請勿把 `.p12`、描述檔或密碼提交到 Git 或貼到公開討論區。

相關文件：[iOS 版說明](IOS.md)、[開發與建置](BUILDING.md)、[測試紀錄](TESTING.md)。
