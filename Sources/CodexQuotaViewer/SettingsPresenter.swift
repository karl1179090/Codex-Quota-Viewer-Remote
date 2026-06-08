import AppKit
import Foundation

@MainActor
struct SettingsPresenterCallbacks {
    let onSettingsChanged: (AppSettings) -> Void
    let onAddChatGPTAccount: () -> Void
    let onCancelChatGPTLogin: () -> Void
    let onAddAPIAccount: () -> Void
    let onActivateAccount: (String) -> Void
    let onRenameAccount: (String) -> Void
    let onForgetAccount: (String) -> Void
    let onOpenVaultFolder: () -> Void
    let onSyncCurrentRemoteConfig: () -> Void
    let onRepairHistoryMetadata: (HistoryMetadataRepairScope) -> Void
    let onWindowClosed: () -> Void

    init(
        onSettingsChanged: @escaping (AppSettings) -> Void = { _ in },
        onAddChatGPTAccount: @escaping () -> Void = {},
        onCancelChatGPTLogin: @escaping () -> Void = {},
        onAddAPIAccount: @escaping () -> Void = {},
        onActivateAccount: @escaping (String) -> Void = { _ in },
        onRenameAccount: @escaping (String) -> Void = { _ in },
        onForgetAccount: @escaping (String) -> Void = { _ in },
        onOpenVaultFolder: @escaping () -> Void = {},
        onSyncCurrentRemoteConfig: @escaping () -> Void = {},
        onRepairHistoryMetadata: @escaping (HistoryMetadataRepairScope) -> Void = { _ in },
        onWindowClosed: @escaping () -> Void = {}
    ) {
        self.onSettingsChanged = onSettingsChanged
        self.onAddChatGPTAccount = onAddChatGPTAccount
        self.onCancelChatGPTLogin = onCancelChatGPTLogin
        self.onAddAPIAccount = onAddAPIAccount
        self.onActivateAccount = onActivateAccount
        self.onRenameAccount = onRenameAccount
        self.onForgetAccount = onForgetAccount
        self.onOpenVaultFolder = onOpenVaultFolder
        self.onSyncCurrentRemoteConfig = onSyncCurrentRemoteConfig
        self.onRepairHistoryMetadata = onRepairHistoryMetadata
        self.onWindowClosed = onWindowClosed
    }
}

@MainActor
protocol SettingsWindowPresenting: AnyObject {
    var isVisible: Bool { get }

    func update(
        settings: AppSettings,
        accountPanelState: SettingsAccountPanelState
    )

    func show(
        settings: AppSettings,
        accountPanelState: SettingsAccountPanelState,
        callbacks: SettingsPresenterCallbacks
    )
}

@MainActor
final class SettingsPresenter {
    private var controller: SettingsWindowController?

    var isVisible: Bool {
        controller?.window?.isVisible == true
    }

    func update(
        settings: AppSettings,
        accountPanelState: SettingsAccountPanelState
    ) {
        controller?.update(settings: settings, accountPanelState: accountPanelState)
    }

    func show(
        settings: AppSettings,
        accountPanelState: SettingsAccountPanelState,
        callbacks: SettingsPresenterCallbacks
    ) {
        let needsInitialController = controller == nil

        if controller == nil {
            let nextController = SettingsWindowController(
                settings: settings,
                accountPanelState: accountPanelState
            )
            controller = nextController
        }

        if let controller {
            apply(callbacks: callbacks, to: controller)
        }

        if !needsInitialController {
            controller?.update(settings: settings, accountPanelState: accountPanelState)
        }
        controller?.showWindow(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
        controller?.window?.orderFrontRegardless()
    }

    private func apply(
        callbacks: SettingsPresenterCallbacks,
        to controller: SettingsWindowController
    ) {
        controller.onSettingsChanged = callbacks.onSettingsChanged
        controller.onAddChatGPTAccount = callbacks.onAddChatGPTAccount
        controller.onCancelChatGPTLogin = callbacks.onCancelChatGPTLogin
        controller.onAddAPIAccount = callbacks.onAddAPIAccount
        controller.onActivateAccount = callbacks.onActivateAccount
        controller.onRenameAccount = callbacks.onRenameAccount
        controller.onForgetAccount = callbacks.onForgetAccount
        controller.onOpenVaultFolder = callbacks.onOpenVaultFolder
        controller.onSyncCurrentRemoteConfig = callbacks.onSyncCurrentRemoteConfig
        controller.onRepairHistoryMetadata = callbacks.onRepairHistoryMetadata
        controller.onWindowClosed = callbacks.onWindowClosed
    }
}

extension SettingsPresenter: SettingsWindowPresenting {}
