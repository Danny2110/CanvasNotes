import AppKit
import UniformTypeIdentifiers

@main
@MainActor
enum NotesyApp {
    static func main() {
        let app = NSApplication.shared
        applyAppearanceOverride()
        setupMainMenu()
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    /// Screenshot hook: `CANVASNOTES_APPEARANCE=dark|light` pins the whole app
    /// to one appearance before any window exists. This is the only place the
    /// app forces an appearance; everything else follows the system.
    private static func applyAppearanceOverride() {
        let requested = ProcessInfo.processInfo.environment["CANVASNOTES_APPEARANCE"]?.lowercased()
        if requested == "dark" {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        } else if requested == "light" {
            NSApp.appearance = NSAppearance(named: .aqua)
        }
    }

    private static func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenu = NSMenu(title: "Notesy")
        appMenu.addItem(NSMenuItem(title: "About Notesy", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Settings...", action: #selector(AppDelegate.openSettingsFromMenu(_:)), keyEquivalent: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide Notesy", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h"))
        if let item = appMenu.items.last { item.keyEquivalentModifierMask = [.command, .option] }
        appMenu.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Notesy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let appMenuItem = NSMenuItem(title: "Notesy", action: nil, keyEquivalent: "")
        mainMenu.addItem(appMenuItem)
        mainMenu.setSubmenu(appMenu, for: appMenuItem)

        // File menu
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(title: "New Note", action: #selector(AppDelegate.newNoteFromMenu(_:)), keyEquivalent: "n"))
        let newCanvasItem = NSMenuItem(title: "New Canvas", action: #selector(AppDelegate.newCanvasFromMenu(_:)), keyEquivalent: "n")
        newCanvasItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(newCanvasItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "Import...", action: #selector(AppDelegate.importFromMenu(_:)), keyEquivalent: "i"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        mainMenu.addItem(fileMenuItem)
        mainMenu.setSubmenu(fileMenu, for: fileMenuItem)

        // Edit menu
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Find", action: #selector(AppDelegate.showFindPanel(_:)), keyEquivalent: "f"))
        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        mainMenu.addItem(editMenuItem)
        mainMenu.setSubmenu(editMenu, for: editMenuItem)

        // View menu
        let viewMenu = NSMenu(title: "View")
        let toggleSidebarItem = NSMenuItem(title: "Toggle Sidebar", action: #selector(AppDelegate.toggleSidebarFromMenu(_:)), keyEquivalent: "s")
        toggleSidebarItem.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(toggleSidebarItem)
        let toggleToolbarItem = NSMenuItem(title: "Toggle Toolbar", action: #selector(AppDelegate.toggleToolbarFromMenu(_:)), keyEquivalent: "t")
        toggleToolbarItem.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(toggleToolbarItem)
        viewMenu.addItem(.separator())
        viewMenu.addItem(NSMenuItem(title: "Zoom In", action: #selector(AppDelegate.zoomInFromMenu(_:)), keyEquivalent: "+"))
        viewMenu.addItem(NSMenuItem(title: "Zoom Out", action: #selector(AppDelegate.zoomOutFromMenu(_:)), keyEquivalent: "-"))
        viewMenu.addItem(NSMenuItem(title: "Actual Size", action: #selector(AppDelegate.actualSizeFromMenu(_:)), keyEquivalent: "0"))
        let viewMenuItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        mainMenu.addItem(viewMenuItem)
        mainMenu.setSubmenu(viewMenu, for: viewMenuItem)

        // Window menu
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        let windowMenuItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        mainMenu.addItem(windowMenuItem)
        mainMenu.setSubmenu(windowMenu, for: windowMenuItem)

        // Help menu
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(NSMenuItem(title: "Notesy Help", action: #selector(AppDelegate.showOnboardingGuide(_:)), keyEquivalent: "?"))
        let helpMenuItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        mainMenu.addItem(helpMenuItem)
        mainMenu.setSubmenu(helpMenu, for: helpMenuItem)

        NSApp.mainMenu = mainMenu

        // Resolve menu actions explicitly. Nil-target items rely on the
        // responder chain, which drops the delegate for this window setup.
        if let delegate = NSApp.delegate {
            for topItem in mainMenu.items {
                guard let submenu = topItem.submenu else { continue }
                for item in submenu.items {
                    if let action = item.action, delegate.responds(to: action) {
                        item.target = delegate
                    }
                }
            }
        }
    }
}

/// Window/titlebar color sampled from the top edge of `AmbientBackdropView(.chrome)`
/// so a transparent titlebar reads as part of the content backdrop in both appearances.
private func chromeBackgroundColor() -> NSColor {
    NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        if isDark {
            return NSColor(srgbRed: 0.153, green: 0.149, blue: 0.157, alpha: 1)
        }
        return NSColor(srgbRed: 0.973, green: 0.965, blue: 0.945, alpha: 1)
    }
}

/// Shared chrome treatment: the titlebar dissolves into the backdrop, with no
/// separator line, so glass bars inside the content own the visible edges.
@MainActor
private func applyGlassChrome(to window: NSWindow) {
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.titlebarSeparatorStyle = .none
    window.backgroundColor = chromeBackgroundColor()
    // Remove the titlebar shadow line
    if let titlebar = window.standardWindowButton(.closeButton)?.superview?.superview {
        titlebar.wantsLayer = true
        titlebar.layer?.backgroundColor = NSColor.clear.cgColor
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private weak var workspace: NotesWorkspaceView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let content = NotesWorkspaceView(frame: NSRect(x: 0, y: 0, width: 1280, height: 820))
        workspace = content
        content.onOpenSettings = { [weak self, weak content] in
            guard let self, let content else { return }
            self.openSettings(for: content)
        }
        let window = NSWindow(contentRect: content.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Notesy"
        applyGlassChrome(to: window)
        window.minSize = NSSize(width: 900, height: 600)
        window.center()
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(content)
        self.window = window
        NSApplication.shared.activate(ignoringOtherApps: true)

        // Show first-run guide if needed
        if !UserDefaults.standard.bool(forKey: "hasSeenGuide") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak content] in
                content?.showWelcomeGuide()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - Menu Actions

    @objc func openSettingsFromMenu(_ sender: Any?) {
        guard let workspace else { return }
        openSettings(for: workspace)
    }

    @objc func newNoteFromMenu(_ sender: Any?) {
        workspace?.newNote()
    }

    @objc func newCanvasFromMenu(_ sender: Any?) {
        workspace?.newCanvas()
    }

    @objc func importFromMenu(_ sender: Any?) {
        workspace?.showImportPanel()
    }

    @objc func showFindPanel(_ sender: Any?) {
        workspace?.showFindPanel()
    }

    @objc func toggleSidebarFromMenu(_ sender: Any?) {
        workspace?.toggleSidebar()
    }

    @objc func toggleToolbarFromMenu(_ sender: Any?) {
        workspace?.toggleToolbar()
    }

    @objc func zoomInFromMenu(_ sender: Any?) {
        workspace?.zoomCanvasIn()
    }

    @objc func zoomOutFromMenu(_ sender: Any?) {
        workspace?.zoomCanvasOut()
    }

    @objc func actualSizeFromMenu(_ sender: Any?) {
        workspace?.actualSizeCanvas()
    }

    @objc func showOnboardingGuide(_ sender: Any?) {
        workspace?.showWelcomeGuide()
    }

    private func openSettings(for workspace: NotesWorkspaceView) {
        if settingsWindow == nil {
            let content = SettingsImportView(frame: NSRect(x: 0, y: 0, width: 480, height: 210))
            content.onImported = { title, body in workspace.importNote(title: title, body: body) }
            let settings = NSWindow(contentRect: content.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            settings.title = "Notesy Settings"
            applyGlassChrome(to: settings)
            settings.contentView = content
            settings.center()
            settingsWindow = settings
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

/// Flipped container inside the glass panel so panel padding reads top-down.
@MainActor
private final class SettingsPanelContentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class SettingsImportView: NSView {
    var onImported: ((String, String) -> Void)?
    override var isFlipped: Bool { true }

    private let backdrop = AmbientBackdropView()
    private let panel = GlassSurfaceView.panel(cornerRadius: 22)
    private let panelContent = SettingsPanelContentView()
    private let heading = NSTextField(labelWithString: "Import from Notes")
    private let descriptionLabel = NSTextField(wrappingLabelWithString: "Export a note from Apple Notes as PDF, RTF, plain text, or HTML, then import it into Notesy.")
    private let importButton = NSButton(title: "Choose Notes Export…", target: nil, action: nil)

    /// Inset between the window edge and the glass panel on every side.
    private let panelInset: CGFloat = 16
    /// Inset between the panel edge and its content.
    private let contentInset: CGFloat = 24

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        backdrop.tone = .chrome
        backdrop.frame = bounds
        backdrop.autoresizingMask = [.width, .height]
        addSubview(backdrop)

        panel.frame = bounds.insetBy(dx: panelInset, dy: panelInset)
        panel.autoresizingMask = [.width, .height]
        addSubview(panel)

        panelContent.autoresizingMask = [.width, .height]
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        heading.textColor = .labelColor
        heading.autoresizingMask = [.width]
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.autoresizingMask = [.width]
        importButton.target = self
        importButton.action = #selector(importNotes)
        // `.glass` bezel draws as bare text when nested inside a glass contentView,
        // so use the standard bezel plus default-action styling instead.
        importButton.bezelStyle = .rounded
        importButton.keyEquivalent = "\r"
        importButton.controlSize = .large
        importButton.autoresizingMask = [.minYMargin]
        [heading, descriptionLabel, importButton].forEach(panelContent.addSubview)
        panel.contentView = panelContent
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override func layout() {
        super.layout()
        backdrop.frame = bounds
        panel.frame = bounds.insetBy(dx: panelInset, dy: panelInset)

        let contentWidth = max(0, panel.bounds.width - contentInset * 2)
        heading.frame = NSRect(x: contentInset, y: 24, width: contentWidth, height: 26)
        descriptionLabel.frame = NSRect(x: contentInset, y: 58, width: contentWidth, height: 48)
        // Grouped directly under the description; no dead space in the panel.
        importButton.frame = NSRect(x: contentInset, y: 118, width: 220, height: 32)
    }

    @objc private func importNotes() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .rtf, .html, .pdf]
        panel.message = "Choose a file exported from Apple Notes"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let body = (try? String(contentsOf: url, encoding: .utf8)) ?? "Imported file: \(url.lastPathComponent)"
        onImported?(url.deletingPathExtension().lastPathComponent, body)
    }
}
