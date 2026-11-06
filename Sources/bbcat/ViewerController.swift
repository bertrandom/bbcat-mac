import AppKit
import UniformTypeIdentifiers

final class ViewerController: NSWindowController, NSWindowDelegate {
    private static let minimumWindowWidth: CGFloat = 560
    private let artworkView = ArtworkView(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)
    private let inspectorView = InfoInspectorView(frame: .zero)
    private let sidebar = FileSidebarController()
    private let splitViewController = NSSplitViewController()
    private var sidebarItem: NSSplitViewItem!
    private let infoPopover = NSPopover()
    private weak var infoButton: NSButton?
    private weak var fitButton: NSButton?
    private var artworkDocument: bbcatDocument?
    private var scale = 1
    private var supportsTwoX = false
    private var fitsToScreenVertically = false
    private static let ninePixelFontKey = "UseNinePixelFont"
    private static let legacyAspectKey = "EmulateLegacyAspect"
    // The View options as currently checked; these alone decide how VGA text is
    // drawn. Opening a file resets them to what its SAUCE asks for, or else to
    // the user's last choice (saved in defaults; both default to on).
    private var ninePixelFont = ViewerController.savedOption(ViewerController.ninePixelFontKey)
    private var legacyAspect = ViewerController.savedOption(ViewerController.legacyAspectKey)

