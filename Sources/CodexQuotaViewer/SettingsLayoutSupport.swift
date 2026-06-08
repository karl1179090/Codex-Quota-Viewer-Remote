import AppKit
import Foundation

@MainActor
final class SettingsCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.72).cgColor
        shadow = NSShadow()
        shadow?.shadowColor = NSColor.black.withAlphaComponent(0.05)
        shadow?.shadowBlurRadius = 8
        shadow?.shadowOffset = NSSize(width: 0, height: -1)
    }
}

@MainActor
final class SettingsSidebarItemView: NSControl {
    private let indicatorView = NSView()
    private let imageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")

    var title: String {
        get { titleLabel.stringValue }
        set {
            titleLabel.stringValue = newValue
            setAccessibilityLabel(newValue)
        }
    }

    var symbolName: String? {
        didSet {
            guard let symbolName else {
                imageView.image = nil
                return
            }
            let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
            image?.isTemplate = true
            imageView.image = image
        }
    }

    var isSelectedItem = false {
        didSet {
            updateAppearance()
        }
    }

    init(title: String, symbolName: String, tag: Int) {
        super.init(frame: .zero)
        self.tag = tag
        self.title = title
        self.symbolName = symbolName
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendAction(action, to: target)
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ", "\r", "\n":
            sendAction(action, to: target)
        default:
            super.keyDown(with: event)
        }
    }

    private func setupUI() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8

        setAccessibilityRole(.button)
        setAccessibilityLabel(title)

        indicatorView.translatesAutoresizingMaskIntoConstraints = false
        indicatorView.wantsLayer = true
        indicatorView.layer?.cornerRadius = 2
        addSubview(indicatorView)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyDown
        imageView.contentTintColor = .labelColor

        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        let row = NSStackView(views: [imageView, titleLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),
            indicatorView.leadingAnchor.constraint(equalTo: leadingAnchor),
            indicatorView.centerYAnchor.constraint(equalTo: centerYAnchor),
            indicatorView.widthAnchor.constraint(equalToConstant: 4),
            indicatorView.heightAnchor.constraint(equalToConstant: 28),

            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 18),
            imageView.heightAnchor.constraint(equalToConstant: 18),
        ])

        updateAppearance()
    }

    private func updateAppearance() {
        let accent = NSColor.controlAccentColor
        layer?.backgroundColor = isSelectedItem
            ? accent.withAlphaComponent(0.13).cgColor
            : NSColor.clear.cgColor
        indicatorView.layer?.backgroundColor = isSelectedItem
            ? accent.cgColor
            : NSColor.clear.cgColor
        imageView.contentTintColor = isSelectedItem ? accent : .labelColor
        titleLabel.textColor = isSelectedItem ? accent : .labelColor
    }
}

@MainActor
final class SettingsAdvancedView: NSView {
    let syncCurrentRemoteButton = NSButton(title: "", target: nil, action: nil)
    let repairLocalHistoryButton = NSButton(title: "", target: nil, action: nil)
    let repairRemoteHistoryButton = NSButton(title: "", target: nil, action: nil)
    let repairAllHistoryButton = NSButton(title: "", target: nil, action: nil)

