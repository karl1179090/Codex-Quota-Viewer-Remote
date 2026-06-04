import AppKit
import Foundation

@MainActor
final class SettingsGeneralView: NSView {
    let refreshPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let iconStylePopup = NSPopUpButton(frame: .zero, pullsDown: false)

    let titleLabel = NSTextField(labelWithString: "")
    let subtitleLabel = NSTextField(labelWithString: "")
    let sectionTitleLabel = NSTextField(labelWithString: "")
    let refreshRowLabel = NSTextField(labelWithString: "")
    let languageRowLabel = NSTextField(labelWithString: "")
    let iconStyleRowLabel = NSTextField(labelWithString: "")

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
        titleLabel.stringValue = AppLocalization.localized(en: "General", zh: "通用")
        subtitleLabel.stringValue = AppLocalization.localized(
            en: "Configure app preferences and menu bar behavior.",
            zh: "配置应用偏好与菜单栏显示方式。"
        )
        sectionTitleLabel.stringValue = AppLocalization.localized(en: "General", zh: "通用")
        refreshRowLabel.stringValue = AppLocalization.localized(en: "Refresh interval", zh: "刷新频率")
        languageRowLabel.stringValue = AppLocalization.localized(en: "Language", zh: "语言")
        iconStyleRowLabel.stringValue = AppLocalization.localized(en: "Menu bar style", zh: "状态栏样式")
        launchAtLoginCheckbox.title = AppLocalization.localized(en: "Launch at login", zh: "登录时启动")
    }

    private func setupUI() {
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.identifier = NSUserInterfaceItemIdentifier("settings.general.title")
        sectionTitleLabel.identifier = NSUserInterfaceItemIdentifier("settings.general.section")
        refreshRowLabel.identifier = NSUserInterfaceItemIdentifier("settings.general.refresh")
        languageRowLabel.identifier = NSUserInterfaceItemIdentifier("settings.general.language")
        iconStyleRowLabel.identifier = NSUserInterfaceItemIdentifier("settings.general.icon-style")
        launchAtLoginCheckbox.identifier = NSUserInterfaceItemIdentifier("settings.general.launch-at-login")

        titleLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.setContentHuggingPriority(.required, for: .vertical)

        subtitleLabel.font = .systemFont(ofSize: 14)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 0
        subtitleLabel.lineBreakMode = .byWordWrapping

        sectionTitleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        sectionTitleLabel.textColor = .labelColor

        let card = SettingsCardView()
        let cardStack = NSStackView()
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 12
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cardStack)

        cardStack.addArrangedSubview(sectionTitleLabel)
        cardStack.addArrangedSubview(makeRow(label: refreshRowLabel, control: refreshPopup))
        cardStack.addArrangedSubview(makeRow(label: languageRowLabel, control: languagePopup))
        cardStack.addArrangedSubview(makeRow(label: iconStyleRowLabel, control: iconStylePopup))
        cardStack.addArrangedSubview(launchAtLoginCheckbox)

        let pageStack = NSStackView(views: [titleLabel, subtitleLabel, card])
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
            card.widthAnchor.constraint(equalTo: pageStack.widthAnchor),

            cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            cardStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
        ])
    }

    private func makeRow(label: NSTextField, control: NSView) -> NSView {
        label.alignment = .left
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.widthAnchor.constraint(equalToConstant: 132).isActive = true
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 16
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }
}
