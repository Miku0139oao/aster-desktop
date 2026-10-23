# Android 版現況

Aster 目前先在同一個 Flutter 專案中加入 Android 平台。介面、訂閱匯入、節點管理、連線狀態、日誌與診斷會與桌面版共用；桌面用的視窗、托盤與單例機制不會在 Android 啟用。

Android 版仍在 `feature/android-client` 開發分支，不是 v0.2.3 正式桌面版的一部分。

## 目前架構

Android APK 會打包 `mobileapi.aar`。這是 gomobile binding，內含現有的設定、訂閱、RPC、核心管理工作，以及固定版本的 Aster Core。

Flutter 透過 `app.astercore/android` MethodChannel 呼叫 `AsterVpnService`。訂閱匯入、節點選擇、設定驗證與備援資料模型不必在 Dart 裡重寫一次。

`AsterVpnService` 是前景服務。`MainActivity` 只負責 `VpnService.prepare`、綁定 service 與轉送 RPC；使用者按下連線後，service 以 `startForegroundService` 啟動，因此 App 進入背景或 Activity 重建時連線仍會繼續。通知列提供「Disconnect」按鈕。

連線流程：

1. Flutter 呼叫 `startVpn`。
2. `MainActivity` 先請求通知權限（Android 13+），完成後才取得 Android VPN 授權（第一次會顯示系統對話框）。兩個對話框循序顯示，避免前景服務啟動被授權流程延遲。
3. `AsterVpnService` 讀取裝置上的應用程式分流設定，用 `VpnService.Builder` 建立 TUN，MTU 9000、IPv4 `198.19.0.1/30`、IPv6 `fdfe:dcba:9876::1/126`、DNS `198.19.0.2` 與 `fdfe:dcba:9876::2`、IPv4/IPv6 預設路由。Android 版固定使用 `198.19.0.0/16` 作為 fake-IP 範圍，避開底層透明代理常用的 `198.18.0.0/16`；兩者重疊時，應用程式可能拿到另一個代理的 fake IP，連線會卡在 SYN-SENT。IPv6 位址是必要的：只加 IPv6 路由而沒有介面位址時，應用程式的 IPv6 socket 會因沒有來源位址而先失敗。TUN 建立後先以 `MobileHost.validateVPN` 驗證目前設定（包含遠端 rule-provider 與 MMDB 下載）；此時 `VpnService.protect()` 已能保護下載 socket。驗證失敗會直接關閉 TUN，不會把 fd 交給 core；通過後才 `detachFd()`。
4. TUN file descriptor 交給同一程序內的 Aster Core。Core 使用 `auto-route: false` 與 `auto-detect-interface: false`：路由由 Android 的 VpnService 管理，而 `auto-detect-interface` 的 netlink 監控在 Android 14 以上的 App 可能被 SELinux 禁止；對外 socket 改由 `VpnService.protect()` 保證繞過 VPN。Core 也強制使用 `stack: gvisor`；system／mixed stack 需要自行管理介面，在 fd 模式下不會回應應用程式連線。
5. Core 的對外 socket 透過 `SocketProtector` 呼叫 `VpnService.protect()`，避免節點連線再繞回 VPN。

gomobile 使用 `with_gvisor cmfa` build tag。`cmfa` 會停用 core 內建的 `/data/system/packages.xml` 讀取；一般 Android App 沒有權限讀取該檔案，若不停用會讓 TUN 建立失敗。應用程式分流因此由 `VpnService.Builder` 執行。Android 的系統 DNS 由 Kotlin 從 `LinkProperties` 讀取後，透過 `MobileHost.setSystemDNS` 注入 core。讀取發生在建立 TUN 之前，需要 `ACCESS_NETWORK_STATE`，並優先選擇非 VPN 的底層網路；否則重連時可能讀到上一條 VPN 的 `198.19.0.2`，而此時 core 尚未啟動，遠端 MMDB／規則資料庫會解析失敗。

## 應用程式分流

Android 版不使用桌面版的 `PROCESS-PATH`／執行檔路徑 UI。應用到「應用程式」頁會列出已安裝套件，支援搜尋與多選，每個 App 可設定：

