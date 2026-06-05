import AppKit
import Foundation

@MainActor
final class SettingsRemoteView: NSView {
    let remoteSyncSwitch = NSSwitch()
    let searchField = NSSearchField()
    let selectAllButton = NSButton(title: "", target: nil, action: nil)
    let deselectAllButton = NSButton(title: "", target: nil, action: nil)
    let reloadHostsButton = NSButton(title: "", target: nil, action: nil)
    let customTargetField = RemoteTargetChipField()
    let remotePathField = NSTextField(string: "")

    let titleLabel = NSTextField(labelWithString: "")
    let subtitleLabel = NSTextField(labelWithString: "")
    private let syncLabel = NSTextField(labelWithString: "")
    private let hostSectionTitleLabel = NSTextField(labelWithString: "")
    private let selectedCountLabel = NSTextField(labelWithString: "")
    private let hostsStack = NSStackView()
    private let emptyHostsLabel = NSTextField(labelWithString: "")
    private let customTargetTitleLabel = NSTextField(labelWithString: "")
    private let remotePathTitleLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")

    var onHostToggled: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyLocalizedText() {
        titleLabel.stringValue = AppLocalization.localized(en: "Remote", zh: "远程")
        subtitleLabel.stringValue = AppLocalization.localized(
            en: "Manage remote host connections and sync options.",
            zh: "管理远程主机连接与同步选项。"
        )
        syncLabel.stringValue = AppLocalization.localized(
            en: "Sync selected remote hosts when switching accounts",
            zh: "切换账号时同步选中的远程主机"
        )
        hostSectionTitleLabel.stringValue = AppLocalization.localized(
            en: "Select hosts from SSH config",
            zh: "从 SSH 配置中选择主机"
        )
        searchField.placeholderString = AppLocalization.localized(en: "Search Host...", zh: "搜索 Host...")
        selectAllButton.title = AppLocalization.localized(en: "Select All", zh: "全选")
        deselectAllButton.title = AppLocalization.localized(en: "Deselect All", zh: "取消全选")
        reloadHostsButton.title = AppLocalization.localized(en: "Reload ~/.ssh/config", zh: "重新读取 ~/.ssh/config")
        customTargetTitleLabel.stringValue = AppLocalization.localized(en: "Custom targets", zh: "自定义目标")
        customTargetField.placeholderString = AppLocalization.localized(en: "Enter target...", zh: "输入目标...")
        remotePathTitleLabel.stringValue = AppLocalization.localized(en: "Remote Codex home", zh: "远程 Codex 目录")
        remotePathField.placeholderString = RemoteSwitchSettings.defaultCodexHomePath
        hintLabel.stringValue = AppLocalization.localized(
            en: "Reads Host entries from ~/.ssh/config and uses system ssh to connect to remote machines. Remote Codex processes can be terminated from the switch confirmation.",
            zh: "读取 ~/.ssh/config 里的 Host，并使用系统 ssh 连接远程机器。可在切换确认框中选择是否终止远端 Codex 进程。"
        )
        remoteSyncSwitch.setAccessibilityLabel(syncLabel.stringValue)
        searchField.setAccessibilityLabel(searchField.placeholderString)
        updateSelectedCount(0)
    }

    func updateSelectedCount(_ count: Int) {
        selectedCountLabel.stringValue = AppLocalization.localized(
            en: "Selected \(count)",
            zh: "已选择 \(count) 个"
        )
    }

    func updateHosts(
        _ hosts: [String],
        selectedHosts: Set<String>,
        emptyMessage: String?
    ) {
        hostsStack.arrangedSubviews.forEach { view in
            hostsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if hosts.isEmpty {
            emptyHostsLabel.stringValue = emptyMessage ?? AppLocalization.localized(
                en: "No available Host entries found.",
                zh: "未找到可用 Host。"
            )
            emptyHostsLabel.isHidden = false
            hostsStack.addArrangedSubview(emptyHostsLabel)
            return
        }

        emptyHostsLabel.isHidden = true
        for host in hosts {
            let row = RemoteHostRowView(host: host)
            row.isChecked = selectedHosts.contains(host)
            row.onToggle = { [weak self] toggledHost in
                self?.onHostToggled?(toggledHost)
            }
            hostsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: hostsStack.widthAnchor).isActive = true
        }
    }

