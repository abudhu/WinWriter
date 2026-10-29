import AppKit
import UniformTypeIdentifiers
import WinWriterCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation, NSMenuDelegate {
    private var window: NSWindow!
    private let chooseISOButton = NSButton(title: "Choose ISO…", target: nil, action: nil)
    private let isoLabel = NSTextField(labelWithString: "No ISO selected")
    private let isoDetail = NSTextField(labelWithString: "Choose the x64 or Arm64 image for your PC.")
    private let diskPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let diskDetail = NSTextField(wrappingLabelWithString: "Looking for external, physical USB disks…")
    private let createButton = NSButton(title: "Create Windows USB", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let stageLabel = NSTextField(wrappingLabelWithString: "Choose an ISO and a USB disk to begin.")
    private let percentLabel = NSTextField(labelWithString: "")
    private let statusIcon = NSImageView()
    private let statusDetail = NSTextField(wrappingLabelWithString: "")
    private let settingsButton = NSButton(title: "Fast creation", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private let copyLogsButton = NSButton(title: "Copy Logs", target: nil, action: nil)
    private let logView = NSTextView(frame: NSRect(x: 0, y: 0, width: 730, height: 180))
    private let logScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 730, height: 180))
    private let logCharacterLimit = 200_000

    private var isoURL: URL?
    private var disks: [DiskTarget] = []
    private var scanInFlight = false
    private var diskMenuIsOpen = false
    private var lastScanError: String?
    private var isConfirming = false
    private var isCreating = false
    private var hasResult = false
    private var cancellation: Cancellation?
    private var canCancel = false
    private var lastStage: String?
    private var activity: NSObjectProtocol?
    private var activeOperationAlert: NSAlert?
    private let verificationMenuItem = NSMenuItem(title: "Full Verification (Slower)", action: #selector(toggleVerification(_:)), keyEquivalent: "")

    private var verifyContents: Bool {
        get { UserDefaults.standard.bool(forKey: "verifyContents") }
        set { UserDefaults.standard.set(newValue, forKey: "verifyContents") }
    }

    private var controlsLocked: Bool { isCreating || isConfirming }

    private var selectedDisk: DiskTarget? {
        let index = diskPopup.indexOfSelectedItem - 1
        return disks.indices.contains(index) ? disks[index] : nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeWindow()
        makeMenu()
        appendLog("Select a Windows 11 ISO and an external USB disk. No disk is erased until you confirm its exact identity and authorize formatting.")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshDisks()
    }

    private func makeWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 690),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "WinWriter"
        window.minSize = NSSize(width: 660, height: 680)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        let root = stack(.vertical, spacing: 20)
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 28),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -24)
        ])

        let title = NSTextField(labelWithString: "Create a Windows USB")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Windows 11 installers for UEFI PCs.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        let heading = stack(.horizontal, spacing: 16, views: [
            symbol("externaldrive.badge.plus", size: 40, color: .controlAccentColor),
            stack(.vertical, spacing: 5, views: [title, subtitle]), NSView()
        ])
        add(heading, to: root)

        configure(chooseISOButton, action: #selector(chooseISO(_:)), accessibility: "Choose Windows 11 ISO file")
        chooseISOButton.setContentHuggingPriority(.required, for: .horizontal)
        isoLabel.font = .systemFont(ofSize: 13, weight: .medium)
        isoLabel.textColor = .secondaryLabelColor
        isoLabel.isSelectable = true
        isoLabel.lineBreakMode = .byTruncatingMiddle
        isoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        isoLabel.setAccessibilityLabel("Selected Windows ISO")
        isoDetail.font = .systemFont(ofSize: 12)
        isoDetail.textColor = .secondaryLabelColor
        isoDetail.lineBreakMode = .byTruncatingMiddle
        isoDetail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let isoRow = stack(.horizontal, spacing: 12, views: [isoLabel, chooseISOButton])
        let isoGroup = stack(.vertical, spacing: 6)
        add(sectionTitle("1  Windows ISO"), to: isoGroup)
        add(isoRow, to: isoGroup)
        add(isoDetail, to: isoGroup)
        let sourceRow = stack(.horizontal, spacing: 16, views: [symbol("doc.badge.gearshape", size: 28), isoGroup])

        diskPopup.target = self
        diskPopup.action = #selector(diskSelectionChanged(_:))
        diskPopup.setAccessibilityLabel("External physical USB disk to erase")
        diskPopup.addItem(withTitle: "Looking for USB drives…")
        diskPopup.menu?.delegate = self
        diskPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        configure(refreshButton, action: #selector(refreshClicked(_:)), accessibility: "Refresh external USB disks")
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        refreshButton.imagePosition = .imageLeading
        refreshButton.setContentHuggingPriority(.required, for: .horizontal)
        let diskRow = stack(.horizontal, spacing: 12, views: [diskPopup, refreshButton])
        diskDetail.font = .systemFont(ofSize: 12)
        diskDetail.textColor = .secondaryLabelColor
        diskDetail.isSelectable = true
        diskDetail.maximumNumberOfLines = 2
        diskDetail.setAccessibilityLabel("Selected disk capacity and device identifier")
        let diskGroup = stack(.vertical, spacing: 6)
        add(sectionTitle("2  USB drive"), to: diskGroup)
        add(diskRow, to: diskGroup)
        add(diskDetail, to: diskGroup)
        let targetRow = stack(.horizontal, spacing: 16, views: [symbol("externaldrive", size: 28), diskGroup])

        let inputs = stack(.vertical, spacing: 18)
        add(sourceRow, to: inputs)
        let divider = NSBox()
        divider.boxType = .separator
        add(divider, to: inputs)
        add(targetRow, to: inputs)
        add(card(inputs, inset: 20), to: root)

        let warning = NSTextField(wrappingLabelWithString: "All data on the selected USB drive will be erased.")
        warning.font = .systemFont(ofSize: 12)
        warning.textColor = .secondaryLabelColor
        warning.setAccessibilityLabel("Warning: all data on the selected USB disk will be permanently erased")
        let warningRow = stack(.horizontal, spacing: 8, views: [
            symbol("exclamationmark.triangle", size: 15, color: .systemOrange), warning, NSView()
        ])

        configure(settingsButton, action: #selector(showSettings(_:)), accessibility: "Creation mode and verification settings")
        settingsButton.title = verifyContents ? "Full verification" : "Fast creation"
        settingsButton.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)
        settingsButton.imagePosition = .imageLeading
        settingsButton.toolTip = "Choose whether to perform full content verification."
        configure(createButton, action: #selector(confirmCreation(_:)), accessibility: "Create Windows USB, requires erase confirmation")
        createButton.controlSize = .large
        createButton.font = .systemFont(ofSize: 13, weight: .medium)
        createButton.keyEquivalent = "\r"
        configure(cancelButton, action: #selector(cancelClicked(_:)), accessibility: "Cancel USB creation at a safe point")
        cancelButton.keyEquivalent = "."
        cancelButton.keyEquivalentModifierMask = [.command]
        cancelButton.isHidden = true
        let actions = stack(.horizontal, spacing: 10, views: [settingsButton, NSView(), cancelButton, createButton])
        let actionGroup = stack(.vertical, spacing: 14)
        add(warningRow, to: actionGroup)
        add(actions, to: actionGroup)
        add(actionGroup, to: root)

        stageLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        stageLabel.maximumNumberOfLines = 2
        stageLabel.setAccessibilityLabel("Creation stage")
        statusDetail.font = .systemFont(ofSize: 12)
        statusDetail.textColor = .secondaryLabelColor
        statusDetail.maximumNumberOfLines = 2
        percentLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        percentLabel.textColor = .secondaryLabelColor
        percentLabel.setContentHuggingPriority(.required, for: .horizontal)
        percentLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusIcon.imageScaling = .scaleProportionallyDown
        statusIcon.setAccessibilityElement(false)
        NSLayoutConstraint.activate([
            statusIcon.widthAnchor.constraint(equalToConstant: 22),
            statusIcon.heightAnchor.constraint(equalToConstant: 22)
        ])
        let statusText = stack(.vertical, spacing: 5)
        add(stageLabel, to: statusText)
        add(statusDetail, to: statusText)
        let stageRow = stack(.horizontal, spacing: 12, views: [statusIcon, statusText, percentLabel])
        progress.style = .bar
        progress.minValue = 0
        progress.maxValue = 1
        progress.isIndeterminate = false
        progress.isDisplayedWhenStopped = true
        progress.setAccessibilityLabel("Current stage progress")
        let status = stack(.vertical, spacing: 12)
        add(stageRow, to: status)
        add(progress, to: status)
        let statusCard = card(status, inset: 16)
        statusCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 78).isActive = true
        add(statusCard, to: root)

        configure(copyLogsButton, action: #selector(copyLogs(_:)), accessibility: "Copy creation logs to clipboard")
        copyLogsButton.controlSize = .small
        copyLogsButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        copyLogsButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copyLogsButton.imagePosition = .imageLeading
        let logTitle = sectionTitle("Activity log")
        logTitle.textColor = .secondaryLabelColor
        let logHeading = stack(.horizontal, spacing: 12, views: [logTitle, NSView(), copyLogsButton])
        logView.isEditable = false
        logView.isSelectable = true
        logView.allowsUndo = false
        logView.usesFindBar = true
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textColor = .textColor
        logView.drawsBackground = false
        logView.textContainerInset = NSSize(width: 12, height: 10)
        logView.minSize = .zero
        logView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        logView.isVerticallyResizable = true
        logView.isHorizontallyResizable = false
        logView.autoresizingMask = [.width]
        logView.textContainer?.widthTracksTextView = true
        logView.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        logView.setAccessibilityLabel("Live USB creation log")
        logView.setAccessibilityHelp("Read-only log. Select and copy text, or use Copy Logs. The most recent 200,000 characters are retained.")
        logScroll.documentView = logView
        logScroll.hasVerticalScroller = true
        logScroll.autohidesScrollers = true
        logScroll.borderType = .noBorder
        logScroll.drawsBackground = false
        logScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        logScroll.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        let logCard = card(logScroll, inset: 0)
        logCard.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        let logs = stack(.vertical, spacing: 8)
        logs.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        add(logHeading, to: logs)
        add(logCard, to: logs)
        add(logs, to: root)

        window.initialFirstResponder = chooseISOButton
        chooseISOButton.nextKeyView = diskPopup
        diskPopup.nextKeyView = refreshButton
        refreshButton.nextKeyView = settingsButton
        settingsButton.nextKeyView = createButton
        createButton.nextKeyView = cancelButton
        cancelButton.nextKeyView = copyLogsButton
        copyLogsButton.nextKeyView = logView
        logView.nextKeyView = chooseISOButton
        updateControlState()
    }

    private func stack(_ orientation: NSUserInterfaceLayoutOrientation, spacing: CGFloat, views: [NSView] = []) -> NSStackView {
        let result = NSStackView(views: views)
        result.orientation = orientation
        result.spacing = spacing
        result.alignment = orientation == .horizontal ? .centerY : .leading
        result.distribution = .fill
        return result
    }

    private func add(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func sectionTitle(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func symbol(_ name: String, size: CGFloat, color: NSColor = .secondaryLabelColor) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        view.contentTintColor = color
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setAccessibilityElement(false)
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: size),
            view.heightAnchor.constraint(equalToConstant: size)
        ])
        return view
    }

    private func card(_ content: NSView, inset: CGFloat) -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.borderWidth = 0.5
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.cornerRadius = 10
        box.contentViewMargins = .zero
        let container = box.contentView!
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: inset),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -inset)
        ])
        return box
    }

    private func setStatusSymbol(_ name: String, color: NSColor) {
        statusIcon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        statusIcon.contentTintColor = color
    }

    @objc private func showSettings(_ sender: NSButton) {
        guard !controlsLocked else { return }
        verificationMenuItem.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: -6), in: sender)
    }

    private func configure(_ button: NSButton, action: Selector, accessibility: String) {
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        button.setAccessibilityLabel(accessibility)
    }

    private func makeMenu() {
        let menu = NSMenu()
        let appMenu = NSMenu(title: "WinWriter")
        appMenu.addItem(withTitle: "About WinWriter", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsMenu = NSMenu(title: "Settings")
        verificationMenuItem.target = self
        verificationMenuItem.state = verifyContents ? .on : .off
        settingsMenu.addItem(verificationMenuItem)
        addMenu(settingsMenu, to: appMenu)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide WinWriter", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit WinWriter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        addMenu(appMenu, to: menu)

        let fileMenu = NSMenu(title: "File")
        let open = fileMenu.addItem(withTitle: "Choose ISO…", action: #selector(chooseISO(_:)), keyEquivalent: "o")
        open.target = self
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        addMenu(fileMenu, to: menu)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        addMenu(editMenu, to: menu)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        addMenu(windowMenu, to: menu)
        NSApp.mainMenu = menu
        NSApp.windowsMenu = windowMenu
    }

    private func addMenu(_ submenu: NSMenu, to menu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleVerification(_:)) {
            menuItem.state = verifyContents ? .on : .off
            return !controlsLocked
        }
        if menuItem.action == #selector(chooseISO(_:)) {
            return !controlsLocked && window.attachedSheet == nil
        }
        return true
    }

    @objc private func toggleVerification(_ sender: NSMenuItem) {
        guard !controlsLocked else { return }
        verifyContents.toggle()
        sender.state = verifyContents ? .on : .off
        settingsButton.title = verifyContents ? "Full verification" : "Fast creation"
    }

    @objc private func chooseISO(_ sender: Any?) {
        guard !controlsLocked, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a Windows 11 ISO"
        panel.prompt = "Choose ISO"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowsOtherFileTypes = false
        panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .diskImage]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            guard url.pathExtension.caseInsensitiveCompare("iso") == .orderedSame else {
                self.showError(title: "Choose an ISO file", message: "The selected file must have the .iso extension.")
                return
            }
            self.isoURL = url
            self.isoLabel.stringValue = url.lastPathComponent
            self.isoLabel.toolTip = url.path
            self.isoLabel.textColor = .labelColor
            self.isoDetail.stringValue = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
            self.isoDetail.toolTip = url.path
            self.hasResult = false
            self.updateControlState()
        }
    }

    @objc private func refreshClicked(_ sender: Any?) {
        guard !controlsLocked else { return }
        hasResult = false
        refreshDisks()
    }

    private func refreshDisks() {
        guard !controlsLocked, !scanInFlight, !diskMenuIsOpen else { return }
        scanInFlight = true
        updateControlState()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try DiskService.list() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanInFlight = false
                guard !self.controlsLocked, !self.diskMenuIsOpen else {
                    self.updateControlState()
                    return
                }
                let previous = self.selectedDisk
                self.diskPopup.removeAllItems()
                self.diskPopup.menu?.autoenablesItems = false
                switch result {
                case .success(let disks):
                    self.disks = disks
                    self.lastScanError = nil
                    self.diskPopup.addItem(withTitle: disks.isEmpty ? "No USB drives found" : "Select a USB drive…")
                    self.diskPopup.item(at: 0)?.isEnabled = false
                    for disk in disks {
                        self.diskPopup.addItem(withTitle: disk.displayName)
                        self.diskPopup.lastItem?.toolTip = disk.displayName
                    }
                    if let previous, let index = disks.firstIndex(of: previous) {
                        self.diskPopup.selectItem(at: index + 1)
                    } else {
                        self.diskPopup.selectItem(at: 0)
                    }
                    self.updateDiskDetail()
                case .failure(let error):
                    self.disks = []
                    self.diskPopup.addItem(withTitle: "USB disk scan unsuccessful")
                    self.diskPopup.item(at: 0)?.isEnabled = false
                    self.diskDetail.stringValue = "Could not list USB disks: \(error.localizedDescription)"
                    self.diskDetail.toolTip = error.localizedDescription
                    self.diskDetail.textColor = .systemRed
                    if self.lastScanError != error.localizedDescription {
                        self.appendLog("USB scan unsuccessful: \(error.localizedDescription)")
                        self.lastScanError = error.localizedDescription
                    }
                }
                self.updateControlState()
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === diskPopup.menu { diskMenuIsOpen = true }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === diskPopup.menu { diskMenuIsOpen = false }
    }

    @objc private func diskSelectionChanged(_ sender: Any?) {
        hasResult = false
        updateDiskDetail()
        updateControlState()
    }

    private func updateDiskDetail() {
        diskDetail.textColor = .secondaryLabelColor
        if let disk = selectedDisk {
            let capacity = ByteCountFormatter.string(fromByteCount: disk.size, countStyle: .file)
            diskDetail.stringValue = "\(capacity) capacity · /dev/\(disk.id) · Entire disk will be erased."
            diskDetail.toolTip = disk.displayName
            diskPopup.toolTip = disk.displayName
        } else {
            diskDetail.stringValue = disks.isEmpty
                ? "Connect a USB drive (2 TB or smaller), then click Refresh."
                : "Only external, physical USB drives are listed."
            diskPopup.toolTip = "Only eligible external physical USB disks are listed."
            diskDetail.toolTip = "Internal, virtual, and non-USB disks are never offered."
        }
    }

    private func updateControlState() {
        verificationMenuItem.isEnabled = !controlsLocked
        settingsButton.isEnabled = !controlsLocked
        chooseISOButton.isEnabled = !controlsLocked
        diskPopup.isEnabled = !controlsLocked && !disks.isEmpty
        refreshButton.isEnabled = !controlsLocked && !scanInFlight
        createButton.isEnabled = !controlsLocked && isoURL != nil && selectedDisk != nil
        cancelButton.isHidden = !isCreating
        cancelButton.isEnabled = isCreating && canCancel && cancellation?.isCancelled == false
        cancelButton.title = cancellation?.isCancelled == true ? "Cancelling…" : "Cancel"
        progress.isHidden = !isCreating
        if !isCreating && !hasResult {
            stageLabel.textColor = .labelColor
            percentLabel.stringValue = ""
            setStatusSymbol("circle.dotted", color: .secondaryLabelColor)
            if isoURL == nil {
                stageLabel.stringValue = "Choose your Windows ISO"
                statusDetail.stringValue = "Then select the USB drive you want to use."
            } else if selectedDisk == nil {
                stageLabel.stringValue = "Choose a USB drive"
                statusDetail.stringValue = "Your Mac’s internal drive is never listed."
            } else {
                stageLabel.stringValue = "Ready to create"
                statusDetail.stringValue = "You’ll confirm the disk and approve administrator access first."
                setStatusSymbol("checkmark.circle", color: .controlAccentColor)
            }
        }
    }

    @objc private func confirmCreation(_ sender: Any?) {
        guard !controlsLocked, window.attachedSheet == nil, let iso = isoURL, let target = selectedDisk else { return }
        isConfirming = true
        updateControlState()
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Erase this USB disk?"
        let capacity = ByteCountFormatter.string(fromByteCount: target.size, countStyle: .file)
        alert.informativeText = "\(target.name)\n\(capacity) (\(target.size) bytes)\n/dev/\(target.id)\n\nALL DATA on this physical disk, including every partition, will be permanently erased.\n\nISO: \(iso.lastPathComponent)\n\nAdministrator approval is requested immediately after you confirm, before checking the ISO or formatting this disk. Formatting cannot be interrupted."
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        let erase = alert.addButton(withTitle: "Erase and Create USB")
        erase.keyEquivalent = ""
        erase.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.isConfirming = false
            if response == .alertSecondButtonReturn {
                self.beginCreation(iso: iso, target: target)
            } else {
                self.updateControlState()
            }
        }
    }

    private func beginCreation(iso: URL, target: DiskTarget) {
        let verifyContents = self.verifyContents
        let token = Cancellation()
        cancellation = token
        isCreating = true
        hasResult = false
        canCancel = false
        lastStage = nil
        stageLabel.textColor = .labelColor
        stageLabel.stringValue = "Preparing…"
        statusDetail.stringValue = "Keep the USB connected until creation finishes."
        setStatusSymbol("arrow.triangle.2.circlepath", color: .controlAccentColor)
        percentLabel.stringValue = ""
        progress.isIndeterminate = true
        progress.startAnimation(nil)
        ProcessInfo.processInfo.disableSuddenTermination()
        ProcessInfo.processInfo.disableAutomaticTermination("Creating a Windows USB")
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Creating a Windows installation USB")
        appendLog("\nStarting creation\nISO: \(iso.path)\nUSB: \(target.displayName)\nDo not unplug the disk while work is in progress.")
        appendLog(verifyContents
            ? "Mode: Full Verification (Slower) — source image validation and post-write content verification enabled."
            : "Mode: Fast — full content verification disabled; safety checks, write error checks, flushing, and ejection remain enabled.")
        updateControlState()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<Void, Error>
            do {
                try USBCreator().create(iso: iso, target: target, verifyContents: verifyContents, cancellation: token) { [weak self] event in
                    DispatchQueue.main.async { self?.receive(event) }
                }
                result = .success(())
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { self?.finishCreation(result, token: token, verifyContents: verifyContents) }
        }
    }

    private func receive(_ event: CreationEvent) {
        guard isCreating else { return }
        switch event {
        case .log(let line):
            appendLog(line)
        case .progress(let stage, let fraction, let cancellable):
            canCancel = cancellable
            if stage != lastStage {
                appendLog(stage)
                lastStage = stage
            }
            stageLabel.stringValue = cancellation?.isCancelled == true
                ? "Cancellation requested — waiting for a safe stop…"
                : stage
            stageLabel.toolTip = stageLabel.stringValue
            if let fraction, fraction.isFinite {
                let bounded = min(1, max(0, fraction))
                progress.stopAnimation(nil)
                progress.isIndeterminate = false
                progress.doubleValue = bounded
                percentLabel.stringValue = "\(Int((bounded * 100).rounded()))%"
            } else {
                progress.isIndeterminate = true
                progress.startAnimation(nil)
                percentLabel.stringValue = ""
            }
            updateControlState()
        }
    }

    @objc private func cancelClicked(_ sender: Any?) {
        requestCancellation()
    }

    private func requestCancellation() {
        guard isCreating, canCancel, let cancellation, !cancellation.isCancelled else { return }
        cancellation.cancel()
        canCancel = false
        stageLabel.stringValue = "Cancellation requested — waiting for a safe stop…"
        appendLog("Cancellation requested. Waiting for safe cleanup; formatting is never interrupted. Do not unplug the USB yet.")
        updateControlState()
    }

    private func finishCreation(_ result: Result<Void, Error>, token: Cancellation, verifyContents: Bool) {
        isCreating = false
        hasResult = true
        percentLabel.stringValue = ""
        stageLabel.toolTip = nil
        canCancel = false
        cancellation = nil
        progress.stopAnimation(nil)
        progress.isIndeterminate = false
        if let alert = activeOperationAlert {
            window.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
            activeOperationAlert = nil
        }
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        ProcessInfo.processInfo.enableAutomaticTermination("Creating a Windows USB")
        ProcessInfo.processInfo.enableSuddenTermination()
        switch result {
        case .success where !token.isCancelled:
            stageLabel.stringValue = verifyContents
                ? "Complete — USB verified and ejected"
                : "Complete — USB created and ejected"
            stageLabel.textColor = .labelColor
            statusDetail.stringValue = "You can remove it and install Windows on your PC."
            setStatusSymbol("checkmark.circle.fill", color: .systemGreen)
            appendLog(verifyContents
                ? "SUCCESS: USB contents verified and disk ejected. You can now remove the USB."
                : "SUCCESS: USB created and disk ejected. You can now remove the USB.")
        case .success:
            showCancelled()
        case .failure(let error) where error is CancellationError:
            showCancelled()
        case .failure(let error):
            stageLabel.stringValue = "Creation unsuccessful — USB is not ready"
            stageLabel.textColor = .labelColor
            statusDetail.stringValue = "See the activity log for details before trying again."
            setStatusSymbol("xmark.circle.fill", color: .systemRed)
            appendLog("UNSUCCESSFUL: \(error.localizedDescription)\nThe USB is not ready. If erasure started, its contents may be incomplete. Run creation successfully before using it.")
            showError(title: "Creation unsuccessful — USB not ready", message: "\(error.localizedDescription)\n\nIf erasure started, the USB may be incomplete. Do not use it as installation media until creation completes successfully. See the activity log for details.")
        }
        updateControlState()
    }

    private func showCancelled() {
        stageLabel.stringValue = "Cancelled — USB is not ready"
        stageLabel.textColor = .labelColor
        statusDetail.stringValue = "Eject the USB in Finder before removing it."
        setStatusSymbol("exclamationmark.circle.fill", color: .systemOrange)
        appendLog("CANCELLED: Creation did not complete successfully. The USB may be incomplete; do not use it as installation media. Eject it in Finder before removing it.")
    }

    private func appendLog(_ line: String) {
        guard let storage = logView.textStorage else { return }
        let wasAtBottom = logScroll.documentVisibleRect.maxY >= logView.bounds.maxY - 24
        let text = line.hasSuffix("\n") ? line : line + "\n"
        storage.beginEditing()
        storage.append(NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.textColor
        ]))
        if storage.length > logCharacterLimit {
            let excess = storage.length - logCharacterLimit
            let string = storage.string as NSString
            let nextNewline = string.range(of: "\n", options: [], range: NSRange(location: excess, length: storage.length - excess))
            let hasEarlierNewline = nextNewline.location != NSNotFound && NSMaxRange(nextNewline) < storage.length
            let end = hasEarlierNewline ? NSMaxRange(nextNewline) : excess
            let removal = string.rangeOfComposedCharacterSequences(for: NSRange(location: 0, length: end))
            storage.deleteCharacters(in: removal)
        }
        storage.endEditing()
        if wasAtBottom {
            logView.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
        }
        copyLogsButton.isEnabled = storage.length > 0
    }

    @objc private func copyLogs(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logView.string, forType: .string)
    }

    private func showError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if window.attachedSheet == nil {
            alert.beginSheetModal(for: window)
        } else {
            // The permanent status and log remain visible even if another sheet is open.
            appendLog("\(title): \(message)")
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isCreating {
            explainActiveOperation()
            return false
        }
        return !isConfirming
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isCreating {
            explainActiveOperation()
            return .terminateCancel
        }
        return isConfirming ? .terminateCancel : .terminateNow
    }

    private func explainActiveOperation() {
        window.makeKeyAndOrderFront(nil)
        guard window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "USB creation is still running"
        if canCancel && cancellation?.isCancelled == false {
            alert.informativeText = "Keep WinWriter open until the operation finishes. You can request safe cancellation, but the USB will not be ready. Formatting is never interrupted. Do not unplug the disk while cleanup is running."
            alert.addButton(withTitle: "Keep Working")
            alert.addButton(withTitle: "Cancel Creation")
        } else {
            alert.informativeText = "The current step cannot be interrupted, or safe cancellation is already in progress. WinWriter must stay open until it finishes. Do not unplug the USB disk."
            alert.addButton(withTitle: "Keep Working")
        }
        alert.buttons.first?.keyEquivalent = "\r"
        activeOperationAlert = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.activeOperationAlert = nil
            guard response == .alertSecondButtonReturn else { return }
            // Recheck the latest stage: formatting may have started while the alert was open.
            self.requestCancellation()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        return true
    }

}
