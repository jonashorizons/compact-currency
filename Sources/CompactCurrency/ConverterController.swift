import AppKit
import CurrencyCore

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

final class CurrencyRow: NSView {
    let code: String
    let amount = AmountField()
    var isSelected = false { didSet { needsDisplay = true } }
    var onSelect: (() -> Void)?
    override var isFlipped: Bool { true }

    init(currency: CurrencyInfo, flags: Bool) {
        code = currency.isoCode
        super.init(frame: NSRect(x: 0, y: 0, width: 294, height: 40))
        let flag = NSTextField(labelWithString: flags ? currency.flag : "")
        flag.font = .systemFont(ofSize: 20)
        flag.frame = NSRect(x: 10, y: 7, width: 28, height: 27)
        addSubview(flag)
        let name = NSTextField(labelWithString: code)
        name.font = .systemFont(ofSize: 13)
        name.frame = NSRect(x: flags ? 44 : 14, y: 11, width: 47, height: 19)
        addSubview(name)
        amount.frame = NSRect(x: 92, y: 8, width: 190, height: 25)
        amount.font = .monospacedDigitSystemFont(ofSize: 16, weight: .regular)
        amount.alignment = .right; amount.isBordered = false; amount.drawsBackground = false
        amount.focusRingType = .none; amount.isEditable = true; amount.isSelectable = true
        amount.usesSingleLineMode = true
        amount.cell?.isScrollable = true
        amount.identifier = NSUserInterfaceItemIdentifier(code)
        amount.setAccessibilityIdentifier("amount.\(code)")
        amount.setAccessibilityLabel("Amount in \(code)")
        amount.toolTip = currency.name
        addSubview(amount)
        setAccessibilityLabel("\(code), \(currency.name)")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isSelected {
            NSColor.controlAccentColor.withAlphaComponent(effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.20 : 0.085).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 8, yRadius: 8).fill()
        }
    }

    override func mouseDown(with event: NSEvent) { onSelect?() }
}

final class AmountField: NSTextField {
    var previousEditingText: String?
    override func mouseDown(with event: NSEvent) {
        let alreadyEditing = currentEditor() != nil
        super.mouseDown(with: event)
        if !alreadyEditing { selectText(nil) }
    }
}

@MainActor
final class ConverterController: NSViewController, NSSearchFieldDelegate {
    enum Mode { case main, manage, settings }
    let model: AppModel
    var onClose: (() -> Void)?
    var onResize: ((NSSize) -> Void)?
    private(set) var rows: [String: CurrencyRow] = [:]
    private(set) var mode: Mode = .main
    private var titleField: NSTextField!
    private var sourceField: NSTextField!
    private var refreshButton: NSButton!
    private var settingsMessage: NSTextField?
    private var scrollView: NSScrollView?
    private var manageList: FlippedView?
    private var searchField: NSSearchField?
    private var visibleCodes: [String] = []
    private var isTyping = false
    private var invalidInput = false
    private var presentationScreen: NSScreen?
    var hotKeyAvailable = true

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        model.onChange = { [weak self] change in self?.modelChanged(change) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        view = FlippedView(frame: NSRect(x: 0, y: 0, width: 310, height: 440))
        renderMain()
    }

    func opened() {
        if mode != .main { renderMain() }
        focusSelected()
        model.refreshIfNeeded()
    }

    func prepareToOpen(on screen: NSScreen?) {
        presentationScreen = screen
        renderMain()
    }

    func closed() {
        isTyping = false; invalidInput = false; model.flush()
    }