    private func setupUI() {
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.identifier = NSUserInterfaceItemIdentifier("settings.remote.title")
        remoteSyncSwitch.identifier = NSUserInterfaceItemIdentifier("settings.remote.sync")
        searchField.identifier = NSUserInterfaceItemIdentifier("settings.remote.search")
        selectedCountLabel.identifier = NSUserInterfaceItemIdentifier("settings.remote.selected-count")
        customTargetField.identifier = NSUserInterfaceItemIdentifier("settings.remote.target-field")
        remotePathField.identifier = NSUserInterfaceItemIdentifier("settings.remote.path-field")
        selectAllButton.identifier = NSUserInterfaceItemIdentifier("settings.remote.select-all")
        deselectAllButton.identifier = NSUserInterfaceItemIdentifier("settings.remote.deselect-all")
        reloadHostsButton.identifier = NSUserInterfaceItemIdentifier("settings.remote.reload-hosts")

        titleLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        titleLabel.textColor = .labelColor
        subtitleLabel.font = .systemFont(ofSize: 14)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 0
        subtitleLabel.lineBreakMode = .byWordWrapping

        let syncCard = SettingsCardView()
        let syncRow = NSStackView()
        syncRow.orientation = .horizontal
        syncRow.alignment = .centerY
        syncRow.spacing = 12
        syncRow.translatesAutoresizingMaskIntoConstraints = false
        syncCard.addSubview(syncRow)

        syncLabel.font = .systemFont(ofSize: 14, weight: .medium)
        syncLabel.textColor = .labelColor
        syncLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let syncSpacer = NSView()
        syncSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        syncSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        syncRow.addArrangedSubview(syncLabel)
        syncRow.addArrangedSubview(syncSpacer)
        syncRow.addArrangedSubview(remoteSyncSwitch)

        let hostCard = makeHostCard()
        let customCard = makeTitledCard(titleLabel: customTargetTitleLabel, content: customTargetField)
        let pathCard = makeTitledCard(titleLabel: remotePathTitleLabel, content: remotePathField)

        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.maximumNumberOfLines = 0
        hintLabel.lineBreakMode = .byWordWrapping

        let pageStack = NSStackView(views: [
            titleLabel,
            subtitleLabel,
            syncCard,
            hostCard,
            customCard,
            pathCard,
            hintLabel,
        ])
        pageStack.orientation = .vertical
        pageStack.alignment = .leading
        pageStack.spacing = 12
        pageStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pageStack)

