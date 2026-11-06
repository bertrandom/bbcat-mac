import AppKit
import CoreServices

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let viewer = ViewerController()
    private let commandLineToolController = CommandLineToolController()
    private var cliMenuItem: NSMenuItem?
    private var aboutWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
        configureMenus()
        viewer.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        let arguments = CommandLine.arguments.dropFirst()
        if let path = arguments.first { viewer.open(URL(fileURLWithPath: path)) }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if let path = filenames.first { viewer.open(URL(fileURLWithPath: path)) }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func configureMenus() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.delegate = self
        appItem.submenu = appMenu
        let about = appMenu.addItem(
            withTitle: "About bbcat",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        about.target = self
        appMenu.addItem(.separator())
        let cliCommand = NSMenuItem()
        cliCommand.target = commandLineToolController
        appMenu.addItem(cliCommand)
        cliMenuItem = cliCommand
        configureCLICommand()
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit bbcat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        let open = fileMenu.addItem(withTitle: "Open…", action: Selector(("chooseFile")), keyEquivalent: "o")
        open.target = viewer
        fileMenu.addItem(.separator())
        let export = fileMenu.addItem(withTitle: "Export…", action: Selector(("exportArtwork")), keyEquivalent: "e")
        export.target = viewer

        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        let info = viewMenu.addItem(withTitle: "Show Info", action: Selector(("toggleInspector")), keyEquivalent: "i")
        info.keyEquivalentModifierMask = [.command, .option]
        info.target = viewer
        let ninePixel = viewMenu.addItem(withTitle: "Use 9px Font", action: #selector(ViewerController.toggleNinePixelFont(_:)), keyEquivalent: "")
        ninePixel.target = viewer
        let aspect = viewMenu.addItem(withTitle: "Emulate Legacy Aspect", action: #selector(ViewerController.toggleLegacyAspect(_:)), keyEquivalent: "")
        aspect.target = viewer
        viewMenu.addItem(.separator())
        let sidebar = viewMenu.addItem(withTitle: "Hide Sidebar", action: #selector(ViewerController.toggleSidebar(_:)), keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.command, .control]
        sidebar.target = viewer
        NSApp.mainMenu = main
    }

    func menuWillOpen(_ menu: NSMenu) {
        configureCLICommand()
    }

    private func configureCLICommand() {
        guard let cliMenuItem else { return }
        if case .installed = CommandLineToolInstaller().state() {
            cliMenuItem.title = "Uninstall CLI…"
            cliMenuItem.action = #selector(CommandLineToolController.uninstall)
        } else {
            cliMenuItem.title = "Install CLI…"
            cliMenuItem.action = #selector(CommandLineToolController.install)
        }
    }

    @objc private func showAbout() {
        if let aboutWindow {
            aboutWindow.makeKeyAndOrderFront(nil)
            return
        }

        let guiVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "unknown"
        let cliVersion = bundledCLIVersion()

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 56),
            icon.heightAnchor.constraint(equalToConstant: 56),
        ])

        let name = NSTextField(labelWithString: "bbcat")
        name.font = .systemFont(ofSize: 19, weight: .bold)

        let subtitle = NSTextField(labelWithString: "ANSI & ASCII art for macOS")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor

        func versionBadge(_ label: String, _ value: String) -> NSView {
            let labelView = NSTextField(labelWithString: label.uppercased())
            labelView.font = .systemFont(ofSize: 10, weight: .semibold)
            labelView.textColor = .tertiaryLabelColor

            let valueView = NSTextField(labelWithString: value)
            valueView.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)

            let badgeContent = NSStackView(views: [labelView, valueView])
            badgeContent.orientation = .horizontal
            badgeContent.alignment = .centerY
            badgeContent.spacing = 7
            badgeContent.translatesAutoresizingMaskIntoConstraints = false

            let badge = NSView()
            badge.wantsLayer = true
            badge.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            badge.layer?.cornerRadius = 8
            badge.layer?.borderWidth = 0.5
            badge.layer?.borderColor = NSColor.separatorColor.cgColor
            badge.addSubview(badgeContent)
            NSLayoutConstraint.activate([
                badgeContent.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 10),
                badgeContent.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -10),
                badgeContent.topAnchor.constraint(equalTo: badge.topAnchor, constant: 7),
                badgeContent.bottomAnchor.constraint(equalTo: badge.bottomAnchor, constant: -7),
            ])
            return badge
        }

        let appBadge = versionBadge("App", "\(guiVersion) (\(buildVersion))")
        let cliBadge = versionBadge("CLI", cliVersion)
        let versions = NSStackView(views: [appBadge, cliBadge])
        versions.orientation = .horizontal
        versions.alignment = .centerY
        versions.spacing = 8

        let website = NSButton(title: "bbcat.dev", target: self, action: #selector(openWebsite))
        website.isBordered = false
        website.contentTintColor = .linkColor
        website.font = .systemFont(ofSize: 13)

        let stack = NSStackView(views: [icon, name, subtitle, website, versions])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.setCustomSpacing(11, after: subtitle)
        stack.setCustomSpacing(13, after: website)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor, constant: -2),
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 215),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "About bbcat"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.center()
        aboutWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func openWebsite() {
        NSWorkspace.shared.open(URL(string: "https://bbcat.dev")!)
    }

    private func bundledCLIVersion() -> String {
        let executable = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/bbcat", isDirectory: false)
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["--version"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            if process.terminationStatus == 0,
               let version = text.split(whereSeparator: { $0.isWhitespace }).last
            {
                return String(version)
            }
        } catch {}

        return "unknown"
    }
}