    private static func savedOption(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
    private weak var aspectButton: NSButton?
    private var frameIndex = 0
    private var playbackGeneration = 0

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.title = "bbcat"
        window.minSize = NSSize(width: Self.minimumWindowWidth, height: 240)
        window.center()
        window.delegate = self
        configureContent()
        configureInfoPopover()
        configureToolbar()
        showWelcomeArtwork()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configureContent() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.postsFrameChangedNotifications = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .black
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        artworkView.autoresizingMask = [.width, .height]
        scrollView.documentView = artworkView

        let artworkContainer = NSView()
        artworkContainer.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: artworkContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: artworkContainer.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: artworkContainer.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: artworkContainer.bottomAnchor),
        ])
        let artworkController = NSViewController()
        artworkController.view = artworkContainer

        sidebar.onSelect = { [weak self] url in self?.open(url, resizeWindow: false) }
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 160
        sidebarItem.maximumThickness = 360
        sidebarItem.canCollapse = true
        let contentItem = NSSplitViewItem(viewController: artworkController)
        contentItem.minimumThickness = 240
        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(contentItem)
        splitViewController.view.frame = window?.contentView?.bounds ?? .zero
        sidebar.view.frame.size.width = 220
        window?.contentViewController = splitViewController

        // Re-fit the artwork whenever its pane changes size: window resizes,
        // dragging the divider, or showing/hiding the sidebar.
        NotificationCenter.default.addObserver(
            self, selector: #selector(artworkPaneDidResize),
            name: NSView.frameDidChangeNotification, object: scrollView
        )
    }

    @objc private func artworkPaneDidResize() {
        guard let size = artworkView.image?.size else { return }
        configureLayout(for: size, resizeWindow: false)
    }

    @objc func toggleSidebar(_ sender: Any?) {
        sidebarItem.animator().isCollapsed.toggle()
    }

    private var sidebarWidth: CGFloat {
        sidebarItem.isCollapsed ? 0 : sidebar.view.frame.width + splitViewController.splitView.dividerThickness
    }

    func windowDidBecomeKey(_ notification: Notification) {
        sidebar.refresh()
    }

    private func configureInfoPopover() {
        let popoverSize = NSSize(width: 310, height: 440)
        inspectorView.frame = NSRect(origin: .zero, size: popoverSize)
        let contentController = NSViewController()
        contentController.view = inspectorView
        contentController.preferredContentSize = popoverSize
        infoPopover.contentViewController = contentController
        infoPopover.contentSize = popoverSize
        infoPopover.behavior = .transient
        infoPopover.animates = true
        infoPopover.delegate = self
    }

    private func configureToolbar() {
        let toolbar = NSToolbar(identifier: "bbcatToolbar")
        toolbar.displayMode = .iconOnly
        toolbar.delegate = self
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
    }

    private func showWelcomeArtwork() {
        artworkView.image = try? bbcatWelcome.image(scale: 1)
        artworkView.maximumFitScale = 2
        artworkView.setAccessibilityLabel("Open an artwork to view it")
    }

    func open(_ url: URL, resizeWindow: Bool = true) {
        playbackGeneration &+= 1
        do {
            let loaded = try bbcatDocument(url: url)
            if loaded.hasVGAText {
                ninePixelFont = loaded.sauceSuggestsNinePixelFont ?? Self.savedOption(Self.ninePixelFontKey)
                legacyAspect = loaded.sauceSuggestsLegacyAspect ?? Self.savedOption(Self.legacyAspectKey)
            }
            loaded.setNinePixelFont(ninePixelFont)
            loaded.emulatesLegacyAspect = legacyAspect
            artworkDocument = loaded
            updateScaleControl(for: loaded)
            artworkView.maximumFitScale = nil
            frameIndex = 0
            window?.title = loaded.displayTitle
            try displayFrame(generation: playbackGeneration, resizeWindow: resizeWindow)
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            window?.representedURL = url
            inspectorView.show(document: loaded)
            sidebar.show(fileAt: url)
            updateToolbarItems()
        } catch {
            sidebar.revertSelection(to: artworkDocument?.sourceURL)
            present(error)
        }
    }

    @objc private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Open artwork"
        panel.prompt = "Open"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = FileSidebarController.supportedExtensions.sorted()
            .compactMap { UTType(filenameExtension: $0) }
        panel.beginSheetModal(for: window!) { [weak self] response in
            if response == .OK, let url = panel.url { self?.open(url) }
        }
    }

    @objc private func changeScale(_ sender: NSSegmentedControl) {
        let newScale = sender.selectedSegment + 1
        guard newScale != scale else { return }
        let previousScale = scale
        scale = newScale
        playbackGeneration &+= 1
        frameIndex = 0
        do {
            try displayFrame(generation: playbackGeneration, resizeWindow: true)
        } catch {
            scale = previousScale
            sender.selectedSegment = previousScale - 1
            present(error)
        }
    }

    @objc func toggleNinePixelFont(_ sender: Any?) {
        ninePixelFont.toggle()
        UserDefaults.standard.set(ninePixelFont, forKey: Self.ninePixelFontKey)
        artworkDocument?.setNinePixelFont(ninePixelFont)
        rerenderAfterDisplayOptionChange()
    }

    @objc func toggleLegacyAspect(_ sender: Any?) {
        legacyAspect.toggle()
        UserDefaults.standard.set(legacyAspect, forKey: Self.legacyAspectKey)
        artworkDocument?.emulatesLegacyAspect = legacyAspect
        rerenderAfterDisplayOptionChange()
    }

    private func rerenderAfterDisplayOptionChange() {
        if let artworkDocument {
            updateScaleControl(for: artworkDocument)
            playbackGeneration &+= 1
            frameIndex = 0
            do {
                try displayFrame(generation: playbackGeneration, resizeWindow: true)
            } catch {
                present(error, message: "Could not render artwork")
            }
        }
        updateToolbarItems()
    }

    @objc private func toggleFitToScreen(_ sender: NSButton) {
        guard artworkDocument != nil else {
            sender.state = .off
            return
        }
        fitsToScreenVertically = sender.state == .on
        if let imageSize = artworkView.image?.size {
            configureLayout(for: imageSize, resizeWindow: true)
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        updateToolbarItems()
    }

    @objc func exportArtwork() {
        guard let artworkDocument, let window else { return }
        let type = artworkDocument.isAnimated ? UTType.gif : UTType.png
        let panel = NSSavePanel()
        panel.title = artworkDocument.isAnimated ? "Export Animated GIF" : "Export PNG"
        panel.prompt = "Export"
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = artworkDocument.sourceURL.deletingPathExtension()
            .lastPathComponent + "." + type.preferredFilenameExtension!
        let exportScale = scale
        panel.beginSheetModal(for: window) { [weak self, artworkDocument] response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                let exported = try artworkDocument.export(scale: exportScale)
                try exported.write(to: destination, options: .atomic)
            } catch {
                self?.present(error, message: "Could not export artwork")
            }
        }
    }

    @objc func toggleInspector() {
        guard artworkDocument != nil else { return }
        if infoPopover.isShown {
            infoPopover.performClose(nil)
        } else if let infoButton, infoButton.window != nil,
                  !infoButton.isHiddenOrHasHiddenAncestor, !infoButton.visibleRect.isEmpty {
            infoPopover.show(relativeTo: infoButton.bounds, of: infoButton, preferredEdge: .maxY)
        } else if let contentView = window?.contentView {
            let anchor = NSRect(x: contentView.bounds.maxX - 28, y: contentView.bounds.maxY - 1,
                                width: 1, height: 1)
            infoPopover.show(relativeTo: anchor, of: contentView, preferredEdge: .maxY)
        }
        updateToolbarItems()
    }

    private func updateScaleControl(for document: bbcatDocument?) {
        supportsTwoX = document?.supports(scale: 2) == true
        if !supportsTwoX {
            scale = 1
        }
        guard let toolbar = window?.toolbar else { return }
        for item in toolbar.items where item.itemIdentifier == Self.scaleIdentifier {
            item.isEnabled = supportsTwoX
            if let control = item.view as? NSSegmentedControl {
                configureScaleControl(control)
            }
        }
        updateToolbarItems()
    }

    private func configureScaleControl(_ control: NSSegmentedControl) {
        control.selectedSegment = scale - 1
        control.isEnabled = supportsTwoX
        control.toolTip = switch (artworkDocument, supportsTwoX) {
        case (nil, _): "Open an artwork to change its rendering scale"
        case (_, true): "Rendering scale"
        case (_, false): "2x rendering exceeds the canvas safety limit"
        }
    }

    private func displayFrame(generation: Int, resizeWindow: Bool) throws {
        guard generation == playbackGeneration, let artworkDocument else { return }
        let rendered = try artworkDocument.frame(at: frameIndex, scale: scale)
        artworkView.image = rendered.image
        configureLayout(for: rendered.image.size, resizeWindow: resizeWindow)

        guard artworkDocument.isAnimated else { return }
        let delay = max(rendered.duration, 0.001)
        frameIndex = (frameIndex + 1) % artworkDocument.frameCount
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == self.playbackGeneration else { return }
            do { try self.displayFrame(generation: generation, resizeWindow: false) }
            catch { self.present(error) }
        }
    }

    private func configureLayout(for imageSize: NSSize, resizeWindow: Bool) {
        let visible = window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let chromeWidth = sidebarWidth
        let maxWidth = floor(visible.width * 0.9) - chromeWidth
        let maxHeight = floor(visible.height * 0.9)
        let needsFitWidth = imageSize.width > maxWidth || imageSize.height > maxHeight

        if resizeWindow {
            let contentSize: NSSize
            if fitsToScreenVertically {
                let width = Self.minimumWindowWidth
                let fittedHeight = width * imageSize.height / max(imageSize.width, 1)
                contentSize = NSSize(
                    width: width,
                    height: min(max(ceil(fittedHeight), 200), maxHeight)
                )
            } else {
                contentSize = NSSize(
                    width: min(max(imageSize.width, Self.minimumWindowWidth), maxWidth),
                    height: min(max(imageSize.height, 200), maxHeight)
                )
            }
            window?.setContentSize(NSSize(width: contentSize.width + chromeWidth, height: contentSize.height))
            window?.contentView?.layoutSubtreeIfNeeded()
            window?.center()
        }

        if fitsToScreenVertically {
            configureScreenFitLayout()
        } else if needsFitWidth {
            configureFitWidthLayout(for: imageSize)
            if resizeWindow {
                scrollView.contentView.scroll(to: .zero)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        } else {
            configureScreenFitLayout()
        }
    }

    private func configureScreenFitLayout() {
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        artworkView.fitsImage = true
        artworkView.autoresizingMask = [.width, .height]
        artworkView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
    }

    private func configureFitWidthLayout(for imageSize: NSSize) {
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        artworkView.fitsImage = true
        artworkView.autoresizingMask = []

        let fullViewport = scrollView.contentSize
        let fullWidthHeight = fullViewport.width * imageSize.height / max(imageSize.width, 1)
        scrollView.hasVerticalScroller = fullWidthHeight > fullViewport.height

        // A non-overlay scroller narrows the viewport, so calculate once more using
        // the final content width. The document always matches that width and can
        // therefore only scroll vertically, just like the iOS viewer.
        let viewport = scrollView.contentSize
        let fittedHeight = viewport.width * imageSize.height / max(imageSize.width, 1)
        artworkView.frame = NSRect(
            origin: .zero,
            size: NSSize(width: viewport.width, height: max(ceil(fittedHeight), viewport.height))
        )
    }

    private func updateToolbarItems() {
        guard let toolbar = window?.toolbar else { return }
        for item in toolbar.items {
            switch item.itemIdentifier {
            case Self.exportIdentifier:
                item.isEnabled = artworkDocument != nil
            case Self.infoIdentifier:
                item.isEnabled = artworkDocument != nil
                item.label = infoPopover.isShown ? "Hide Info" : "Show Info"
                item.toolTip = infoPopover.isShown ? "Hide artwork information" : "Show artwork information"
                infoButton?.state = infoPopover.isShown ? .on : .off
                infoButton?.toolTip = item.toolTip
            case Self.aspectIdentifier:
                item.isEnabled = artworkDocument?.hasVGAText ?? true
                aspectButton?.state = legacyAspect ? .on : .off
                aspectButton?.toolTip = legacyAspect
                    ? "Showing legacy aspect (4:3 CRT pixels); click for square pixels"
                    : "Emulate legacy aspect (4:3 CRT pixels)"
                item.toolTip = aspectButton?.toolTip
            case Self.fitIdentifier:
                item.isEnabled = artworkDocument != nil
                fitButton?.state = fitsToScreenVertically ? .on : .off
                fitButton?.toolTip = fitsToScreenVertically
                    ? "Use fit-width scrolling"
                    : "Fit artwork to screen vertically"
            default:
                break
            }
        }
    }

    private func present(_ error: Error, message: String = "Could not open artwork") {
        playbackGeneration &+= 1
        let alert = NSAlert(error: error)
        alert.messageText = message
        if let window { alert.beginSheetModal(for: window) }
    }
}