        NSLayoutConstraint.activate([
            pageStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            pageStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            pageStack.topAnchor.constraint(equalTo: topAnchor),
            pageStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),

            subtitleLabel.widthAnchor.constraint(equalTo: pageStack.widthAnchor),
            syncCard.widthAnchor.constraint(equalTo: pageStack.widthAnchor),
            hostCard.widthAnchor.constraint(equalTo: pageStack.widthAnchor),
            customCard.widthAnchor.constraint(equalTo: pageStack.widthAnchor),
            pathCard.widthAnchor.constraint(equalTo: pageStack.widthAnchor),
            hintLabel.widthAnchor.constraint(equalTo: pageStack.widthAnchor),

            syncRow.leadingAnchor.constraint(equalTo: syncCard.leadingAnchor, constant: 20),
            syncRow.trailingAnchor.constraint(equalTo: syncCard.trailingAnchor, constant: -20),
            syncRow.topAnchor.constraint(equalTo: syncCard.topAnchor, constant: 14),
            syncRow.bottomAnchor.constraint(equalTo: syncCard.bottomAnchor, constant: -14),
        ])
    }

    private func makeHostCard() -> NSView {
        let card = SettingsCardView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        hostSectionTitleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        hostSectionTitleLabel.textColor = .labelColor

        selectedCountLabel.font = .systemFont(ofSize: 13)
        selectedCountLabel.textColor = .secondaryLabelColor

        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        let titleSpacer = NSView()
        titleSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleRow.addArrangedSubview(hostSectionTitleLabel)
        titleRow.addArrangedSubview(titleSpacer)
        titleRow.addArrangedSubview(selectedCountLabel)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.controlSize = .regular

        hostsStack.orientation = .vertical
        hostsStack.alignment = .leading
        hostsStack.spacing = 0
        hostsStack.translatesAutoresizingMaskIntoConstraints = false

        emptyHostsLabel.font = .systemFont(ofSize: 13)
        emptyHostsLabel.textColor = .secondaryLabelColor
        emptyHostsLabel.alignment = .center
        emptyHostsLabel.maximumNumberOfLines = 0
        emptyHostsLabel.lineBreakMode = .byWordWrapping
        emptyHostsLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 92).isActive = true

        let listContainer = NSView()
        listContainer.translatesAutoresizingMaskIntoConstraints = false
        listContainer.wantsLayer = true
        listContainer.layer?.cornerRadius = 8
        listContainer.layer?.masksToBounds = true
        listContainer.layer?.borderWidth = 1
        listContainer.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        listContainer.layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.85).cgColor

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        listContainer.addSubview(scrollView)

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        documentView.addSubview(hostsStack)

        let buttonsRow = NSStackView(views: [selectAllButton, deselectAllButton, reloadHostsButton])
        buttonsRow.orientation = .horizontal
        buttonsRow.alignment = .centerY
        buttonsRow.spacing = 8
        buttonsRow.translatesAutoresizingMaskIntoConstraints = false

        [selectAllButton, deselectAllButton, reloadHostsButton].forEach {
            $0.controlSize = .small
            $0.bezelStyle = .rounded
        }

        stack.addArrangedSubview(titleRow)
        stack.addArrangedSubview(searchField)
        stack.addArrangedSubview(listContainer)
        stack.addArrangedSubview(buttonsRow)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),

            titleRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            searchField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            listContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            listContainer.heightAnchor.constraint(equalToConstant: 176),

            scrollView.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: listContainer.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),

            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),

            hostsStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            hostsStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            hostsStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            hostsStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])

        return card
    }

    private func makeTitledCard(titleLabel: NSTextField, content: NSView) -> NSView {
        let card = SettingsCardView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .labelColor

        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(content)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            content.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        return card
    }
}

@MainActor
final class RemoteHostRowView: NSControl {
    let host: String
    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let titleLabel = NSTextField(labelWithString: "")
    private let chevronLabel = NSTextField(labelWithString: "›")

    var onToggle: ((String) -> Void)?

    var isChecked = false {
        didSet {
            checkbox.state = isChecked ? .on : .off
            updateAppearance()
        }
    }

    init(host: String) {
        self.host = host
        super.init(frame: .zero)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    func performToggle() {
        onToggle?(host)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        performToggle()
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ", "\r", "\n":
            performToggle()
        default:
            super.keyDown(with: event)
        }
    }

    private func setupUI() {
        identifier = NSUserInterfaceItemIdentifier("settings.remote.host-row.\(host)")
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 7

        setAccessibilityLabel(host)
        setAccessibilityRole(.button)

        checkbox.identifier = NSUserInterfaceItemIdentifier("settings.remote.host-checkbox.\(host)")
        checkbox.target = self
        checkbox.action = #selector(checkboxClicked)
        checkbox.setAccessibilityLabel(host)

        titleLabel.stringValue = host
        titleLabel.font = .systemFont(ofSize: 14)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        chevronLabel.font = .systemFont(ofSize: 24, weight: .regular)
        chevronLabel.textColor = .tertiaryLabelColor
        chevronLabel.alignment = .center
        chevronLabel.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [checkbox, titleLabel, chevronLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        updateAppearance()
    }

    @objc
    private func checkboxClicked() {
        performToggle()
    }

    private func updateAppearance() {
        layer?.backgroundColor = isChecked
            ? NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
            : NSColor.clear.cgColor
        titleLabel.textColor = isChecked ? .controlAccentColor : .labelColor
    }
}

@MainActor
final class RemoteTargetChipField: NSView, NSTextFieldDelegate {
    private let container = NSView()
    private let stack = NSStackView()
    let inputField = NSTextField(string: "")

