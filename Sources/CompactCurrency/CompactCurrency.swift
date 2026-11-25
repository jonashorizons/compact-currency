import AppKit
import Carbon
import CurrencyCore

@main
enum CompactCurrencyApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        // LSUIElement in Info.plist makes this an agent. Setting .accessory here
        // creates zero-height status items on macOS 27 with menu bar managers.
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var model: AppModel?
    private var controller: ConverterController?
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var testWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let smokeTest = CommandLine.arguments.contains("--smoke-test")
        if !smokeTest, let identifier = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("CompactCurrency.Open"), object: nil, userInfo: nil, deliverImmediately: true)
            existing.activate()
            NSApp.terminate(nil); return
        }
        do {
            let directory = CommandLine.arguments.first { $0.hasPrefix("--state-directory=") }
                .map { URL(fileURLWithPath: String($0.dropFirst("--state-directory=".count)), isDirectory: true) }
            let state = try AppModel(directory: directory)
            model = state
            let content = ConverterController(model: state)
            controller = content
            popover.behavior = .transient; popover.animates = true; popover.delegate = self
            popover.contentViewController = content
            _ = content.view
            popover.contentSize = content.preferredContentSize
            content.onClose = { [weak self] in self?.popover.performClose(nil) }
            content.onResize = { [weak self] size in self?.popover.contentSize = size }
            if smokeTest { runSmokeTest(state: state, controller: content); return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.autosaveName = "ai.exique.compactcurrency.main"
            item.behavior = []
            statusItem = item
            if let button = item.button {
                let image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "Compact Currency")!
                image.isTemplate = true; button.image = image
                button.title = ""; button.imagePosition = .imageOnly
                button.setAccessibilityIdentifier("ai.exique.compactcurrency.main")
                button.toolTip = "Compact Currency · Right ⌘Y"
                button.setAccessibilityLabel("Compact Currency")
                button.target = self; button.action = #selector(statusClicked(_:))
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            }
            item.isVisible = true
            content.hotKeyAvailable = registerHotKey()
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(openFromNotification(_:)), name: Notification.Name("CompactCurrency.Open"), object: nil)
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)
            state.start()
            writeStartupDiagnosticsIfRequested()
            if CommandLine.arguments.contains("--show") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.togglePopover() }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Compact Currency could not start"
            alert.informativeText = error.localizedDescription
            alert.runModal(); NSApp.terminate(nil)
        }
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            let open = NSMenuItem(title: "Open Currency", action: #selector(openMenu), keyEquivalent: "")
            open.target = self; menu.addItem(open)
            let refresh = NSMenuItem(title: "Refresh Rates", action: #selector(refreshRates), keyEquivalent: "")
            refresh.target = self; menu.addItem(refresh)
            menu.addItem(.separator())
            let quit = NSMenuItem(title: "Quit Compact Currency", action: #selector(quitApp), keyEquivalent: "q")
            quit.target = self; menu.addItem(quit)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
        } else { togglePopover() }
    }

    func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        controller?.prepareToOpen(on: button.window?.screen ?? NSScreen.main)
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        controller?.opened()
    }

    @objc private func openMenu() { if !popover.isShown { togglePopover() } }
    @objc private func openFromNotification(_ notification: Notification) { openMenu() }
    @objc private func refreshRates() { model?.refresh() }
    @objc private func quitApp() { NSApp.terminate(nil) }
    @objc private func didWake(_ notification: Notification) { model?.refreshIfNeeded() }
    func popoverDidClose(_ notification: Notification) { controller?.closed() }
    func applicationWillTerminate(_ notification: Notification) {
        model?.flush()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    private func registerHotKey() -> Bool {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { delegate.togglePopover() }
            return noErr
        }, 1, &event, context, &eventHandler)
        guard handlerStatus == noErr else { return false }
        let identifier = EventHotKeyID(signature: OSType(0x43465843), id: 1)
        // Karabiner maps only Right Command + Y to this private chord. Carbon
        // cannot distinguish Command sides; registering Command + Y directly
        // would also consume ordinary Left Command + Y in other applications.
        return RegisterEventHotKey(UInt32(kVK_F20), UInt32(controlKey | optionKey | cmdKey), identifier,
                                  GetApplicationEventTarget(), 0, &hotKey) == noErr
    }

    private func writeStartupDiagnosticsIfRequested() {
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--diagnostics-file=") }) else { return }
        let url = URL(fileURLWithPath: String(argument.dropFirst("--diagnostics-file=".count)))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, let item = self.statusItem, let button = item.button else { return }
            let frame = button.window?.frame ?? .zero
            let output: [String: Any] = [
                "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
                "bundlePath": Bundle.main.bundleURL.path,
                "autosaveName": item.autosaveName ?? "",
                "accessibilityIdentifier": button.accessibilityIdentifier(),
                "visible": item.isVisible,
                "buttonHeight": button.bounds.height,
                "windowHeight": frame.height,
                "agentPolicy": NSApp.activationPolicy() == .accessory,
                "shortcutAvailable": self.controller?.hotKeyAvailable ?? false,
                "currencyCount": self.model?.currencies.count ?? 0,
                "popoverContentHeight": self.controller?.preferredContentSize.height ?? 0,
                "hasVerticalScroller": self.controller?.view.subviews.compactMap { $0 as? NSScrollView }.first?.hasVerticalScroller ?? false,
                "lastRowVisibleHeight": self.model?.currencies.last.flatMap { code in
                    self.controller?.rows[code].map { $0.visibleRect.intersection($0.bounds).height }
                } ?? 0,
                "thawRunning": NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.lastPathComponent == "Thaw.app" }
            ]
            do { try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic) }
            catch { fputs("Could not write startup diagnostics: \(error.localizedDescription)\n", stderr) }
        }
    }

    private func runSmokeTest(state: AppModel, controller: ConverterController) {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 310, height: 440),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        testWindow = window
        window.title = "Compact Currency · verification"
        window.contentViewController = controller
        window.setContentSize(controller.preferredContentSize)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.opened()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            var checks: [String: Bool] = [:]
            state.select("CHF")
            if let editor = window.firstResponder as? NSTextView {
                checks["initialAmountSelected"] = editor.selectedRange().length == (editor.string as NSString).length
                editor.insertText("250", replacementRange: editor.selectedRange())
                checks["typingReplacesAmount"] = state.settings.anchorAmount == 250 && state.settings.anchorCurrency == "CHF"
                editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
                checks["downSelectsGBP"] = state.selectedCode == "GBP"
                if let next = window.firstResponder as? NSTextView {
                    checks["nextAmountSelected"] = next.selectedRange().length == (next.string as NSString).length
                    next.insertText("10", replacementRange: next.selectedRange())
                    checks["typingAfterArrowReplacesAmount"] = state.settings.anchorAmount == 10 && state.settings.anchorCurrency == "GBP"
                    next.selectAll(nil)
                    next.insertText("1234567", replacementRange: next.selectedRange())
                    checks["liveGrouping"] = next.string == "1,234,567" && state.settings.anchorAmount == 1234567
                    next.insertText("8", replacementRange: next.selectedRange())
                    checks["typingPastExistingCommas"] = next.string == "12,345,678" && state.settings.anchorAmount == 12345678
                    checks["caretPreservedAtEnd"] = next.selectedRange() == NSRange(location: 10, length: 0)
                    next.setSelectedRange(NSRange(location: 3, length: 0))
                    next.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
                    checks["deleteCommaPreservesAmount"] = state.settings.anchorAmount == 12345678 && next.selectedRange().location == 2
                    next.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
                    checks["backspaceNotTrappedByComma"] = state.settings.anchorAmount == 1345678
                    next.selectAll(nil)
                    next.insertText("12345.00", replacementRange: next.selectedRange())
                    checks["editingKeepsFractionalZeros"] = next.string == "12,345.00" && state.settings.anchorAmount == 12345
                    checks["editorUsesContrastingText"] = next.textColor == NSColor.labelColor
                    next.selectAll(nil)
                    next.insertText("10", replacementRange: next.selectedRange())
                    next.doCommand(by: #selector(NSResponder.moveUp(_:)))
                    checks["upSelectsCHF"] = state.selectedCode == "CHF"
                }
            }
            checks["allRowsHaveValues"] = state.currencies.allSatisfy { state.amount($0) != nil }
            checks["mainHasNoFooter"] = !controller.view.subviews.contains { $0.accessibilityIdentifier() == "rate-status" }
            let source = state.settings.anchorAmount
            state.select("EUR")
            checks["selectionPreservesAnchor"] = state.settings.anchorAmount == source && state.settings.anchorCurrency == "GBP"
            state.toggle("SGD", enabled: true)
            checks["addCurrency"] = state.currencies.contains("SGD")
            state.reorder("SGD", delta: -1)
            checks["reorderCurrency"] = state.currencies[state.currencies.count - 2] == "SGD"
            state.toggle("SGD", enabled: false)
            checks["removeCurrency"] = !state.currencies.contains("SGD")
            controller.perform(NSSelectorFromString("showManage"))
            checks["manageView"] = controller.mode == .manage
            controller.perform(NSSelectorFromString("showSettings"))
            checks["settingsView"] = controller.mode == .settings
            checks["rateInfoMovedToSettings"] = controller.view.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue == state.footerText }
            checks["keyboardHelpMovedToSettings"] = controller.view.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("↑ ↓ Select") }
            if let screenshot = CommandLine.arguments.first(where: { $0.hasPrefix("--settings-screenshot=") }),
               let bitmap = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) {
                controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: String(screenshot.dropFirst("--settings-screenshot=".count))))
            }
            controller.renderMain()
            let originalCodes = state.currencies
            for code in ["SGD", "VND", "CNY", "HKD", "NZD"] { state.toggle(code, enabled: true) }
            if let scroll = controller.view.subviews.compactMap({ $0 as? NSScrollView }).first {
                let fullHeight = CGFloat(state.currencies.count) * 40
                checks["listGrowsPastTenRows"] = state.currencies.count > 10 && scroll.contentView.bounds.height >= fullHeight
                checks["allRowsFitWithoutScrolling"] = scroll.documentView?.bounds.height == scroll.contentView.bounds.height
                checks["noVisibleScrollbars"] = !scroll.hasVerticalScroller && !scroll.hasHorizontalScroller
            }
            for code in state.currencies where !originalCodes.contains(code) { state.toggle(code, enabled: false) }
            checks["listShrinksAfterRemoval"] = controller.view.frame.height == 56 + CGFloat(originalCodes.count) * 40
            _ = state.enter("1000", currency: "CHF"); state.select("CHF"); state.flush()
            if CommandLine.arguments.contains("--expanded-list-preview") {
                for code in ["VND", "CNY", "NZD"] { state.toggle(code, enabled: true) }
            }
            if CommandLine.arguments.contains("--large-entry-preview") {
                state.select("THB")
                if let editor = window.firstResponder as? NSTextView { editor.insertText("12121212", replacementRange: editor.selectedRange()) }
            }
            if let screenshot = CommandLine.arguments.first(where: { $0.hasPrefix("--screenshot=") }),
               let bitmap = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) {
                controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: String(screenshot.dropFirst("--screenshot=".count))))
            }
            let success = checks.count >= 13 && checks.values.allSatisfy { $0 }
            let output: [String: Any] = ["success": success, "checks": checks, "quoteDate": state.quoteDate]
            if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: data, encoding: .utf8) { print(text) }
            fflush(stdout)
            window.orderOut(nil)
            exit(success ? 0 : 1)
        }
    }
}
