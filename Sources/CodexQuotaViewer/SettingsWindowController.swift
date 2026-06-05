import AppKit
import Foundation

private enum SettingsPane: Int, CaseIterable {
    case general
    case remote
    case accounts
    case advanced

    var symbolName: String {
        switch self {
        case .general:
            "gearshape"
        case .remote:
            "desktopcomputer"
        case .accounts:
            "person"
        case .advanced:
            "slider.horizontal.3"
        }
    }

    var title: String {
        switch self {
        case .general:
            AppLocalization.localized(en: "General", zh: "通用")
        case .remote:
            AppLocalization.localized(en: "Remote", zh: "远程")
        case .accounts:
            AppLocalization.localized(en: "Accounts", zh: "账户")
        case .advanced:
            AppLocalization.localized(en: "Advanced", zh: "高级")
        }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSSearchFieldDelegate {
    var onSettingsChanged: ((AppSettings) -> Void)?
    var onAddChatGPTAccount: (() -> Void)?
    var onCancelChatGPTLogin: (() -> Void)?
    var onAddAPIAccount: (() -> Void)?
    var onActivateAccount: ((String) -> Void)?
    var onRenameAccount: ((String) -> Void)?
    var onForgetAccount: ((String) -> Void)?
    var onOpenVaultFolder: (() -> Void)?
    var onWindowClosed: (() -> Void)?

    private var settings: AppSettings
    private var accountPanelState: SettingsAccountPanelState
    private var sshConfigHosts: [String] = []
    private var selectedSSHConfigHosts = Set<String>()
    private var isApplyingSettings = false
    private let sshConfigHostLoader: () -> [String]

    private let sidebarView = NSView()
    private let contentContainer = NSView()
    private var sidebarItems: [SettingsPane: SettingsSidebarItemView] = [:]
    private var selectedPane: SettingsPane = .remote

    private let generalView = SettingsGeneralView()
    private let remoteView = SettingsRemoteView()
    private let accountsView = SettingsAccountsView()
    private let advancedView = SettingsAdvancedView()
    private lazy var accountsTableController = makeAccountsTableController()

    init(
        settings: AppSettings,
        accountPanelState: SettingsAccountPanelState,
        sshConfigHostLoader: @escaping () -> [String] = { loadSSHConfigHosts() }
    ) {
        self.settings = settings
        self.accountPanelState = accountPanelState
        self.sshConfigHostLoader = sshConfigHostLoader

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppLocalization.localized(en: "Settings", zh: "设置")
        window.center()
        window.minSize = NSSize(width: 860, height: 620)
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
        setupUI()
        applySettingsToControls()
        applyAccountPanelState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(settings: AppSettings, accountPanelState: SettingsAccountPanelState) {
        self.settings = settings
        self.accountPanelState = accountPanelState
        applySettingsToControls()
        applyAccountPanelState()
        applySelectedPaneVisibility()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        applySelectedPaneVisibility()
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        sidebarView.identifier = NSUserInterfaceItemIdentifier("settings.sidebar")
        sidebarView.translatesAutoresizingMaskIntoConstraints = false
        sidebarView.wantsLayer = true
        sidebarView.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.55).cgColor
        contentView.addSubview(sidebarView)

        let divider = NSView()
        divider.identifier = NSUserInterfaceItemIdentifier("settings.sidebar.divider")
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.7).cgColor
        contentView.addSubview(divider)

        contentContainer.identifier = NSUserInterfaceItemIdentifier("settings.content")
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(contentContainer)

        setupSidebar()
        setupPages()
        setupControlBindings()

        NSLayoutConstraint.activate([
            sidebarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            sidebarView.topAnchor.constraint(equalTo: contentView.topAnchor),
            sidebarView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            sidebarView.widthAnchor.constraint(equalToConstant: 220),

            divider.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            divider.topAnchor.constraint(equalTo: contentView.topAnchor),
            divider.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            contentContainer.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        selectPane(.remote)
    }

    private func setupSidebar() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        sidebarView.addSubview(stack)

        for pane in SettingsPane.allCases {
            let item = SettingsSidebarItemView(title: pane.title, symbolName: pane.symbolName, tag: pane.rawValue)
            item.identifier = NSUserInterfaceItemIdentifier("settings.sidebar.\(pane)")
            item.target = self
            item.action = #selector(sidebarItemClicked(_:))
            sidebarItems[pane] = item
            stack.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: sidebarView.topAnchor, constant: 52),
        ])
    }

