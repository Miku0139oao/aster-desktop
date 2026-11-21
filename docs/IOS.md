# iOS 版

Aster iOS 使用與桌面、Android 相同的 Flutter／Material 3 介面，並以 NetworkExtension Packet Tunnel Provider 執行 Aster Core。

## 架構

- `AsterIOSHost` 管理 App 內的訂閱、設定與一般 RPC。
- `AsterTunnelProvider` 在獨立 NetworkExtension process 內啟動 core。
- extension 收到停止要求後不會再啟動 core，避免 tunnel 已在拆除時留下仍在執行的 engine 或重複回報完成。
- `mobileapi.xcframework` 由 gomobile 產生，包含管理層與固定版本的 Aster Core。
- App 與 extension 透過 `group.app.aster.desktop` App Group 共用狀態。
- 兩邊的 core host 會對 App Group 內的 engine 取得互斥鎖；同一時間只會有一個 process 持有 core，避免兩份狀態互相覆寫。
- Tunnel 啟動前，App 關閉自己的 core host；連線期間所有狀態與 controller 請求經 `NETunnelProviderSession` 交給 extension。
- 斷線後，App 會等 tunnel 真正進入 `disconnected` 並釋放鎖，才重新取得 host；短暫的鎖殘留會重試，不會再誤報「已在執行」。
- App 進入背景時會釋放 in-app host，讓使用者從「設定」、控制中心或捷徑啟動的 tunnel 能取得鎖；回到前景後再按需重開。
- Flutter 每兩秒輪詢一次狀態，所有通道請求、Siri／捷徑與狀態變更都經過序列化，避免輪詢和連線／斷線交錯。
- Tunnel 找出自己的 utun descriptor 後，複製一份交給 core，core 停止時關閉的是副本，不會影響 NetworkExtension 的封包流程；iOS 不支援 Android 的套件層級分流，啟動時會清空套件選取條件。
- Tunnel 生效前會先讀取裝置當下的 DNS 解析器，並在設定檔仍使用預設 `system` 時注入 core；tunnel 生效後 `/etc/resolv.conf` 可能指向 Aster 自己的位址，不能再用來解析節點網域。設定檔若已指定 `dns.nameserver`，則維持原設定。

## App Intents

第一版提供四個系統入口：

- Connect Aster
- Disconnect Aster
- Check Aster status
- Open Aster nodes

前三個可在 Siri／捷徑中執行；節點選擇會開啟 App 並切換到節點頁。Connect 失敗時會回報失敗原因，不再一律顯示已連線。

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

1. 用固定版本的 gomobile 產生 `ios/mobileapi.xcframework`；`gomobile init` 會把 gobind 換成 latest，腳本會再裝回固定版本。
2. 執行 `scripts/configure-ios.rb`，加入 `AsterTunnel` extension、App Group entitlement 與 framework 連結（靜態 framework 不嵌入）。
3. 執行 Flutter unsigned iOS release build。

CI 另會確認產物內含：

- `Runner.app`
- `PlugIns/AsterTunnel.appex`
- `Metadata.appintents`
- Packet Tunnel extension point 與 `app.aster.desktop`／`app.aster.desktop.tunnel` bundle id
- App 與 extension 的 App Group 及 `packet-tunnel-provider` entitlement 設定
- App 與 extension 都靜態連結 `Mobileapi`（gomobile 產生的 framework 是靜態的，只連結、不嵌入，也不會出現在 `otool -L`）

## 目前限制

- 尚未在 iPhone 實機驗證；背景／前景切換與從系統設定啟動 tunnel 需在真機確認。
- Tunnel fd 取得依賴 iOS utun descriptor，需在支援的 iOS 版本與真機確認。
- App 分流在 iOS 受 Apple NetworkExtension 限制，不能照搬 Android 的 package VPN。
- iOS 沒有 Android 的 `VpnService.protect()`；NetworkExtension 不會把 tunnel process 自己的連線送回同一個 utun，因此 core 直接對外連線即可。
- 連線中若修改會影響 TUN 的設定（例如 MTU），需重新連線才會生效，避免 core 用已關閉的 descriptor 重建 TUN。
- 匯出檔案會存到 App 文件夾並顯示在「檔案」App；iOS 不提供桌面版的自訂儲存位置對話框。
- XCFramework 與未簽章 build 不會提交到 Git。