    private let titleLabel = NSTextField(labelWithString: "")
    private let syncTitleLabel = NSTextField(labelWithString: "")
    private let syncDetailLabel = NSTextField(labelWithString: "")
    private let repairTitleLabel = NSTextField(labelWithString: "")
    private let repairDetailLabel = NSTextField(labelWithString: "")

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
        titleLabel.stringValue = AppLocalization.localized(en: "Advanced", zh: "高级")
        syncTitleLabel.stringValue = AppLocalization.localized(
            en: "Remote host sync",
            zh: "远程主机同步"
        )
        syncDetailLabel.stringValue = AppLocalization.localized(
            en: "Push the current local auth.json and config.toml to the selected remote hosts.",
            zh: "将当前本机 auth.json 和 config.toml 同步到已选择的远程主机。"
        )
        syncCurrentRemoteButton.title = AppLocalization.localized(
            en: "Sync Current Local Config",
            zh: "同步当前本机配置"
        )
        syncCurrentRemoteButton.setAccessibilityLabel(syncCurrentRemoteButton.title)
        repairTitleLabel.stringValue = AppLocalization.localized(
            en: "History metadata repair",
            zh: "历史模型元数据修复"
        )
        repairDetailLabel.stringValue = AppLocalization.localized(
            en: "Synchronize the current model/provider into Codex history database, rollout files, and session index.",
            zh: "将当前 model/provider 同步到 Codex 历史数据库、rollout 文件和 session index。"
        )
        repairLocalHistoryButton.title = AppLocalization.localized(en: "Repair This Mac", zh: "修复本机")
        repairRemoteHistoryButton.title = AppLocalization.localized(en: "Repair Remote Hosts", zh: "修复远程主机")
        repairAllHistoryButton.title = AppLocalization.localized(en: "Repair All", zh: "全部修复")
        repairLocalHistoryButton.setAccessibilityLabel(repairLocalHistoryButton.title)
        repairRemoteHistoryButton.setAccessibilityLabel(repairRemoteHistoryButton.title)
        repairAllHistoryButton.setAccessibilityLabel(repairAllHistoryButton.title)
    }

    func updateSyncCurrentRemoteAction(
        isEnabled: Bool,
        tooltip: String?
    ) {
        syncCurrentRemoteButton.isEnabled = isEnabled
        syncCurrentRemoteButton.toolTip = tooltip
    }

    func updateHistoryRepairActions(
        localEnabled: Bool,
        remoteEnabled: Bool,
        allEnabled: Bool,
        localTooltip: String?,
        remoteTooltip: String?,
        allTooltip: String?
    ) {
        repairLocalHistoryButton.isEnabled = localEnabled
        repairRemoteHistoryButton.isEnabled = remoteEnabled
        repairAllHistoryButton.isEnabled = allEnabled
        repairLocalHistoryButton.toolTip = localTooltip
        repairRemoteHistoryButton.toolTip = remoteTooltip
        repairAllHistoryButton.toolTip = allTooltip
    }

    private func setupUI() {
        translatesAutoresizingMaskIntoConstraints = false
        identifier = NSUserInterfaceItemIdentifier("settings.advanced.view")
        syncCurrentRemoteButton.identifier = NSUserInterfaceItemIdentifier("settings.advanced.sync-current-remote")
        repairLocalHistoryButton.identifier = NSUserInterfaceItemIdentifier("settings.advanced.repair-history.local")
        repairRemoteHistoryButton.identifier = NSUserInterfaceItemIdentifier("settings.advanced.repair-history.remote")
        repairAllHistoryButton.identifier = NSUserInterfaceItemIdentifier("settings.advanced.repair-history.all")

        titleLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        titleLabel.textColor = .labelColor

        let syncCard = SettingsCardView()
        syncTitleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        syncTitleLabel.textColor = .labelColor

        syncDetailLabel.font = .systemFont(ofSize: 13)
        syncDetailLabel.textColor = .secondaryLabelColor
        syncDetailLabel.maximumNumberOfLines = 0
        syncDetailLabel.lineBreakMode = .byWordWrapping

        syncCurrentRemoteButton.bezelStyle = .rounded
        syncCurrentRemoteButton.controlSize = .regular

        let textStack = NSStackView(views: [syncTitleLabel, syncDetailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [textStack, syncCurrentRemoteButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 18
        row.translatesAutoresizingMaskIntoConstraints = false
        syncCard.addSubview(row)

        let repairCard = SettingsCardView()
        repairTitleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        repairTitleLabel.textColor = .labelColor

        repairDetailLabel.font = .systemFont(ofSize: 13)
        repairDetailLabel.textColor = .secondaryLabelColor
        repairDetailLabel.maximumNumberOfLines = 0
        repairDetailLabel.lineBreakMode = .byWordWrapping

        for button in [repairLocalHistoryButton, repairRemoteHistoryButton, repairAllHistoryButton] {
            button.bezelStyle = .rounded
            button.controlSize = .regular
        }

        let repairTextStack = NSStackView(views: [repairTitleLabel, repairDetailLabel])
        repairTextStack.orientation = .vertical
        repairTextStack.alignment = .leading
        repairTextStack.spacing = 4
        repairTextStack.translatesAutoresizingMaskIntoConstraints = false

        let repairButtonStack = NSStackView(views: [
            repairLocalHistoryButton,
            repairRemoteHistoryButton,
            repairAllHistoryButton,
        ])
        repairButtonStack.orientation = .horizontal
        repairButtonStack.alignment = .centerY
        repairButtonStack.spacing = 8
        repairButtonStack.translatesAutoresizingMaskIntoConstraints = false

        let repairRow = NSStackView(views: [repairTextStack, repairButtonStack])
        repairRow.orientation = .horizontal
        repairRow.alignment = .centerY
        repairRow.spacing = 18
        repairRow.translatesAutoresizingMaskIntoConstraints = false
        repairCard.addSubview(repairRow)

        let stack = NSStackView(views: [titleLabel, syncCard, repairCard])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            syncCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            repairCard.widthAnchor.constraint(equalTo: stack.widthAnchor),

            row.leadingAnchor.constraint(equalTo: syncCard.leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: syncCard.trailingAnchor, constant: -20),
            row.topAnchor.constraint(equalTo: syncCard.topAnchor, constant: 18),
            row.bottomAnchor.constraint(equalTo: syncCard.bottomAnchor, constant: -18),
            textStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            syncCurrentRemoteButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 170),

            repairRow.leadingAnchor.constraint(equalTo: repairCard.leadingAnchor, constant: 20),
            repairRow.trailingAnchor.constraint(equalTo: repairCard.trailingAnchor, constant: -20),
            repairRow.topAnchor.constraint(equalTo: repairCard.topAnchor, constant: 18),
            repairRow.bottomAnchor.constraint(equalTo: repairCard.bottomAnchor, constant: -18),
            repairTextStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            repairLocalHistoryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 84),
            repairRemoteHistoryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 116),
            repairAllHistoryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 84),
        ])
    }
}
