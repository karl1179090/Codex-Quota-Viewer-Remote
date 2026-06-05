import AppKit
import Foundation

private enum SettingsAccountsListRow: Equatable {
    case section(SettingsAccountSection)
    case account(SettingsAccountItem)
}

@MainActor
final class SettingsAccountsTableController: NSObject {
    var onActivateAccount: ((String) -> Void)?
    var onRenameAccount: ((String) -> Void)?
    var onForgetAccount: ((String) -> Void)?

    private let scrollView: NSScrollView
    private let listView: SettingsAccountsListView
    private var rows: [SettingsAccountsListRow] = []
    private var rowViews: [(row: SettingsAccountsListRow, view: NSView)] = []
    private var actionsEnabled = true
    private var didInstallLayoutObservers = false

    init(scrollView: NSScrollView, listView: SettingsAccountsListView) {
        self.scrollView = scrollView
        self.listView = listView
        super.init()
        configureListView()
        installLayoutObserversIfPossible()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func update(state: SettingsAccountPanelState) {
        actionsEnabled = state.actionsEnabled
        rows = state.sections.flatMap { section in
            [SettingsAccountsListRow.section(section)] + section.items.map(SettingsAccountsListRow.account)
        }

        renderRows()
        refreshLayout()
    }

    func refreshLayout() {
        installLayoutObserversIfPossible()
        scrollView.layoutSubtreeIfNeeded()

        let clipSize = scrollView.contentView.bounds.size
        let width = preferredLayoutDimension(
            visibleDimension: clipSize.width,
            scrollDimension: scrollView.bounds.width,
            currentDimension: listView.bounds.width
        )
        guard width > 1 || clipSize.height > 1 else {
            return
        }

        let totalRowHeight = rows.reduce(CGFloat(0)) { total, row in
            total + rowHeight(for: row)
        }
        let spacingHeight = max(0, CGFloat(rows.count - 1)) * Self.rowSpacing
        let contentHeight = totalRowHeight + spacingHeight
        let height = max(clipSize.height, contentHeight, 1)
        let nextSize = NSSize(width: max(width, 1), height: height)

        let nextFrame = NSRect(origin: .zero, size: nextSize)
        if abs(listView.frame.width - nextSize.width) > 0.5
            || abs(listView.frame.height - nextSize.height) > 0.5
            || listView.frame.origin != .zero {
            listView.frame = nextFrame
        }
        layoutRows(width: nextSize.width)
        listView.needsDisplay = true
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private static let rowSpacing: CGFloat = 4

    private func configureListView() {
        listView.identifier = NSUserInterfaceItemIdentifier("settings.accounts.list")
        listView.wantsLayer = true
        listView.translatesAutoresizingMaskIntoConstraints = true
    }

    private func renderRows() {
        rowViews.removeAll()
        for view in listView.subviews {
            view.removeFromSuperview()
        }

        for row in rows {
            let view: NSView
            switch row {
            case .section(let section):
                view = configuredSectionView(section.title)
            case .account(let item):
                view = configuredAccountView(item)
            }
            view.translatesAutoresizingMaskIntoConstraints = true
            view.autoresizingMask = [.width]
            listView.addSubview(view)
            rowViews.append((row, view))
        }
    }

    private func layoutRows(width: CGFloat) {
        var y: CGFloat = 0
        for (index, rowView) in rowViews.enumerated() {
            let height = rowHeight(for: rowView.row)
            rowView.view.frame = NSRect(x: 0, y: y, width: width, height: height)
            rowView.view.needsLayout = true
            rowView.view.layoutSubtreeIfNeeded()
            y += height
            if index < rowViews.count - 1 {
                y += Self.rowSpacing
            }
        }
    }

    private func preferredLayoutDimension(
        visibleDimension: CGFloat,
        scrollDimension: CGFloat,
        currentDimension: CGFloat
    ) -> CGFloat {
        if visibleDimension > 1 {
            return visibleDimension
        }
        if scrollDimension > 1 {
            return scrollDimension
        }
        return max(currentDimension, 1)
    }

    private func rowHeight(for row: SettingsAccountsListRow) -> CGFloat {
        switch row {
        case .section:
            return 26
        case .account:
            return 58
        }
    }

    private func installLayoutObserversIfPossible() {
        guard !didInstallLayoutObservers else {
            return
        }

        scrollView.postsFrameChangedNotifications = true
        scrollView.contentView.postsBoundsChangedNotifications = true

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(observedLayoutDidChange),
            name: NSView.frameDidChangeNotification,
            object: scrollView
        )
        center.addObserver(
            self,
            selector: #selector(observedLayoutDidChange),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        didInstallLayoutObservers = true
    }

    @objc
    private func observedLayoutDidChange() {
        refreshLayout()
    }

    private func configuredSectionView(_ title: String) -> NSView {
        let view = SettingsAccountsSectionRowView()
        view.identifier = NSUserInterfaceItemIdentifier("settings.accounts.section.row")
        view.apply(title: title)
        return view
    }

    private func configuredAccountView(_ item: SettingsAccountItem) -> NSView {
        let view = SettingsAccountsRowView()
        view.identifier = NSUserInterfaceItemIdentifier("settings.accounts.account.row")
        view.apply(
            item: item,
            actionsEnabled: actionsEnabled,
            onActivate: { [weak self] id in self?.onActivateAccount?(id) },
            onRename: { [weak self] id in self?.onRenameAccount?(id) },
            onForget: { [weak self] id in self?.onForgetAccount?(id) }
        )
        return view
    }
}

private final class SettingsAccountsSectionRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(title: String) {
        titleLabel.stringValue = title
    }

    private func setupUI() {
        wantsLayer = true
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}

private final class SettingsAccountsRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let activateButton = NSButton(
        title: AppLocalization.localized(en: "Activate", zh: "切换"),
        target: nil,
        action: nil
    )
    private let renameButton = NSButton(
        title: AppLocalization.localized(en: "Rename…", zh: "重命名…"),
        target: nil,
        action: nil
    )
    private let forgetButton = NSButton(
        title: AppLocalization.localized(en: "Forget…", zh: "移除…"),
        target: nil,
        action: nil
    )
    private let textStack = NSStackView()
    private let buttonStack = NSStackView()

    private var accountID: String?
    private var onActivate: ((String) -> Void)?
    private var onRename: ((String) -> Void)?
    private var onForget: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(
        item: SettingsAccountItem,
        actionsEnabled: Bool,
        onActivate: @escaping (String) -> Void,
        onRename: @escaping (String) -> Void,
        onForget: @escaping (String) -> Void
    ) {
        accountID = item.id
        self.onActivate = onActivate
        self.onRename = onRename
        self.onForget = onForget

        titleLabel.stringValue = item.title
        subtitleLabel.stringValue = item.subtitle
        activateButton.title = AppLocalization.localized(en: "Activate", zh: "切换")
        renameButton.title = AppLocalization.localized(en: "Rename…", zh: "重命名…")
        forgetButton.title = AppLocalization.localized(en: "Forget…", zh: "移除…")

        activateButton.isHidden = !item.canActivate
        renameButton.isHidden = !item.canRename
        forgetButton.isHidden = !item.canForget

        activateButton.isEnabled = actionsEnabled && item.canActivate
        renameButton.isEnabled = actionsEnabled && item.canRename
        forgetButton.isEnabled = actionsEnabled && item.canForget
        updateAppearance(isCurrent: item.isCurrent)
    }

    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = 9

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = .systemFont(ofSize: 10)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 1
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        activateButton.target = self
        activateButton.action = #selector(handleActivate)
        renameButton.target = self
        renameButton.action = #selector(handleRename)
        forgetButton.target = self
        forgetButton.action = #selector(handleForget)
        [activateButton, renameButton, forgetButton].forEach {
            $0.bezelStyle = .rounded
            $0.controlSize = .small
            $0.font = .systemFont(ofSize: 11)
            $0.setButtonType(.momentaryPushIn)
        }

        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(subtitleLabel)

        buttonStack.setViews([activateButton, renameButton, forgetButton], in: .leading)
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 6
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        buttonStack.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(textStack)
        addSubview(buttonStack)

        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: buttonStack.leadingAnchor, constant: -12),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
            buttonStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            buttonStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            buttonStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
        ])
    }

    private func updateAppearance(isCurrent: Bool) {
        let backgroundColor = isCurrent
            ? NSColor.separatorColor.withAlphaComponent(0.14)
            : NSColor.clear
        layer?.backgroundColor = backgroundColor.cgColor
        layer?.borderWidth = 0
        layer?.borderColor = nil
    }

    @objc
    private func handleActivate() {
        guard let accountID else { return }
        onActivate?(accountID)
    }

    @objc
    private func handleRename() {
        guard let accountID else { return }
        onRename?(accountID)
    }

    @objc
    private func handleForget() {
        guard let accountID else { return }
        onForget?(accountID)
    }
}