    private func reset(width: CGFloat, height: CGFloat, title: String, back: Bool) {
        view.window?.makeFirstResponder(nil)
        view.subviews.forEach { $0.removeFromSuperview() }
        rows = [:]; sourceField = nil; refreshButton = nil; settingsMessage = nil
        scrollView = nil; manageList = nil; searchField = nil
        view.frame.size = NSSize(width: width, height: height)
        preferredContentSize = view.frame.size
        if back {
            let button = iconButton("chevron.left", label: "Back to converter", action: #selector(backToMain))
            button.frame = NSRect(x: 9, y: 10, width: 28, height: 28); view.addSubview(button)
        }
        titleField = label(title, size: 14, weight: .medium)
        titleField.frame = NSRect(x: back ? 42 : 18, y: 16, width: width - 125, height: 22)
        view.addSubview(titleField)
        onResize?(view.frame.size)
    }

    func renderMain() {
        mode = .main; isTyping = false; invalidInput = false
        let screen = presentationScreen ?? view.window?.screen ?? NSScreen.main ?? NSScreen.screens.first
        // Reserve the popover arrow/chrome, and cap only at the actual screen.
        // Keep whole rows visible when a list is too tall to fit in one view.
        let availableHeight = (screen?.visibleFrame.height ?? 800) - 24
        let maximumListHeight = max(40, floor((availableHeight - 56) / 40) * 40)
        let listHeight = min(CGFloat(model.currencies.count) * 40, maximumListHeight)
        reset(width: 310, height: 48 + listHeight + 8, title: "Currency", back: false)
        let manage = iconButton("plus", label: "Add or manage currencies", action: #selector(showManage))
        manage.frame = NSRect(x: 234, y: 10, width: 29, height: 29); view.addSubview(manage)
        let settings = iconButton("slider.horizontal.3", label: "Converter settings", action: #selector(showSettings))
        settings.frame = NSRect(x: 270, y: 10, width: 29, height: 29); view.addSubview(settings)
        let scroll = NSScrollView(frame: NSRect(x: 8, y: 48, width: 294, height: listHeight))
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false; scroll.hasHorizontalScroller = false
        scroll.verticalScrollElasticity = .none; scroll.horizontalScrollElasticity = .none
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 294, height: CGFloat(model.currencies.count) * 40))
        for (index, code) in model.currencies.enumerated() {
            let row = CurrencyRow(currency: model.currency(code), flags: model.settings.showFlags)
            row.frame.origin.y = CGFloat(index) * 40
            row.amount.delegate = self
            row.onSelect = { [weak self] in self?.model.select(code) }
            rows[code] = row; document.addSubview(row)
        }
        scroll.documentView = document; view.addSubview(scroll); scrollView = scroll
        let orderedFields = model.currencies.compactMap { rows[$0]?.amount }
        for (index, field) in orderedFields.enumerated() { field.nextKeyView = orderedFields[(index + 1) % orderedFields.count] }
        updateValues(); updateSelection(); updateStatus()
    }

    private func modelChanged(_ change: AppModel.Change) {
        guard isViewLoaded else { return }
        switch change {
        case .structure:
            if mode == .main { renderMain(); focusSelected() }
            else if mode == .manage { renderManageRows() }
        case .selection:
            if mode == .main { isTyping = false; invalidInput = false; updateValues(); updateSelection(); focusSelected() }
        case .values:
            if mode == .main { updateValues(); updateSelection() }
        case .status: break
        }
        updateStatus()
    }

    private func updateValues() {
        for (code, row) in rows {
            if !(isTyping && row.amount.currentEditor() != nil) {
                let editor = row.amount.currentEditor() as? NSTextView
                let selectedAll = editor.map { $0.selectedRange().length == ($0.string as NSString).length } ?? false
                row.amount.stringValue = model.formatted(code)
                if selectedAll { row.amount.selectText(nil) }
            }
            let targetDate = model.snapshot.quotes[code]?.date ?? "Unknown"
            row.amount.toolTip = "\(model.currency(code).name)\nReference quote: \(targetDate)\nSource: Frankfurter"
        }
    }

    private func updateSelection() {
        for (code, row) in rows {
            row.isSelected = code == model.selectedCode
            row.amount.textColor = .labelColor
            if let editor = row.amount.currentEditor() as? NSTextView { styleEditor(editor) }
        }
    }

    func focusSelected() {
        guard mode == .main, let row = rows[model.selectedCode], let window = view.window else { return }
        row.scrollToVisible(row.bounds)
        window.makeFirstResponder(row.amount)
        row.amount.selectText(nil)
        if let editor = row.amount.currentEditor() as? NSTextView { styleEditor(editor) }
    }

    private func updateStatus() {
        sourceField?.stringValue = invalidInput ? "Enter a number up to 100 billion" : model.footerText
        sourceField?.textColor = invalidInput ? .systemRed : .secondaryLabelColor
        sourceField?.toolTip = model.details
        refreshButton?.isEnabled = !model.isLoading
        if mode == .settings {
            if let storageError = model.storageError { settingsMessage?.stringValue = storageError }
        }
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let field = notification.object as? AmountField, let code = field.identifier?.rawValue else { return }
        field.previousEditingText = field.stringValue
        if model.selectedCode != code { model.select(code) }
        if let editor = field.currentEditor() as? NSTextView { styleEditor(editor) }
    }

    func controlTextDidChange(_ notification: Notification) {
        if let searchField, notification.object as? NSSearchField === searchField { renderManageRows(); return }
        guard let field = notification.object as? AmountField, let code = field.identifier?.rawValue else { return }
        isTyping = true
        let editor = field.currentEditor() as? NSTextView
        let range = editor?.selectedRange() ?? NSRange(location: field.stringValue.utf16.count, length: 0)
        if let edit = AmountEditingFormatter.format(field.stringValue, selection: range, previousText: field.previousEditingText) {
            if edit.text != field.stringValue {
                field.stringValue = edit.text
                editor?.string = edit.text
                editor?.setSelectedRange(edit.selection)
            }
            field.previousEditingText = edit.text
            invalidInput = !model.enter(edit.normalized, currency: code)
        } else {
            field.previousEditingText = field.stringValue
            invalidInput = true
        }
        field.textColor = invalidInput ? .systemRed : .labelColor
        if let editor { styleEditor(editor, invalid: invalidInput) }
        field.setAccessibilityHelp(invalidInput ? "Enter a number up to 100 billion, such as 1,234.56." : "Type to replace this amount. Use up and down arrows to select a currency.")
        updateStatus()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? AmountField, let code = field.identifier?.rawValue else { return }
        isTyping = false; invalidInput = false
        field.stringValue = model.formatted(code)
        field.previousEditingText = nil
        updateStatus()
    }

    private func styleEditor(_ editor: NSTextView, invalid: Bool = false) {
        editor.textColor = invalid ? .systemRed : .labelColor
        editor.insertionPointColor = .labelColor
        editor.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor,
                                        .foregroundColor: NSColor.selectedTextColor]
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control is AmountField else {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) { backToMain(); return true }
            return false
        }
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)):
            model.moveSelection(1); return true
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.insertBacktab(_:)):
            model.moveSelection(-1); return true
        case #selector(NSResponder.insertNewline(_:)):
            isTyping = false; invalidInput = false; updateValues(); focusSelected(); model.flush(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?(); return true
        default: return false
        }
    }

    @objc private func showManage() {
        mode = .manage
        reset(width: 360, height: 500, title: "Your currencies", back: true)
        let search = NSSearchField(frame: NSRect(x: 17, y: 52, width: 326, height: 29))
        search.placeholderString = "Find a currency…"; search.delegate = self
        search.setAccessibilityLabel("Find a currency"); searchField = search; view.addSubview(search)
        let scroll = NSScrollView(frame: NSRect(x: 9, y: 92, width: 342, height: 357))
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder; scroll.drawsBackground = false
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 326, height: 357))
        scroll.documentView = document; view.addSubview(scroll); scrollView = scroll; manageList = document
        separator(y: 459)
        let hint = label("Use ↑ and ↓ buttons to reorder your list.", size: 11, color: .secondaryLabelColor)
        hint.frame = NSRect(x: 18, y: 474, width: 320, height: 18); view.addSubview(hint)
        renderManageRows()
        view.window?.makeFirstResponder(search)
    }

    private func renderManageRows() {
        guard let document = manageList else { return }
        let origin = scrollView?.contentView.bounds.origin ?? .zero
        document.subviews.forEach { $0.removeFromSuperview() }
        let query = searchField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let available = model.catalog.filter { model.snapshot.quotes[$0.isoCode] != nil }
        let byCode = Dictionary(uniqueKeysWithValues: available.map { ($0.isoCode, $0) })
        let order = model.currencies + available.map(\.isoCode).filter { !model.currencies.contains($0) }
        visibleCodes = order.filter { code in
            query.isEmpty || code.localizedCaseInsensitiveContains(query) || (byCode[code]?.name.localizedCaseInsensitiveContains(query) ?? false)
        }
        document.frame.size.height = max(357, CGFloat(visibleCodes.count) * 35)
        for (index, code) in visibleCodes.enumerated() {
            let info = model.currency(code), y = CGFloat(index) * 35
            let check = NSButton(checkboxWithTitle: "\(info.flag)  \(code)  \(info.name)", target: self, action: #selector(toggleCurrency(_:)))
            check.font = .systemFont(ofSize: 12); check.frame = NSRect(x: 7, y: y + 6, width: 257, height: 23)
            check.cell?.lineBreakMode = .byTruncatingTail
            check.toolTip = info.name; check.tag = index
            let selected = model.currencies.contains(code)
            check.state = selected ? .on : .off
            check.isEnabled = !(selected && model.currencies.count == 1)
            check.setAccessibilityLabel("\(code), \(info.name)")
            document.addSubview(check)
            if let position = model.currencies.firstIndex(of: code) {
                let up = iconButton("chevron.up", label: "Move \(code) up", action: #selector(moveCurrency(_:)))
                up.identifier = NSUserInterfaceItemIdentifier("up.\(code)")
                up.frame = NSRect(x: 268, y: y + 3, width: 25, height: 28); up.isEnabled = position > 0
                document.addSubview(up)
                let down = iconButton("chevron.down", label: "Move \(code) down", action: #selector(moveCurrency(_:)))
                down.identifier = NSUserInterfaceItemIdentifier("down.\(code)")
                down.frame = NSRect(x: 296, y: y + 3, width: 25, height: 28); down.isEnabled = position < model.currencies.count - 1
                document.addSubview(down)
            }
        }
        if visibleCodes.isEmpty {
            let empty = label("No matching currencies", size: 13, color: .secondaryLabelColor)
            empty.frame = NSRect(x: 10, y: 20, width: 300, height: 24); document.addSubview(empty)
        }
        scrollView?.contentView.scroll(to: NSPoint(x: 0, y: min(origin.y, max(0, document.frame.height - 357))))
        if let scrollView { scrollView.reflectScrolledClipView(scrollView.contentView) }
    }

    @objc private func toggleCurrency(_ sender: NSButton) {
        guard visibleCodes.indices.contains(sender.tag) else { return }
        model.toggle(visibleCodes[sender.tag], enabled: sender.state == .on)
    }

    @objc private func moveCurrency(_ sender: NSButton) {
        guard let parts = sender.identifier?.rawValue.split(separator: "."), parts.count == 2 else { return }
        model.reorder(String(parts[1]), delta: parts[0] == "up" ? -1 : 1)
    }

    @objc private func showSettings() {
        mode = .settings
        reset(width: 340, height: 469, title: "Settings", back: true)
        settingLabel("Check for new rates", y: 62)
        let interval = NSPopUpButton(frame: NSRect(x: 188, y: 56, width: 133, height: 28), pullsDown: false)
        interval.addItems(withTitles: ["Every hour", "Every 4 hours", "Daily"])
        interval.selectItem(at: [3600.0,14400.0,86400.0].firstIndex(of: model.settings.refreshInterval) ?? 0)
        interval.target = self; interval.action = #selector(changeInterval(_:)); interval.setAccessibilityLabel("Refresh interval")
        view.addSubview(interval)
        settingLabel("Decimal places", y: 105)
        let decimals = NSPopUpButton(frame: NSRect(x: 188, y: 99, width: 133, height: 28), pullsDown: false)
        decimals.addItems(withTitles: ["0 digits", "2 digits", "4 digits"])
        decimals.selectItem(at: [0,2,4].firstIndex(of: model.settings.decimals) ?? 1)
        decimals.target = self; decimals.action = #selector(changeDecimals(_:)); decimals.setAccessibilityLabel("Decimal places")
        view.addSubview(decimals)
        let flags = NSButton(checkboxWithTitle: "Show flags", target: self, action: #selector(changeFlags(_:)))
        flags.frame = NSRect(x: 18, y: 143, width: 270, height: 25); flags.state = model.settings.showFlags ? .on : .off
        view.addSubview(flags)
        let login = NSButton(checkboxWithTitle: "Launch at login", target: self, action: #selector(changeLogin(_:)))
        login.frame = NSRect(x: 18, y: 181, width: 270, height: 25); login.state = model.loginEnabled ? .on : .off
        view.addSubview(login)
        let shortcut = label(hotKeyAvailable ? "Open from anywhere   Right ⌘Y" : "Shortcut unavailable · use the menu bar icon", size: 12, color: .secondaryLabelColor)
        shortcut.frame = NSRect(x: 20, y: 224, width: 303, height: 22); view.addSubview(shortcut)
        let keys = label("↑ ↓ Select · type to replace\nEnter Format · Esc Close · ⌘C Copy", size: 11, color: .secondaryLabelColor)
        keys.maximumNumberOfLines = 2
        keys.frame = NSRect(x: 20, y: 250, width: 303, height: 36); view.addSubview(keys)
        separator(y: 296)
        let source = NSButton(title: "Rates by Frankfurter ↗", target: self, action: #selector(openProvider))
        source.bezelStyle = .inline; source.isBordered = false; source.font = .systemFont(ofSize: 11)
        source.contentTintColor = .secondaryLabelColor; source.frame = NSRect(x: 17, y: 307, width: 180, height: 22)
        view.addSubview(source)
        sourceField = label(model.footerText, size: 11, color: .secondaryLabelColor)
        sourceField.frame = NSRect(x: 20, y: 340, width: 267, height: 21)
        sourceField.setAccessibilityIdentifier("rate-status"); view.addSubview(sourceField)
        refreshButton = iconButton("arrow.clockwise", label: "Refresh exchange rates", action: #selector(refreshRates))
        refreshButton.frame = NSRect(x: 294, y: 333, width: 27, height: 28); view.addSubview(refreshButton)
        settingsMessage = label(model.loginNeedsApproval ? "Allow login access in System Settings." : "Daily reference rates · saved for offline use", size: 10.5, color: .secondaryLabelColor)
        settingsMessage?.frame = NSRect(x: 20, y: 377, width: 303, height: 35)
        settingsMessage?.maximumNumberOfLines = 2; settingsMessage?.lineBreakMode = .byWordWrapping
        if let settingsMessage { view.addSubview(settingsMessage) }
        let quit = NSButton(title: "Quit Compact Currency", target: self, action: #selector(quitApp))
        quit.bezelStyle = .rounded; quit.font = .systemFont(ofSize: 11)
        quit.frame = NSRect(x: 15, y: 430, width: 176, height: 26); view.addSubview(quit)
        updateStatus()
    }

    @objc private func changeInterval(_ sender: NSPopUpButton) { model.setInterval([3600,14400,86400][sender.indexOfSelectedItem]) }
    @objc private func changeDecimals(_ sender: NSPopUpButton) { model.setDecimals([0,2,4][sender.indexOfSelectedItem]) }
    @objc private func changeFlags(_ sender: NSButton) { model.setFlags(sender.state == .on) }
    @objc private func changeLogin(_ sender: NSButton) {
        do {
            try model.setLogin(sender.state == .on)
            sender.state = model.loginEnabled ? .on : .off
            settingsMessage?.stringValue = model.loginNeedsApproval ? "Allow Compact Currency in Login Items in System Settings." : "Login preference saved."
        } catch {
            sender.state = model.loginEnabled ? .on : .off
            settingsMessage?.stringValue = "Could not change login access: \(error.localizedDescription)"
            settingsMessage?.textColor = .systemRed
        }
    }
    @objc private func openProvider() { NSWorkspace.shared.open(URL(string: "https://frankfurter.dev/")!) }
    @objc private func quitApp() { model.flush(); NSApp.terminate(nil) }
    @objc private func backToMain() { renderMain(); focusSelected() }
    @objc private func refreshRates() { model.refresh() }

    private func settingLabel(_ text: String, y: CGFloat) {
        let field = label(text, size: 12)
        field.frame = NSRect(x: 20, y: y, width: 164, height: 22); view.addSubview(field)
    }

    private func separator(y: CGFloat) {
        let line = NSBox(frame: NSRect(x: 0, y: y, width: view.frame.width, height: 1))
        line.boxType = .separator; view.addSubview(line)
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight); field.textColor = color
        return field
    }

    private func iconButton(_ symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
        button.isBordered = false; button.bezelStyle = .inline; button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor; button.toolTip = label
        button.setAccessibilityLabel(label)
        return button
    }
}
