# Android 版現況

Aster 目前先在同一個 Flutter 專案中加入 Android 平台。介面、訂閱匯入、節點管理、連線狀態、日誌與診斷會與桌面版共用；桌面用的視窗、托盤與單例機制不會在 Android 啟用。

## 目前架構

Android APK 會把兩個 Go 引擎包進 native library：

- `libaster_bridge.so`：現有的設定、訂閱、RPC 與核心管理工作。
- `libaster_core.so`：固定版本的 Aster Core，使用 `with_gvisor`。

Flutter 透過 Android `nativeLibraryDir` 找到這兩個引擎，再沿用既有的 line-based JSON RPC。因此訂閱匯入、節點選擇、設定驗證與備援資料模型不必在 Dart 裡重寫一次。

Android 的 VPN 權限服務已註冊為 `AsterVpnService`。下一階段會在這個服務內建立 Go mobile bridge，讓 Android `VpnService` 取得的 TUN file descriptor 交給 core，並啟用「代理所有應用程式」與 package 分流。

## 這個階段的限制

- Android 版仍在開發分支，不是 v0.2.3 正式桌面版的一部分。
- 目前可啟動本機 mixed proxy 與共用管理工作；還沒有完整 Android 全域 VPN。
- 「代理所有應用程式」仍需要下一階段的 VpnService fd bridge。
- 應用程式分流會改用 Android package 管理，而不是桌面版的 executable path 規則。

## 本機建置

從專案根目錄執行：

```bash
python3 scripts/build-android.py --abis arm64-v8a
```

腳本會先產生 Android 64-bit 引擎，再執行 `flutter build apk --release --split-per-abi`。GitHub CI 也會產出 APK artifact，名稱為 `aster-android`。
