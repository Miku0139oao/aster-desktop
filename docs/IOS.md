# iOS 版

Aster iOS 使用與桌面、Android 相同的 Flutter／Material 3 介面，並以 NetworkExtension Packet Tunnel Provider 執行 Aster Core。

## 架構

- `AsterIOSHost` 管理 App 內的訂閱、設定與一般 RPC。
- `AsterTunnelProvider` 在獨立 NetworkExtension process 內啟動 core。
- `mobileapi.xcframework` 由 gomobile 產生，包含管理層與固定版本的 Aster Core。
- App 與 extension 透過 `group.app.aster.desktop` App Group 共用狀態。
- Tunnel 啟動前，App 關閉自己的 core host；連線期間所有狀態與 controller 請求經 `NETunnelProviderSession` 交給 extension。
- 斷線後，App 重新取得 host，恢復一般管理操作。

## App Intents

第一版提供四個系統入口：

- Connect Aster
- Disconnect Aster
- Check Aster status
- Open Aster nodes

前三個可在 Siri／捷徑中執行；節點選擇會開啟 App 並切換到節點頁。

## 簽章與測試

iOS 目前可在沒有付費 Apple Developer Program 的情況下完成：

- Flutter iOS 編譯
- Go XCFramework 產生
- NetworkExtension 與 App Intents 編譯
- 未簽章 CI 產物

以下項目需要付費 Apple Developer Program：

- TestFlight
- Ad Hoc IPA
- NetworkExtension 實機授權
- App Store 發佈

正式建置需要建立 App ID、App Group、NetworkExtension capability 與對應 provisioning profile。CI 目前使用 `--no-codesign`，產物只供編譯與結構檢查，不能直接安裝在一般 iPhone。

## 建置

在 macOS 執行：

```bash
gem install xcodeproj --no-document
flutter pub get --enforce-lockfile
python3 scripts/build-ios.py
```

`scripts/build-ios.py` 會：

1. 用 gomobile 產生 `ios/mobileapi.xcframework`。
2. 執行 `scripts/configure-ios.rb`，加入 `AsterTunnel` extension、App Group entitlement、framework 與 embed phase。
3. 執行 Flutter unsigned iOS release build。

## 目前限制

- 尚未在 iPhone 實機驗證。
- Tunnel fd 取得依賴 iOS utun descriptor，需在支援的 iOS 版本與真機確認。
- App 分流在 iOS 受 Apple NetworkExtension 限制，不能照搬 Android 的 package VPN。
- XCFramework 與未簽章 build 不會提交到 Git。