    private func setupPages() {
        let pages: [NSView] = [generalView, remoteView, accountsView, advancedView]
        for page in pages {
            page.translatesAutoresizingMaskIntoConstraints = false
            contentContainer.addSubview(page)
            NSLayoutConstraint.activate([
                page.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: 44),
                page.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -44),
                page.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 34),
                page.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor, constant: -28),
            ])
        }
    }

    private func setupControlBindings() {
        configurePopup(generalView.refreshPopup, values: RefreshIntervalPreset.allCases.map(\.rawValue))
        configurePopup(generalView.languagePopup, values: AppLanguage.allCases.map(\.rawValue))
        configurePopup(generalView.iconStylePopup, values: StatusItemStyle.allCases.map(\.rawValue))

        generalView.launchAtLoginCheckbox.target = self
        generalView.launchAtLoginCheckbox.action = #selector(controlChanged)

        remoteView.remoteSyncSwitch.target = self
        remoteView.remoteSyncSwitch.action = #selector(controlChanged)
        remoteView.searchField.delegate = self
        remoteView.remotePathField.delegate = self
        remoteView.onHostToggled = { [weak self] host in
            self?.toggleSSHConfigHost(host)
        }
        remoteView.customTargetField.onChange = { [weak self] in
            self?.controlChanged()
        }
        remoteView.selectAllButton.target = self
        remoteView.selectAllButton.action = #selector(selectAllSSHHostsClicked)
        remoteView.deselectAllButton.target = self
        remoteView.deselectAllButton.action = #selector(deselectAllSSHHostsClicked)
        remoteView.reloadHostsButton.target = self
        remoteView.reloadHostsButton.action = #selector(reloadSSHHostsClicked)

        accountsView.addChatGPTButton.target = self
        accountsView.addChatGPTButton.action = #selector(addChatGPTClicked)
        accountsView.cancelChatGPTLoginButton.target = self
        accountsView.cancelChatGPTLoginButton.action = #selector(cancelChatGPTLoginClicked)
        accountsView.addAPIButton.target = self
        accountsView.addAPIButton.action = #selector(addAPIClicked)
        accountsView.openVaultButton.target = self
        accountsView.openVaultButton.action = #selector(openVaultClicked)
    }

    private func makeAccountsTableController() -> SettingsAccountsTableController {
        let controller = SettingsAccountsTableController(
            scrollView: accountsView.scrollView,
            listView: accountsView.listView
        )
        accountsView.onLayout = { [weak controller] in
            controller?.refreshLayout()
        }
        controller.onActivateAccount = { [weak self] identifier in
            self?.onActivateAccount?(identifier)
        }
        controller.onRenameAccount = { [weak self] identifier in
            self?.onRenameAccount?(identifier)
        }
        controller.onForgetAccount = { [weak self] identifier in
            self?.onForgetAccount?(identifier)
        }
        return controller
    }

    private func applySettingsToControls() {
        isApplyingSettings = true
        defer {
            isApplyingSettings = false
        }

        applyLocalizedText()
        updatePopupTitles(generalView.refreshPopup, values: RefreshIntervalPreset.allCases.map(\.displayName))
        updatePopupTitles(generalView.languagePopup, values: AppLanguage.allCases.map(\.displayName))
        updatePopupTitles(generalView.iconStylePopup, values: StatusItemStyle.allCases.map(\.displayName))
        sshConfigHosts = sshConfigHostLoader()

        selectItem(in: generalView.refreshPopup, matching: settings.refreshIntervalPreset.rawValue)
        selectItem(in: generalView.languagePopup, matching: settings.appLanguage.rawValue)
        selectItem(in: generalView.iconStylePopup, matching: settings.statusItemStyle.rawValue)
        generalView.launchAtLoginCheckbox.state = settings.launchAtLoginEnabled ? .on : .off
        remoteView.remoteSyncSwitch.state = settings.remoteSwitch.enabled ? .on : .off
        applyRemoteTargetsToControls(settings.remoteSwitch.trimmedSSHTargets)
        remoteView.remotePathField.stringValue = settings.remoteSwitch.codexHomePath
    }

    private func applyAccountPanelState() {
        let actionsUnavailableExplanation = accountPanelState.actionsEnabled
            ? nil
            : AppLocalization.localized(
                en: "Finish the current account operation before changing saved accounts.",
                zh: "请先完成当前账号操作，再修改已保存账号。"
            )
        accountsView.importStatusLabel.stringValue = joinedNonEmptyParts(
            [accountPanelState.importStatusText, actionsUnavailableExplanation],
            separator: "\n"
        )
        accountsView.importStatusLabel.isHidden = accountsView.importStatusLabel.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        accountsView.addChatGPTButton.isEnabled = accountPanelState.actionsEnabled
        accountsView.addAPIButton.isEnabled = accountPanelState.actionsEnabled
        accountsView.cancelChatGPTLoginButton.isHidden = !accountPanelState.canCancelChatGPTLogin
        accountsView.cancelChatGPTLoginButton.isEnabled = accountPanelState.canCancelChatGPTLogin
        accountsView.addChatGPTButton.toolTip = actionsUnavailableExplanation
        accountsView.addAPIButton.toolTip = actionsUnavailableExplanation
        accountsView.cancelChatGPTLoginButton.toolTip = accountPanelState.canCancelChatGPTLogin
            ? AppLocalization.localized(en: "Cancel the current ChatGPT login.", zh: "取消当前 ChatGPT 登录。")
            : nil
        accountsView.openVaultButton.isEnabled = true
        accountsTableController.update(state: accountPanelState)
        window?.contentView?.layoutSubtreeIfNeeded()
        accountsTableController.refreshLayout()
    }

    private func applyLocalizedText() {
        window?.title = AppLocalization.localized(en: "Settings", zh: "设置")
        generalView.applyLocalizedText()
        remoteView.applyLocalizedText()
        accountsView.applyLocalizedText()
        advancedView.applyLocalizedText()

        for pane in SettingsPane.allCases {
            sidebarItems[pane]?.title = pane.title
            sidebarItems[pane]?.symbolName = pane.symbolName
        }
    }

    private func configurePopup(_ popup: NSPopUpButton, values: [String]) {
        popup.removeAllItems()
        popup.target = self
        popup.action = #selector(controlChanged)
        for value in values {
            popup.addItem(withTitle: value)
            popup.lastItem?.representedObject = value
        }
    }

    private func updatePopupTitles(_ popup: NSPopUpButton, values: [String]) {
        for (index, value) in values.enumerated() where index < popup.numberOfItems {
            popup.item(at: index)?.title = value
        }
    }

    private func selectItem(in popup: NSPopUpButton, matching rawValue: String) {
        if let item = popup.itemArray.first(where: { ($0.representedObject as? String) == rawValue }) {
            popup.select(item)
        }
    }

    @objc
    private func controlChanged() {
        guard !isApplyingSettings else {
            return
        }

        if let rawValue = generalView.refreshPopup.selectedItem?.representedObject as? String,
           let preset = RefreshIntervalPreset(rawValue: rawValue) {
            settings.refreshIntervalPreset = preset
        }

        if let rawValue = generalView.languagePopup.selectedItem?.representedObject as? String,
           let language = AppLanguage(rawValue: rawValue) {
            settings.appLanguage = language
        }

        if let rawValue = generalView.iconStylePopup.selectedItem?.representedObject as? String,
           let style = StatusItemStyle(rawValue: rawValue) {
            settings.statusItemStyle = style
        }

        settings.launchAtLoginEnabled = generalView.launchAtLoginCheckbox.state == .on
        settings.remoteSwitch.enabled = remoteView.remoteSyncSwitch.state == .on
        settings.remoteSwitch.sshTargets = normalizedRemoteTargets(
            selectedRemoteConfigHosts() + remoteView.customTargetField.targets
        )
        settings.remoteSwitch.codexHomePath = remoteView.remotePathField.stringValue
        onSettingsChanged?(settings)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSSearchField) === remoteView.searchField else {
            return
        }
        renderRemoteHostRows()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) !== remoteView.searchField else {
            return
        }
        controlChanged()
    }

    @objc
    private func sidebarItemClicked(_ sender: SettingsSidebarItemView) {
        guard let pane = SettingsPane(rawValue: sender.tag) else {
            return
        }
        selectPane(pane)
    }

    @objc
    private func selectAllSSHHostsClicked() {
        selectedSSHConfigHosts = Set(sshConfigHosts)
        renderRemoteHostRows()
        controlChanged()
    }

    @objc
    private func deselectAllSSHHostsClicked() {
        selectedSSHConfigHosts.removeAll()
        renderRemoteHostRows()
        controlChanged()
    }

    @objc
    private func reloadSSHHostsClicked() {
        let previouslySelectedHosts = selectedSSHConfigHosts
        let currentCustomTargets = remoteView.customTargetField.targets
        sshConfigHosts = sshConfigHostLoader()
        let availableHosts = Set(sshConfigHosts)
        selectedSSHConfigHosts = previouslySelectedHosts
            .intersection(availableHosts)
            .union(currentCustomTargets.filter { availableHosts.contains($0) })
        remoteView.customTargetField.setTargets(
            currentCustomTargets.filter { !availableHosts.contains($0) }
        )
        renderRemoteHostRows()
        controlChanged()
    }

    @objc
    private func addChatGPTClicked() {
        onAddChatGPTAccount?()
    }

    @objc
    private func cancelChatGPTLoginClicked() {
        onCancelChatGPTLogin?()
    }

    @objc
    private func addAPIClicked() {
        onAddAPIAccount?()
    }

    @objc
    private func openVaultClicked() {
        onOpenVaultFolder?()
    }

    func windowWillClose(_ notification: Notification) {
        onWindowClosed?()
    }

    private func selectPane(_ pane: SettingsPane) {
        selectedPane = pane
        applySelectedPaneVisibility()
    }

    private func applySelectedPaneVisibility() {
        let pane = selectedPane
        generalView.isHidden = pane != .general
        remoteView.isHidden = pane != .remote
        accountsView.isHidden = pane != .accounts
        advancedView.isHidden = pane != .advanced

        for (itemPane, item) in sidebarItems {
            item.isSelectedItem = itemPane == pane
        }
        contentContainer.layoutSubtreeIfNeeded()
        if pane == .accounts {
            applyAccountPanelState()
            accountsTableController.refreshLayout()
        }
    }

    private func toggleSSHConfigHost(_ host: String) {
        if selectedSSHConfigHosts.contains(host) {
            selectedSSHConfigHosts.remove(host)
        } else {
            selectedSSHConfigHosts.insert(host)
        }
        renderRemoteHostRows()
        controlChanged()
    }

    private func applyRemoteTargetsToControls(_ targets: [String]) {
        let availableHosts = Set(sshConfigHosts)
        selectedSSHConfigHosts = Set(targets.filter { availableHosts.contains($0) })
        let customTargets = targets.filter { !availableHosts.contains($0) }
        remoteView.customTargetField.setTargets(customTargets)
        renderRemoteHostRows()
    }

    private func selectedRemoteConfigHosts() -> [String] {
        sshConfigHosts.filter { selectedSSHConfigHosts.contains($0) }
    }

    private func renderRemoteHostRows() {
        let availableHosts = Set(sshConfigHosts)
        selectedSSHConfigHosts = selectedSSHConfigHosts.filter { availableHosts.contains($0) }

        let filteredHosts = filteredSSHConfigHosts()
        let emptyMessage: String?
        if sshConfigHosts.isEmpty {
            emptyMessage = AppLocalization.localized(
                en: "No usable Host entries were found in ~/.ssh/config.",
                zh: "未在 ~/.ssh/config 中找到可用 Host。"
            )
        } else if filteredHosts.isEmpty {
            emptyMessage = AppLocalization.localized(
                en: "No Host matches the current search.",
                zh: "没有匹配当前搜索的 Host。"
            )
        } else {
            emptyMessage = nil
        }

        remoteView.updateSelectedCount(selectedRemoteConfigHosts().count)
        remoteView.updateHosts(
            filteredHosts,
            selectedHosts: selectedSSHConfigHosts,
            emptyMessage: emptyMessage
        )
    }

    private func filteredSSHConfigHosts() -> [String] {
        let query = remoteView.searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return sshConfigHosts
        }
        return sshConfigHosts.filter {
            $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private func normalizedRemoteTargets(_ targets: [String]) -> [String] {
        var seen = Set<String>()
        return targets
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
