import AppIntents
import Foundation

@available(iOS 16.0, *)
struct ConnectAsterIntent: AppIntent {
    static var title: LocalizedStringResource = "Connect Aster"
    static var description = IntentDescription("Starts the configured Aster VPN.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await AsterIOSHost.shared.connectFromIntent()
        return .result(dialog: "Aster connected.")
    }
}

@available(iOS 16.0, *)
struct DisconnectAsterIntent: AppIntent {
    static var title: LocalizedStringResource = "Disconnect Aster"
    static var description = IntentDescription("Stops the Aster VPN.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await AsterIOSHost.shared.disconnectFromIntent()
        return .result(dialog: "Aster disconnected.")
    }
}

@available(iOS 16.0, *)
struct AsterStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Check Aster Status"
    static var description = IntentDescription("Reports whether the Aster VPN is connected.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let status = await AsterIOSHost.shared.currentStatus()
        return .result(dialog: "Aster is \(status).")
    }
}

@available(iOS 16.0, *)
struct OpenAsterNodesIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Aster Nodes"
    static var description = IntentDescription("Opens Aster at the node selector.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set("nodes", forKey: "AsterPendingRoute")
        return .result()
    }
}

@available(iOS 16.0, *)
struct AsterAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConnectAsterIntent(),
            phrases: ["Connect \(.applicationName)"],
            shortTitle: "Connect",
            systemImageName: "shield.fill"
        )
        AppShortcut(
            intent: DisconnectAsterIntent(),
            phrases: ["Disconnect \(.applicationName)"],
            shortTitle: "Disconnect",
            systemImageName: "shield.slash.fill"
        )
        AppShortcut(
            intent: AsterStatusIntent(),
            phrases: ["Check \(.applicationName) status"],
            shortTitle: "Status",
            systemImageName: "waveform.path.ecg"
        )
        AppShortcut(
            intent: OpenAsterNodesIntent(),
            phrases: ["Choose \(.applicationName) node"],
            shortTitle: "Choose Node",
            systemImageName: "network"
        )
    }
}
