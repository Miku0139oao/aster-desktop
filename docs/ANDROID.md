# Android 版現況

Aster 目前先在同一個 Flutter 專案中加入 Android 平台。介面、訂閱匯入、節點管理、連線狀態、日誌與診斷會與桌面版共用；桌面用的視窗、托盤與單例機制不會在 Android 啟用。

## 目前架構

Android APK 會打包 `mobileapi.aar`。這是 gomobile binding，內含現有的設定、訂閱、RPC、核心管理工作，以及固定版本的 Aster Core。

Flutter 透過 Android service bridge 呼叫這個 binding。因此訂閱匯入、節點選擇、設定驗證與備援資料模型不必在 Dart 裡重寫一次。

Android 的 VPN 權限服務是 `AsterVpnService`。它取得 TUN file descriptor 後交給 in-process core，並透過 socket hook 呼叫 Android `protect()`，避免 core 自身的節點連線再回到 VPN。

## 這個階段的限制

- Android 版仍在開發分支，不是 v0.2.3 正式桌面版的一部分。
- 全域 VPN 需要在 Android 實機完成連線、DNS、UDP 與節點切換測試。
- 應用程式分流會改用 Android package 管理，而不是桌面版的 executable path 規則。

## 本機建置

從專案根目錄執行：

```bash
python3 scripts/build-android.py
```

腳本會先用 gomobile 產生 Android arm64 binding，再執行 `flutter build apk --release`。GitHub CI 也會產出 APK artifact，名稱為 `aster-android`。