    var onChange: (() -> Void)?

    var placeholderString: String? {
        didSet {
            inputField.placeholderString = placeholderString
            inputField.setAccessibilityLabel(placeholderString)
        }
    }

    private(set) var targets: [String] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setTargets(_ nextTargets: [String], notify: Bool = false) {
        targets = normalizedTargets(nextTargets)
        rebuildChips()
        if notify {
            onChange?()
        }
    }

    func addTargets(from text: String, notify: Bool = true) {
        let nextTargets = targets + splitTargets(text)
        setTargets(nextTargets, notify: notify)
    }

    func controlTextDidChange(_ obj: Notification) {
        let text = inputField.stringValue
        guard text.rangeOfCharacter(from: separatorCharacters) != nil else {
            return
        }
        addTargets(from: text)
        inputField.stringValue = ""
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitInput()
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitInput()
            return true
        }
        return false
    }

    private func setupUI() {
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true

        identifier = NSUserInterfaceItemIdentifier("settings.remote.target-chip-field")

        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        container.layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.9).cgColor
        addSubview(container)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        inputField.identifier = NSUserInterfaceItemIdentifier("settings.remote.target-field.input")
        inputField.isBordered = false
        inputField.drawsBackground = false
        inputField.focusRingType = .none
        inputField.delegate = self
        inputField.font = .systemFont(ofSize: 13)
        inputField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        inputField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stack.addArrangedSubview(inputField)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -5),

            inputField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
    }

    private func commitInput() {
        let text = inputField.stringValue
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        addTargets(from: text)
        inputField.stringValue = ""
    }

    private func rebuildChips() {
        stack.arrangedSubviews
            .filter { $0 !== inputField }
            .forEach { view in
                stack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }

        for target in targets {
            let chip = makeChip(title: target)
            stack.insertArrangedSubview(chip, at: max(0, stack.arrangedSubviews.count - 1))
        }
    }

    private func makeChip(title: String) -> NSButton {
        let button = RemoteTargetChipButton(targetValue: title, target: self, action: #selector(removeChip(_:)))
        button.identifier = NSUserInterfaceItemIdentifier("settings.remote.target-chip.\(title)")
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.font = .systemFont(ofSize: 12)
        button.contentTintColor = .labelColor
        button.wantsLayer = true
        button.layer?.cornerRadius = 11
        button.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.16).cgColor
        button.setButtonType(.momentaryPushIn)
        button.setAccessibilityLabel(AppLocalization.localized(en: "Remove \(title)", zh: "移除 \(title)"))
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    @objc
    private func removeChip(_ sender: NSButton) {
        guard let target = (sender as? RemoteTargetChipButton)?.targetValue else {
            return
        }
        targets.removeAll { $0 == target }
        rebuildChips()
        onChange?()
    }

    private var separatorCharacters: CharacterSet {
        CharacterSet(charactersIn: ",;\n\t ").union(.newlines)
    }

    private func splitTargets(_ text: String) -> [String] {
        text.components(separatedBy: separatorCharacters)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func normalizedTargets(_ nextTargets: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []
        for target in nextTargets {
            let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else {
                continue
            }
            normalized.append(trimmed)
        }
        return normalized
    }
}

@MainActor
private final class RemoteTargetChipButton: NSButton {
    let targetValue: String

    init(targetValue: String, target: AnyObject?, action: Selector?) {
        self.targetValue = targetValue
        super.init(frame: .zero)
        title = "\(targetValue) ×"
        self.target = target
        self.action = action
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