extension ViewerController: NSToolbarDelegate {
    private static let openIdentifier = NSToolbarItem.Identifier("Open")
    private static let exportIdentifier = NSToolbarItem.Identifier("Export")
    private static let scaleIdentifier = NSToolbarItem.Identifier("Scale")
    private static let infoIdentifier = NSToolbarItem.Identifier("Info")
    private static let fitIdentifier = NSToolbarItem.Identifier("FitScreen")
    private static let aspectIdentifier = NSToolbarItem.Identifier("LegacyAspect")

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, Self.openIdentifier, Self.exportIdentifier, Self.infoIdentifier, Self.fitIdentifier,
         Self.aspectIdentifier, .flexibleSpace, Self.scaleIdentifier]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, Self.openIdentifier, Self.exportIdentifier, Self.infoIdentifier, Self.fitIdentifier,
         Self.aspectIdentifier, .flexibleSpace, Self.scaleIdentifier]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier == .toggleSidebar {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Sidebar"
            item.toolTip = "Show or hide the file sidebar"
            item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Toggle sidebar")
            item.target = self
            item.action = #selector(toggleSidebar(_:))
            item.isBordered = true
            item.visibilityPriority = .high
            return item
        }
        let item = NSToolbarItem(itemIdentifier: identifier)
        if identifier == Self.openIdentifier {
            item.label = "Open"
            item.toolTip = "Open artwork"
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Open")
            item.target = self
            item.action = #selector(chooseFile)
            item.visibilityPriority = .high
        } else if identifier == Self.exportIdentifier {
            item.label = "Export"
            item.toolTip = "Export artwork"
            item.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Export")
            item.target = self
            item.action = #selector(exportArtwork)
            item.isEnabled = artworkDocument != nil
            item.visibilityPriority = .high
        } else if identifier == Self.scaleIdentifier {
            let control = NSSegmentedControl(labels: ["×1", "×2"], trackingMode: .selectOne,
                                             target: self, action: #selector(changeScale(_:)))
            control.setAccessibilityLabel("Rendering scale")
            configureScaleControl(control)
            item.label = "Scale"
            item.view = control
            item.isEnabled = supportsTwoX
            item.visibilityPriority = .low
        } else if identifier == Self.fitIdentifier {
            let button = NSButton(
                image: NSImage(systemSymbolName: "arrow.up.and.down", accessibilityDescription: "Fit artwork vertically")!,
                target: self,
                action: #selector(toggleFitToScreen(_:))
            )
            button.bezelStyle = .toolbar
            button.imagePosition = .imageOnly
            button.setButtonType(.toggle)
            button.setAccessibilityLabel("Fit artwork to screen vertically")
            button.widthAnchor.constraint(equalToConstant: 32).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            fitButton = button
            item.label = "Fit Screen"
            item.toolTip = "Fit artwork to screen vertically"
            item.view = button
            item.isEnabled = artworkDocument != nil
            item.visibilityPriority = .low
        } else if identifier == Self.aspectIdentifier {
            let button = NSButton(
                image: NSImage(systemSymbolName: "tv", accessibilityDescription: "Emulate legacy aspect")!,
                target: self,
                action: #selector(toggleLegacyAspect(_:))
            )
            button.bezelStyle = .toolbar
            button.imagePosition = .imageOnly
            button.setButtonType(.toggle)
            button.state = legacyAspect ? .on : .off
            button.setAccessibilityLabel("Emulate legacy aspect")
            button.widthAnchor.constraint(equalToConstant: 32).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            aspectButton = button
            item.label = "Legacy Aspect"
            item.view = button
            item.visibilityPriority = .low
        } else if identifier == Self.infoIdentifier {
            let button = NSButton(
                image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Artwork information")!,
                target: self,
                action: #selector(toggleInspector)
            )
            button.bezelStyle = .toolbar
            button.imagePosition = .imageOnly
            button.setButtonType(.toggle)
            button.setAccessibilityLabel("Artwork information")
            button.widthAnchor.constraint(equalToConstant: 32).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            infoButton = button
            item.label = "Show Info"
            item.toolTip = "Show artwork information"
            item.view = button
            item.isEnabled = artworkDocument != nil
            item.visibilityPriority = .user
        } else { return nil }
        return item
    }
}

extension ViewerController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(exportArtwork) {
            return artworkDocument != nil
        }
        if menuItem.action == #selector(toggleInspector) {
            menuItem.title = infoPopover.isShown ? "Hide Info" : "Show Info"
            return artworkDocument != nil
        }
        if menuItem.action == #selector(toggleNinePixelFont(_:)) {
            menuItem.state = ninePixelFont ? .on : .off
            return artworkDocument?.hasVGAText ?? true
        }
        if menuItem.action == #selector(toggleLegacyAspect(_:)) {
            menuItem.state = legacyAspect ? .on : .off
            return artworkDocument?.hasVGAText ?? true
        }
        if menuItem.action == #selector(toggleSidebar(_:)) {
            menuItem.title = sidebarItem.isCollapsed ? "Show Sidebar" : "Hide Sidebar"
        }
        return true
    }
}

extension ViewerController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        updateToolbarItems()
    }
}