- **代理**：加入 VPN。全域模式關閉「只代理選取的應用程式」時，這是預設值。
- **直連**：不加入 VPN，流量直接由 Android 網路發出。
- **排除**：不加入 VPN，且不傳給 core 任何提示規則。

Android 的 `VpnService` 只能以套件為單位決定是否進入 VPN，因此「直連」與「排除」在裝置上的實際效果相同：兩者都不經由 Aster。差別只在 core 的 `exclude-package` 提示；文件與 UI 都明確說明這一點，避免誤稱可以做 TUN 內的 UID 分流。

設定以 JSON 儲存在 App 的 `SharedPreferences`（`aster_android/app_routing`），屬於裝置層級。更新訂閱、切換節點或修改 profile 都不會清除。變更在下次連線時生效。

`include-package`／`exclude-package` 仍會寫入 core 的 TUN 設定，作為未來 core 自行管理 TUN 時的相容路徑；目前 fd 模式由 VpnService.Builder 實際執行過濾。

## 已知限制

- 尚未在本專案的 CI 或開發環境中完成 Android 實機／emulator 的 VPN 連線、DNS、UDP、節點切換與斷線清理驗證。在完成實機驗證前，不應宣稱 Android VPN 已可正式使用。
- `QUERY_ALL_PACKAGES` 用來列出所有已安裝 App。直接安裝 APK 沒問題；若要上架 Google Play，需依該權限政策提出 VPN／安全用途說明，或改為只列出有啟動圖示的 App。
- Android 13 以上首次連線會請求通知權限。即使拒絕，VPN 仍可運作，但通知列可能不顯示。
- CI 產生的 APK 目前使用 Gradle 的 debug 簽章，且每個 runner 的除錯金鑰不同，只能視為測試包；要提供可覆蓋更新的正式 APK，必須另外設定固定的 release keystore。
- 桌面版的系統代理、TUN 網路介面選擇與背景服務授權不適用於 Android，已在設定頁隱藏。

## 建置需求

- Flutter 3.47.6
- Go 1.26.3
- JDK 17
- Android NDK r28c，版本目錄必須是 `28.2.13676358`
- Android SDK（Flutter 會使用 `ANDROID_HOME`）
- 執行 gomobile 時需要 `ANDROID_NDK_HOME` 指向上述 NDK

從專案根目錄執行：

```bash
python3 scripts/build-android.py
```

腳本會用 gomobile 產生 `android/app/libs/mobileapi.aar`（arm64-v8a 與 x86_64），再以 `--target-platform android-arm64,android-x64` 執行 `flutter build apk --release`。建置後會檢查 APK 只包含這兩個 ABI，且兩者都有 `libgojni.so`；若 Flutter 額外打包了沒有對應 Go 引擎的 armeabi-v7a，建置會直接失敗。GitHub CI 的 `android` job 會下載 r28c、放進 SDK 的 `ndk/28.2.13676358`，並上傳名為 `aster-android` 的 artifact，內容包含 `app-release.apk` 與 checksums。

## 驗證清單

本機可重現的檢查：

```bash
flutter analyze
flutter test
cd bridge && go test ./...
GOOS=android GOARCH=arm64 CGO_ENABLED=0 go build ./...
GOOS=android GOARCH=arm64 CGO_ENABLED=0 go build -tags "with_gvisor cmfa" ./...
```

實機或 emulator 需要另外確認：

1. `adb install -r build/app/outputs/flutter-apk/app-release.apk`
2. 匯入訂閱、選擇節點。
3. 開啟應用程式分流，將瀏覽器設為「代理」、另一個 App 設為「直連」。
4. 連線並同意 Android VPN 授權。
5. 瀏覽器可上網，直連 App 的流量不經過 Aster。
6. 以 `adb logcat -s AsterVpnService` 檢查 service 與 core 錯誤。
7. 切換節點、關閉螢幕、把 App 送到背景，確認連線持續。
8. 斷線後確認 TUN 關閉、core 停止、通知消失；再從系統設定撤銷 VPN 權限，確認 `onRevoke` 完成清理。
