import AppKit

private struct WorkspaceNote: Codable, Identifiable {
    var id: UUID = UUID()
    var title: String
    var body: String
    var folder: String
    var modified: Date = Date()
    var isCanvas = false
    var canvasBlocks: [NoteBlock] = []
    var connections: [NoteConnection] = []
    var attachments: [Attachment] = []

    private enum CodingKeys: String, CodingKey { case id, title, body, folder, modified, isCanvas, canvasBlocks, connections, attachments }

    init(id: UUID = UUID(), title: String, body: String, folder: String, modified: Date = Date(), isCanvas: Bool = false,
         canvasBlocks: [NoteBlock] = [], connections: [NoteConnection] = [], attachments: [Attachment] = []) {
        self.id = id
        self.title = title
        self.body = body
        self.folder = folder
        self.modified = modified
        self.isCanvas = isCanvas
        self.canvasBlocks = canvasBlocks
        self.connections = connections
        self.attachments = attachments
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        body = try values.decode(String.self, forKey: .body)
        folder = try values.decode(String.self, forKey: .folder)
        modified = try values.decodeIfPresent(Date.self, forKey: .modified) ?? Date()
        isCanvas = try values.decodeIfPresent(Bool.self, forKey: .isCanvas) ?? false
        canvasBlocks = try values.decodeIfPresent([NoteBlock].self, forKey: .canvasBlocks) ?? []
        connections = try values.decodeIfPresent([NoteConnection].self, forKey: .connections) ?? []
    }
}

/// File attachment for text notes
struct Attachment: Codable, Identifiable {
    var id: UUID = UUID()
    var fileName: String
    var fileURL: URL?
    var fileData: Data?
    var mimeType: String
    var dateAdded: Date = Date()
    
    init(fileName: String, fileURL: URL? = nil, fileData: Data? = nil, mimeType: String) {
        self.fileName = fileName
        self.fileURL = fileURL
        self.fileData = fileData
        self.mimeType = mimeType
    }
}

/// Three-column, native Notes-style workspace backed by a small local JSON store.
@MainActor
final class NotesWorkspaceView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate, NSTextFieldDelegate {
    var onOpenSettings: (() -> Void)?
    
    private var notes: [WorkspaceNote] = [] { didSet { save() } }
    private var folders: [String] = ["Notes"] { didSet { save() } }
    private var selectedFolder = "Notes"
    private var selectedNoteID: UUID?
    private var canvasViews: [UUID: WorkspaceScrollView] = [:]
    private var canvasControlButtons: [NSButton] = []
    private var query = ""
    private var showsSidebar = true
    private var showsNotesList = true
    private var showsToolbar = true
    private var isUpdatingEditor = false
    /// True only while `load()` is populating the model from disk. `save()` is
    /// a no-op then, otherwise the first `didSet` writes an empty store back
    /// over the file we just read.
    private var isRestoring = false

    /// Ambient gradient behind every piece of chrome; gives the glass something to refract.
    private let backdrop = AmbientBackdropView()
    private lazy var toolbarGlass = GlassSurfaceView.bar(cornerRadius: 22)
    private lazy var sidebarGlass = GlassSurfaceView.panel(cornerRadius: 22)
    private let toolbarContent = NSView()
    private let folderStack = NSStackView()
    private let folderScroll = NSScrollView()
    private let notesTable = NSTableView()
    private let notesScroll = NSScrollView()
    /// Glass note list panel, matching the floating chrome.
    private lazy var listCard = GlassSurfaceView.panel(cornerRadius: 22)
    /// Opaque rounded page behind the title + editor for text notes.
    private let pageCard = RoundedCardView()
    private let editorScroll = NSScrollView()
    private let editor = NSTextView()
    private let titleField = NSTextField(string: "")
    private let searchField = NSSearchField()
    private let folderHeader = NSTextField(labelWithString: "Notes")
    /// Floating glass zoom control over the canvas.
    private let zoomHUD = GlassSurfaceView.control(cornerRadius: 18)
    private let zoomLabel = NSTextField(labelWithString: "100%")
    private var zoomOutButton: NSButton!
    private var zoomInButton: NSButton!
    /// The view inside the HUD's glass, laid out in HUD coordinates.
    private let zoomHUDContent = NSView()
    /// Floating control that stays visible while the toolbar is hidden, so the
    /// bar can always be brought back without hunting through the menu.
    private let toolbarReveal = GlassSurfaceView.control(cornerRadius: 14)
    private let toolbarRevealButton = NSButton()
    private var newNoteButton: NSButton!
    private var listColumnWidth: CGFloat = 242
    /// Guards `selectNote` against re-entry from `selectRowIndexes` while a
    /// text field is finishing its edit.
    private var isSelectingNote = false

    private var visibleNotes: [WorkspaceNote] {        notes.filter { note in
            let inFolder = selectedFolder == "All iCloud" || (selectedFolder == "Canvas" ? note.isCanvas : note.folder == selectedFolder)
            let matches = query.isEmpty || note.title.localizedCaseInsensitiveContains(query) || note.body.localizedCaseInsensitiveContains(query)
            return inFolder && matches
        }.sorted { $0.modified > $1.modified }
    }

    override var isFlipped: Bool { true }
    // Takes focus so the search field does not launch with a focus ring.
    override var acceptsFirstResponder: Bool { true }

    /// Sidebar and list shift left when the sidebar is hidden, so no dead gutter remains.
    /// When notes list is hidden, detail view takes its place.
    private var listX: CGFloat {
        if !showsSidebar && !showsNotesList { return 8 }
        if showsSidebar && !showsNotesList { return 248 }
        return showsSidebar ? 248 : 8
    }
    private var listWidth: CGFloat { showsNotesList ? listColumnWidth : 0 }
    private var detailX: CGFloat { listX + listWidth + (showsNotesList ? 8 : 0) }
    private var detailWidth: CGFloat { max(0, bounds.width - detailX - 8) }
    private var detailFrame: NSRect {
        let detailTop: CGFloat = showsToolbar ? 68 : 12
        return NSRect(x: detailX, y: detailTop, width: detailWidth, height: max(0, bounds.height - detailTop - 8))
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        load()
        backdrop.tone = .chrome
        backdrop.frame = bounds
        backdrop.autoresizingMask = [.width, .height]
        addSubview(backdrop)
        configureToolbar()
        configureSidebar()
        configureNotesList()
        configureEditor()
        configureCanvasHUD()
        [toolbarGlass, sidebarGlass, listCard, pageCard, editorScroll, titleField, zoomHUD].forEach(addSubview)
        rebuildFolderRows()
        notesTable.reloadData()
        if let first = visibleNotes.first { selectNote(first.id) }
        else { showEmptyEditor() }
        
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override func layout() {
        super.layout()
        backdrop.frame = bounds

        // Floating toolbar bar, inset from every window edge so its radius reads.
        let toolbarY: CGFloat = showsToolbar ? 8 : -56
        toolbarGlass.frame = NSRect(x: 10, y: toolbarY, width: max(0, bounds.width - 20), height: 56)
        toolbarGlass.isHidden = !showsToolbar
        toolbarContent.frame = NSRect(origin: .zero, size: toolbarGlass.bounds.size)

        // While the bar is hidden, leave a small pill afloat so it can be restored.
        toolbarReveal.isHidden = showsToolbar
        if !showsToolbar {
            let revealSide: CGFloat = 34
            toolbarReveal.frame = NSRect(x: max(12, bounds.width - revealSide - 16), y: 10,
                                         width: revealSide, height: revealSide)
            addSubview(toolbarReveal, positioned: .above, relativeTo: nil)
        }

        // Floating sidebar panel, inset from the window edges and above the bar's band.
        let sidebarTop: CGFloat = showsToolbar ? 68 : 12
        sidebarGlass.isHidden = !showsSidebar
        sidebarGlass.frame = NSRect(x: 8, y: sidebarTop, width: 232, height: max(0, bounds.height - sidebarTop - 8))
        folderScroll.frame = sidebarGlass.bounds
        folderStack.frame = NSRect(x: 0, y: 0, width: max(0, sidebarGlass.bounds.width),
                                   height: max(sidebarGlass.bounds.height, CGFloat(folderStack.arrangedSubviews.count) * 38 + 24))

        // Notes list panel (middle) - can be hidden
        let listTop: CGFloat = showsToolbar ? 68 : 12
        listCard.isHidden = !showsNotesList
        listCard.frame = NSRect(x: listX, y: listTop, width: listWidth, height: max(0, bounds.height - listTop - 8))
        notesScroll.frame = listCard.bounds
        notesTable.frame = NSRect(origin: .zero, size: notesScroll.contentSize)
        
        // Detail view (right) - expands when list is hidden
        let detailTop: CGFloat = showsToolbar ? 68 : 12
        pageCard.frame = NSRect(x: detailX, y: detailTop, width: detailWidth, height: max(0, bounds.height - detailTop - 8))
        // Title sits on its own band at the top of the page card; the editor
        // starts below it so body text never runs underneath the title.
        let titleTop = detailTop + 24
        let titleHeight: CGFloat = 40
        titleField.frame = NSRect(x: detailX + 48, y: titleTop, width: max(0, detailWidth - 96), height: titleHeight)
        let bodyTop = titleTop + titleHeight + 10
        let bodyHeight = max(0, bounds.height - bodyTop - 8)
        editorScroll.frame = NSRect(x: detailX, y: bodyTop, width: detailWidth, height: bodyHeight)
        editor.frame = NSRect(x: 0, y: 0, width: max(0, editorScroll.contentSize.width - 96), height: max(1000, editorScroll.contentSize.height))
        editor.textContainer?.containerSize = NSSize(width: max(0, editorScroll.contentSize.width - 96), height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        for canvas in canvasViews.values {
            canvas.frame = NSRect(x: detailX, y: detailTop, width: detailWidth, height: max(0, bounds.height - detailTop - 8))
        }
        layoutToolbar()
        layoutHUD()
    }

    func importNote(title: String, body: String) {
        let destinationFolder = selectedFolder == "Canvas" || selectedFolder == "All iCloud" ? "Notes" : selectedFolder
        let note = WorkspaceNote(title: title, body: body, folder: destinationFolder)
        notes.append(note)
        notesTable.reloadData()
        selectNote(note.id)
    }

    private func configureToolbar() {
        toolbarGlass.contentView = toolbarContent

        // Left group: sidebar, new folder, folder header, more
        addGlassToolbarButton("sidebar.left", help: "Show or hide folders", action: #selector(toggleSidebar))
        addGlassToolbarButton("folder.badge.plus", help: "New Folder", action: #selector(newFolder))
        folderHeader.font = .systemFont(ofSize: 15, weight: .semibold)
        toolbarContent.addSubview(folderHeader)
        addGlassToolbarButton("ellipsis", help: "More folder actions", action: #selector(openFolderActions))
        newNoteButton = addGlassToolbarButton("square.and.pencil", help: "New Note", action: #selector(newNote))

        let flexible = NSView()
        toolbarContent.addSubview(flexible)

        // Center group: formatting
        addGlassToolbarButton("textformat", help: "Text formatting", action: #selector(formatMenu))
        addGlassToolbarButton("checklist", help: "Insert checklist item", action: #selector(insertChecklist))
        addGlassToolbarButton("tablecells", help: "Insert table", action: #selector(insertTable))
        addGlassToolbarButton("paperclip", help: "Attach a file", action: #selector(attachFile))

        // Canvas controls
        canvasControlButtons = [
            addGlassToolbarButton("plus.square", help: "Add card to canvas", action: #selector(addCanvasCard)),
            addGlassToolbarButton("point.3.connected.trianglepath.dotted", help: "Connect the two newest cards", action: #selector(connectCanvasCards)),
            addGlassToolbarButton("minus.magnifyingglass", help: "Zoom out", action: #selector(zoomCanvasOut)),
            addGlassToolbarButton("plus.magnifyingglass", help: "Zoom in", action: #selector(zoomCanvasIn))
        ]

        // Right group: share, delete, settings
        addGlassToolbarButton("square.and.arrow.up", help: "Share note", action: #selector(shareNote))
        addGlassToolbarButton("trash", help: "Delete note", action: #selector(deleteSelectedNote))
        addGlassToolbarButton("menubar.rectangle", help: "Show or hide toolbar", action: #selector(toggleToolbar))
        addGlassToolbarButton("gearshape", help: "Settings", action: #selector(showSettings))

        searchField.placeholderString = "Search"
        searchField.target = self
        searchField.action = #selector(searchChanged)
        toolbarContent.addSubview(searchField)

        // Always-available restore control for a hidden toolbar.
        toolbarReveal.isInteractive = true
        toolbarReveal.style = .clear
        toolbarRevealButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Show toolbar")
        toolbarRevealButton.bezelStyle = .circular
        toolbarRevealButton.isBordered = false
        toolbarRevealButton.imageScaling = .scaleProportionallyDown
        toolbarRevealButton.contentTintColor = .labelColor
        toolbarRevealButton.toolTip = "Show toolbar (⌥⌘T)"
        toolbarRevealButton.target = self
        toolbarRevealButton.action = #selector(toggleToolbar)
        toolbarRevealButton.frame = NSRect(x: 0, y: 0, width: 34, height: 34)
        toolbarReveal.contentView = toolbarRevealButton
        toolbarReveal.isHidden = true
        addSubview(toolbarReveal)
    }

    @discardableResult
    private func addGlassToolbarButton(_ symbol: String, help: String, action: Selector) -> NSButton {
        // Create a glass surface for the button
        let glass = GlassSurfaceView.control(cornerRadius: 12)
        glass.isInteractive = true
        glass.style = .clear
        toolbarContent.addSubview(glass)

        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: help) ?? NSImage(), target: self, action: action)
        button.bezelStyle = .circular
        button.isBordered = false
        button.cell?.backgroundStyle = .raised
        button.toolTip = help
        button.contentTintColor = .labelColor
        button.imageScaling = .scaleProportionallyDown
        glass.contentView = button

        // Set fixed size for glass and button - layoutToolbar will position them.
        // The button fills the whole glass so the entire circle is clickable.
        glass.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        button.frame = NSRect(x: 0, y: 0, width: 40, height: 40)

        return button
    }

    /// Lays out inside the glass bar's own bounds using Auto Layout for glass buttons.
    private func layoutToolbar() {
        let bar = toolbarGlass.frame
        // One deterministic left-to-right pass. The old version anchored the
        // center group, the right group and the canvas controls all from the
        // right edge, so the canvas controls landed exactly on top of
        // Share / Trash / Menu / Gear.
        let side: CGFloat = 40
        let gap: CGFloat = 6
        let buttonY = (bar.height - side) / 2

        let allGlass = toolbarContent.subviews.compactMap { $0 as? GlassSurfaceView }
        let leftGlass = Array(allGlass.prefix(3))
        let newNoteGlass = newNoteButton.superview as? GlassSurfaceView
        let canvasGlass = canvasControlButtons.compactMap { $0.superview as? GlassSurfaceView }
        let canvasSet = Set(canvasGlass)
        let otherGlass = allGlass.filter { !leftGlass.contains($0) && $0 !== newNoteGlass && !canvasSet.contains($0) }
        let centerGlass = Array(otherGlass.prefix(4))
        let rightGlass = Array(otherGlass.dropFirst(4))

        let searchWidth: CGFloat = min(280, max(180, bounds.width * 0.18))
        searchField.frame = NSRect(x: bar.width - searchWidth - 14, y: (bar.height - 36) / 2,
                                   width: searchWidth, height: 36)

        // Right edge -> left: search, right group, canvas controls, center group.
        var x = searchField.frame.minX - gap
        for glass in rightGlass.reversed() {
            x -= side
            glass.frame = NSRect(x: x, y: buttonY, width: side, height: side)
            x -= gap
        }
        for glass in canvasGlass.reversed() {
            x -= side
            glass.frame = NSRect(x: x, y: buttonY, width: side, height: side)
            x -= gap
        }
        let centerEndX = x
        for glass in centerGlass.reversed() {
            x -= side
            glass.frame = NSRect(x: x, y: buttonY, width: side, height: side)
            x -= gap
        }

        // Left edge -> right: sidebar, new folder, ellipsis, folder header, new note.
        var lx: CGFloat = 18 - bar.minX
        for glass in leftGlass {
            glass.frame = NSRect(x: lx, y: buttonY, width: side, height: side)
            lx += side + gap
        }
        folderHeader.frame = NSRect(x: lx + 2, y: (bar.height - 24) / 2, width: 150, height: 24)
        lx += 150 + gap
        if let newNoteGlass {
            newNoteGlass.frame = NSRect(x: lx, y: buttonY, width: side, height: side)
            lx += side + gap
        }

        let flexible = toolbarContent.subviews.first(where: { !($0 is GlassSurfaceView) && $0 !== folderHeader && $0 !== searchField })
        if let flexible {
            flexible.frame = NSRect(x: lx + 8, y: 0, width: max(8, centerEndX - lx - 16), height: 1)
        }
    }

    private func configureSidebar() {
        folderScroll.drawsBackground = false
        folderScroll.hasVerticalScroller = true
        folderScroll.autoresizingMask = [.width, .height]
        folderStack.orientation = .vertical
        folderStack.alignment = .leading
        folderStack.spacing = 4
        folderStack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 12, right: 10)
        folderScroll.documentView = folderStack
        sidebarGlass.contentView = folderScroll
        folderHeader.stringValue = selectedFolder
    }

    private func configureNotesList() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("note"))
        column.title = "Notes"
        column.width = listColumnWidth
        notesTable.addTableColumn(column)
        notesTable.headerView = nil
        notesTable.rowHeight = 72
        notesTable.dataSource = self
        notesTable.delegate = self
        notesTable.selectionHighlightStyle = .none
        notesTable.backgroundColor = .clear
        notesTable.gridColor = NSColor.clear
        notesTable.usesAlternatingRowBackgroundColors = false
        notesTable.intercellSpacing = NSSize(width: 0, height: 0)
        notesScroll.documentView = notesTable
        notesScroll.hasVerticalScroller = true
        notesScroll.drawsBackground = false
        notesScroll.backgroundColor = .clear
        notesScroll.autoresizingMask = [.width, .height]
        listCard.contentView = notesScroll
        listCard.style = .clear
    }

    private func configureEditor() {
        titleField.font = .systemFont(ofSize: 26, weight: .bold)
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.delegate = self
        titleField.placeholderString = "Title"
        editor.isRichText = true
        editor.allowsUndo = true
        editor.font = .systemFont(ofSize: 15)
        editor.textColor = .labelColor
        editor.textContainerInset = NSSize(width: 48, height: 8)
        editor.delegate = self
        editorScroll.documentView = editor
        editorScroll.hasVerticalScroller = true
        editorScroll.drawsBackground = false
        pageCard.cornerRadius = 14
        pageCard.fillColor = .textBackgroundColor
        pageCard.borderColor = .separatorColor
    }

    /// Floating glass control over the canvas: zoom out, percentage, zoom in.
    private func configureCanvasHUD() {
        zoomHUDContent.autoresizingMask = [.width, .height]
        zoomLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        zoomLabel.textColor = .labelColor
        zoomLabel.alignment = .center
        zoomLabel.isBordered = false
        zoomLabel.drawsBackground = false
        zoomOutButton = NSButton(image: NSImage(systemSymbolName: "minus.magnifyingglass", accessibilityDescription: "Zoom out") ?? NSImage(),
                                 target: self, action: #selector(zoomCanvasOut))
        zoomOutButton.bezelStyle = .circular
        zoomOutButton.isBordered = true
        zoomOutButton.contentTintColor = .labelColor
        zoomInButton = NSButton(image: NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: "Zoom in") ?? NSImage(),
                                target: self, action: #selector(zoomCanvasIn))
        zoomInButton.bezelStyle = .circular
        zoomInButton.isBordered = true
        zoomInButton.contentTintColor = .labelColor
        [zoomOutButton, zoomLabel, zoomInButton].forEach(zoomHUDContent.addSubview)
        zoomHUD.contentView = zoomHUDContent
        zoomHUD.isHidden = true
    }

    private func layoutHUD() {
        let hudWidth: CGFloat = 200
        let hudHeight: CGFloat = 48
        // Position relative to canvas area (detailFrame), not window bounds
        let canvasFrame = detailFrame
        zoomHUD.frame = NSRect(x: canvasFrame.maxX - hudWidth - 12, 
                                y: canvasFrame.maxY - hudHeight - 12, 
                                width: hudWidth, height: hudHeight)
        zoomHUDContent.frame = zoomHUD.bounds
        let side: CGFloat = 42
        zoomOutButton.frame = NSRect(x: 4, y: 3, width: side, height: side)
        zoomInButton.frame = NSRect(x: zoomHUD.bounds.width - side - 4, y: 3, width: side, height: side)
        zoomLabel.frame = NSRect(x: side + 4, y: 3, width: zoomHUD.bounds.width - side * 2 - 8, height: side)
    }

    private func rebuildFolderRows() {
        folderStack.setViews([], in: .top)
        addFolderRow("Quick Notes", symbol: "bolt.fill", count: nil, folder: "Quick Notes")
        addFolderRow("All iCloud", symbol: "folder", count: nil, folder: "All iCloud")
        addFolderRow("Notes", symbol: "folder", count: nil, folder: "Notes")
        for folder in folders where !["Notes", "Quick Notes"].contains(folder) {
            addFolderRow(folder, symbol: "folder", count: nil, folder: folder)
        }
        addFolderRow("Canvas", symbol: "scribble.variable", count: nil, folder: "Canvas")
    }

    private func addFolderRow(_ title: String, symbol: String, count: Int?, folder: String) {
        let isSelected = folder == selectedFolder
        
        // Create glass surface for the folder row
        let glass = GlassSurfaceView.control(cornerRadius: 12)
        glass.isInteractive = true
        glass.style = .clear
        glass.translatesAutoresizingMaskIntoConstraints = false
        folderStack.addArrangedSubview(glass)
        
        let button = NSButton(title: title, target: self, action: #selector(folderSelected(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(folder)
        button.isBordered = false
        button.alignment = .left
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.font = .systemFont(ofSize: 13, weight: isSelected ? .semibold : .regular)
        button.contentTintColor = isSelected ? NSColor(srgbRed: 0.98, green: 0.72, blue: 0.32, alpha: 1) : .labelColor
        button.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView = button
        
        // Selection pill with cozy warm color inside the glass
        let cozyColor = NSColor(srgbRed: 0.98, green: 0.72, blue: 0.32, alpha: 1)
        if isSelected {
            let pill = NSView()
            pill.wantsLayer = true
            pill.layer?.backgroundColor = cozyColor.withAlphaComponent(0.3).cgColor
            pill.layer?.cornerRadius = 8
            pill.translatesAutoresizingMaskIntoConstraints = false
            glass.addSubview(pill, positioned: .below, relativeTo: button)
            NSLayoutConstraint.activate([
                pill.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: 4),
                pill.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -4),
                pill.topAnchor.constraint(equalTo: glass.topAnchor, constant: 2),
                pill.bottomAnchor.constraint(equalTo: glass.bottomAnchor, constant: -2)
            ])
        }
        
        NSLayoutConstraint.activate([
            glass.widthAnchor.constraint(equalToConstant: 212),
            glass.heightAnchor.constraint(equalToConstant: 36),
            button.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: 12),
            button.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -12),
            button.centerYAnchor.constraint(equalTo: glass.centerYAnchor),
        ])
    }

    @objc private func folderSelected(_ sender: NSButton) {
        guard let folder = sender.identifier?.rawValue else { return }
        selectedFolder = folder
        folderHeader.stringValue = folder
        rebuildFolderRows()
        notesTable.reloadData()
        if let first = visibleNotes.first { selectNote(first.id) } else { showEmptyEditor() }
    }


    @objc private func newFolder() {
        let alert = NSAlert()
        alert.messageText = "New Folder"
        alert.informativeText = "Choose a name for this folder."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.placeholderString = "Folder name"
        alert.accessoryView = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !folders.contains(name) else { return }
        folders.append(name)
        selectedFolder = name
        folderHeader.stringValue = name
        rebuildFolderRows()
        notesTable.reloadData()
        showEmptyEditor()
    }

    @objc private func openFolderActions() {
        let menu = NSMenu()
        let rename = NSMenuItem(title: "Rename Folder…", action: #selector(renameSelectedFolder), keyEquivalent: "")
        rename.target = self
        menu.addItem(rename)
        let remove = NSMenuItem(title: "Delete Folder", action: #selector(deleteSelectedFolder), keyEquivalent: "")
        remove.target = self
        remove.isEnabled = selectedFolder != "Notes" && selectedFolder != "Quick Notes" && selectedFolder != "All iCloud" && selectedFolder != "Canvas"
        menu.addItem(remove)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: toolbarContent)
    }

    @objc private func renameSelectedFolder() {
        guard let index = folders.firstIndex(of: selectedFolder) else { return }
        promptForFolderName(initial: selectedFolder) { [weak self] name in
            guard let self, let name, !name.isEmpty else { return }
            let old = self.folders[index]
            self.folders[index] = name
            self.notes = self.notes.map { note in var copy = note; if copy.folder == old { copy.folder = name }; return copy }
            self.selectedFolder = name
            self.folderHeader.stringValue = name
            self.rebuildFolderRows()
            self.notesTable.reloadData()
        }
    }

    @objc private func deleteSelectedFolder() {
        guard let index = folders.firstIndex(of: selectedFolder), selectedFolder != "Notes" else { return }
        let deleted = folders.remove(at: index)
        notes = notes.map { note in var copy = note; if copy.folder == deleted { copy.folder = "Notes" }; return copy }
        selectedFolder = "Notes"
        folderHeader.stringValue = selectedFolder
        rebuildFolderRows()
        notesTable.reloadData()
    }

    private func promptForFolderName(initial: String, completion: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Rename Folder"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        completion(alert.runModal() == .alertFirstButtonReturn ? field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
    }

    @objc func newNote() {
        let menu = NSMenu()
        let normal = NSMenuItem(title: "New Note", action: #selector(createNormalNote), keyEquivalent: "")
        normal.target = self
        menu.addItem(normal)
        let canvas = NSMenuItem(title: "New Canvas Note", action: #selector(createCanvasNote), keyEquivalent: "")
        canvas.target = self
        menu.addItem(canvas)
        let point = NSPoint(x: newNoteButton.frame.midX, y: newNoteButton.frame.minY)
        menu.popUp(positioning: nil, at: point, in: toolbarContent)
    }

    @objc private func createNormalNote() { createNote() }

    func createNote() {
        if selectedFolder == "All iCloud" || selectedFolder == "Canvas" { selectedFolder = "Notes"; folderHeader.stringValue = selectedFolder }
        let note = WorkspaceNote(title: "New Note", body: "", folder: selectedFolder)
        notes.append(note)
        notesTable.reloadData()
        selectNote(note.id)
        window?.makeFirstResponder(editor)
    }

    @objc private func createCanvasNote() {
        if selectedFolder == "All iCloud" || selectedFolder == "Canvas" {
            selectedFolder = "Notes"
            folderHeader.stringValue = selectedFolder
            rebuildFolderRows()
        }
        let note = WorkspaceNote(title: "New Canvas", body: "", folder: selectedFolder, isCanvas: true)
        notes.append(note)
        notesTable.reloadData()
        selectNote(note.id)
    }

    @objc private func searchChanged() {
        query = searchField.stringValue
        notesTable.reloadData()
        if let first = visibleNotes.first { selectNote(first.id) } else { showEmptyEditor() }
    }

    @objc private func insertChecklist() { insertAtCursor("☐ ") }
    @objc private func insertTable() { insertAtCursor("\nColumn 1\tColumn 2\n────────\t────────\n") }

    @objc private func formatMenu() {
        let menu = NSMenu()
        for (title, size, weight) in [("Title", CGFloat(24), NSFont.Weight.bold), ("Heading", CGFloat(18), .semibold), ("Body", CGFloat(15), .regular), ("Monospaced", CGFloat(14), .regular)] {
            let item = NSMenuItem(title: title, action: #selector(applyFormat(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ["size": size, "weight": weight.rawValue] as [String: Any]
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: toolbarContent)
    }

    @objc private func applyFormat(_ sender: NSMenuItem) {
        guard let values = sender.representedObject as? [String: Any], let size = values["size"] as? CGFloat,
              let weightValue = values["weight"] as? CGFloat else { return }
        let weight = NSFont.Weight(rawValue: weightValue)
        let font = sender.title == "Monospaced" ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        let range = editor.selectedRange()
        let text = editor.string as NSString
        let target = range.length == 0 ? NSRange(location: 0, length: text.length) : range
        editor.textStorage?.addAttribute(.font, value: font, range: target)
        textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
    }

    private func insertAtCursor(_ string: String) {
        if selectedNoteID == nil { newNote() }
        editor.insertText(string, replacementRange: editor.selectedRange())
        window?.makeFirstResponder(editor)
    }

    @objc private func attachFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .pdf, .plainText, .rtf, .rtfd, .html, .jpeg, .png, .tiff, .gif, .bmp]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        
        guard let note = selectedNote else { return }
        
        if note.isCanvas {
            // For canvas: create a card with the image/file
            guard let canvas = canvasViews[note.id]?.canvasView else { return }
            let visible = canvas.visibleRect
            let box = canvas.addBox(frame: NSRect(x: visible.midX - 140, y: visible.midY - 95, width: 280, height: 190), title: url.deletingPathExtension().lastPathComponent)
            if let image = NSImage(contentsOf: url) {
                box.displayImage(image, sourceURL: url)
            }
            box.noteBody = "Attachment: \(url.lastPathComponent)"
        } else {
            // For text notes: add to attachments array and insert reference
            if let index = notes.firstIndex(where: { $0.id == note.id }) {
                let mimeType = mimeTypeForURL(url)
                let attachment = Attachment(fileName: url.lastPathComponent, fileURL: url, mimeType: mimeType)
                notes[index].attachments.append(attachment)
                insertAtCursor("\n[Attachment: \(url.lastPathComponent)]\n")
            }
        }
    }
    
    private func mimeTypeForURL(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "tiff", "tif": return "image/tiff"
        case "bmp": return "image/bmp"
        case "pdf": return "application/pdf"
        case "txt": return "text/plain"
        case "rtf": return "application/rtf"
        case "html", "htm": return "text/html"
        default: return "application/octet-stream"
        }
    }

    @objc private func shareNote() {
        guard let note = selectedNote else { return }
        let picker = NSSharingServicePicker(items: ["\(note.title)\n\n\(note.body)"])
        picker.show(relativeTo: NSRect(x: bounds.maxX - 100, y: 0, width: 1, height: 1), of: self, preferredEdge: .minY)
    }

    @objc private func deleteSelectedNote() {
        guard let selectedNoteID else { return }
        canvasViews.removeValue(forKey: selectedNoteID)?.removeFromSuperview()
        notes.removeAll { $0.id == selectedNoteID }
        self.selectedNoteID = nil
        notesTable.reloadData()
        if let first = visibleNotes.first { selectNote(first.id) } else { showEmptyEditor() }
    }

    @objc private func showSettings() { onOpenSettings?() }

    @objc private func addCanvasCard() {
        guard let canvas = selectedNote.flatMap({ canvasViews[$0.id] }) else { return }
        let visible = canvas.canvasView.visibleRect
        let offset = CGFloat(canvas.canvasView.cards.count % 7) * 28
        _ = canvas.canvasView.addBox(frame: NSRect(x: visible.midX - 140 + offset, y: visible.midY - 95 + offset, width: 280, height: 190), title: "New card")
    }

    @objc private func connectCanvasCards() {
        guard let canvas = selectedNote.flatMap({ canvasViews[$0.id] }), !canvas.canvasView.connectMostRecentBoxes(type: .directional) else { return }
        NSSound.beep()
    }


    private var selectedNote: WorkspaceNote? { notes.first { $0.id == selectedNoteID } }

    private func canvasView(for note: WorkspaceNote) -> WorkspaceScrollView {
        if let existing = canvasViews[note.id] { return existing }
        let scroll = WorkspaceScrollView(frame: detailFrame)
        // Float the canvas as a rounded sheet on the desk, like the other surfaces.
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 14
        scroll.layer?.masksToBounds = true
        scroll.layer?.borderWidth = 0.5
        scroll.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.7).cgColor
        scroll.canvasView.restore(blocks: note.canvasBlocks, connections: note.connections)
        if note.canvasBlocks.isEmpty {
            let box = scroll.canvasView.addBox(frame: NSRect(x: 420, y: 320, width: 320, height: 240), title: note.title)
            box.noteBody = note.body
        }
        canvasViews[note.id] = scroll
        scroll.canvasView.onCanvasChanged = { [weak self] in self?.saveCanvas(id: note.id) }
        scroll.frame = detailFrame
        scroll.isHidden = true
        addSubview(scroll)
        return scroll
    }

    private func saveCanvas(id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }), let canvas = canvasViews[id]?.canvasView else { return }
        notes[index].canvasBlocks = canvas.exportBlocks()
        notes[index].connections = canvas.connections
        notes[index].modified = Date()
    }

    private func selectNote(_ id: UUID) {
        guard !isSelectingNote else { return }
        isSelectingNote = true
        defer { isSelectingNote = false }
        selectedNoteID = id
        if let index = visibleNotes.firstIndex(where: { $0.id == id }) { notesTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        guard let note = selectedNote else { showEmptyEditor(); return }
        isUpdatingEditor = true
        titleField.stringValue = note.title
        editor.string = note.body
        isUpdatingEditor = false
        for button in canvasControlButtons { button.isHidden = !note.isCanvas }
        if note.isCanvas {
            let selectedCanvas = canvasView(for: note)
            for (canvasID, view) in canvasViews { view.isHidden = canvasID != id }
            pageCard.isHidden = true
            titleField.isHidden = false
            editorScroll.isHidden = true
            selectedCanvas.isHidden = false
            zoomHUD.isHidden = false
            // Canvas scroll views are added after the HUD, so re-raise it above
            // whichever canvas is on screen; otherwise the HUD is painted under it.
            addSubview(zoomHUD, positioned: .above, relativeTo: nil)
            layoutHUD()
        } else {
            for canvas in canvasViews.values { canvas.isHidden = true }
            pageCard.isHidden = false
            titleField.isHidden = false
            editorScroll.isHidden = false
            zoomHUD.isHidden = true
            zoomHUD.removeFromSuperview()
        }
    }

    private func showEmptyEditor() {
        
        selectedNoteID = nil
        titleField.stringValue = ""
        editor.string = ""
        pageCard.isHidden = true
        titleField.isHidden = true
        editorScroll.isHidden = true
        zoomHUD.isHidden = true
        for button in canvasControlButtons { button.isHidden = true }
        for canvas in canvasViews.values { canvas.isHidden = true }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleNotes.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visibleNotes.indices.contains(row) else { return nil }
        let note = visibleNotes[row]
        let cell = NSTableCellView()
        let heading = NSTextField(labelWithString: note.title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.textColor = .labelColor
        let date = NSTextField(labelWithString: note.modified.formatted(date: .abbreviated, time: .shortened))
        date.font = .systemFont(ofSize: 11)
        date.textColor = .secondaryLabelColor
        let previewText = note.isCanvas ? "Canvas · \(note.canvasBlocks.count) cards" : note.body.replacingOccurrences(of: "\n", with: " ")
        let preview = NSTextField(labelWithString: previewText)
        preview.font = .systemFont(ofSize: 11)
        preview.textColor = .secondaryLabelColor
        preview.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [heading, date, preview])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.frame = NSRect(x: 12, y: 9, width: listColumnWidth - 24, height: 54)
        cell.addSubview(stack)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard notesTable.selectedRow >= 0, visibleNotes.indices.contains(notesTable.selectedRow) else { return }
        selectNote(visibleNotes[notesTable.selectedRow].id)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        return CozyTableRowView()
    }

    func textDidChange(_ notification: Notification) {
        guard !isUpdatingEditor, let id = selectedNoteID, let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].body = editor.string
        notes[index].modified = Date()
    }

    func textDidEndEditing(_ notification: Notification) {
        // Ending an edit is delivered while AppKit is still tearing down the
        // field editor. Rebuilding the note UI synchronously here can reach a
        // half-destroyed editor (the ⌘. crash), so hop to the next turn.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.notesTable.reloadData()
            if let id = self.selectedNoteID { self.selectNote(id) }
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard !isUpdatingEditor, let id = selectedNoteID, let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].title = titleField.stringValue
        notes[index].modified = Date()
        if notes[index].isCanvas, let firstCard = canvasViews[id]?.canvasView.cards.first?.1 {
            firstCard.title = titleField.stringValue
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.notesTable.reloadData()
            if let id = self.selectedNoteID { self.selectNote(id) }
        }
    }

    /// ⌘. is AppKit's cancel. Without an override it falls through to the
    /// default responder while the inline editor is live; end the edit on the
    /// next turn instead so the field editor is never rebuilt mid-teardown.
    override func cancelOperation(_ sender: Any?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.window?.firstResponder is NSTextView {
                self.window?.makeFirstResponder(nil)
            }
        }
    }


    private var storeURL: URL {
        // Use iCloud Drive Documents folder directly: ~/Library/Mobile Documents/com~apple~CloudDocs/Documents/Notesy/
        let icloudBase = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Documents/Notesy", isDirectory: true)
        let localBase = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notesy", isDirectory: true)
        // Prefer iCloud Drive if it exists, otherwise local
        let useURL = FileManager.default.fileExists(atPath: icloudBase.path) ? icloudBase : localBase
        try? FileManager.default.createDirectory(at: useURL, withIntermediateDirectories: true)
        return useURL.appendingPathComponent("Notes.json")
    }

    private func load() {
        isRestoring = true
        defer { isRestoring = false }
        if let data = try? Data(contentsOf: storeURL), let saved = try? JSONDecoder().decode(SavedNotes.self, from: data) {
            notes = saved.notes
            folders = saved.folders
        } else {
            // First run under the new name: pull in the user's notes from the
            // previous app's store so nothing is lost on the rename.
            if let migrated = migrateFromOldStore(), migrated.notes.count > 0 {
                notes = migrated.notes
                folders = migrated.folders
            } else {
                notes = [
                    WorkspaceNote(title: "Welcome to Notesy", body: "Your notes live here. Create folders, write freely, and switch to Canvas when you want to arrange ideas spatially.", folder: "Notes"),
                    WorkspaceNote(title: "A note can be more than text", body: "Use the toolbar to add checklist items, tables, and attachments. Your edits save automatically on this Mac.", folder: "Notes")
                ]
            }
        }
    }

    /// Migration: check old storage locations (both iCloud/Documents CanvasNotes and Application Support CanvasNotes).
    private func migrateFromOldStore() -> SavedNotes? {
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Documents/CanvasNotes/Notes.json"),
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CanvasNotes/Notes.json"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/CanvasNotes/Notes.json")
        ]
        for oldURL in candidates {
            guard let data = try? Data(contentsOf: oldURL),
                  let saved = try? JSONDecoder().decode(SavedNotes.self, from: data),
                  saved.notes.count > 0 else { continue }
            let encoded = try? JSONEncoder().encode(saved)
            try? encoded?.write(to: storeURL, options: .atomic)
            return saved
        }
        return nil
    }

    private func save() {
        guard !isRestoring, isViewLoaded else { return }
        let data = try? JSONEncoder().encode(SavedNotes(notes: notes, folders: folders))
        try? data?.write(to: storeURL, options: .atomic)
    }

    /// True once this view is actually inside a window. Before that, `save()`
    /// would write an empty store back over the file we just loaded.
    private var isViewLoaded: Bool { window != nil }

    // MARK: - Public menu actions

    func newCanvas() {
        if selectedFolder == "All iCloud" || selectedFolder == "Canvas" {
            selectedFolder = "Notes"
            folderHeader.stringValue = selectedFolder
            rebuildFolderRows()
        }
        let note = WorkspaceNote(title: "New Canvas", body: "", folder: selectedFolder, isCanvas: true)
        notes.append(note)
        notesTable.reloadData()
        selectNote(note.id)
    }

    @objc func showImportPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .rtf, .html, .pdf]
        panel.message = "Choose a file exported from Apple Notes"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let body = (try? String(contentsOf: url, encoding: .utf8)) ?? "Imported file: \(url.lastPathComponent)"
        importNote(title: url.deletingPathExtension().lastPathComponent, body: body)
    }

    @objc func showFindPanel() {
        window?.makeFirstResponder(searchField)
    }

    @objc func toggleSidebar() {
        showsSidebar.toggle()
        animateLayout()
    }

    @objc func toggleNotesList() {
        showsNotesList.toggle()
        animateLayout()
    }

    @objc func toggleToolbar() {
        showsToolbar.toggle()
        animateLayout()
    }

    private func animateLayout() {
        // Toggling a flag does not mark the view dirty, so ask for a layout pass
        // explicitly; otherwise the frames never update and the buttons look dead.
        needsLayout = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            layoutSubtreeIfNeeded()
        }
    }

    @objc func zoomCanvasIn() {
        guard let canvas = selectedNote.flatMap({ canvasViews[$0.id] }) else { return }
        canvas.setZoomScale(canvas.zoomScale * 1.15)
        zoomLabel.stringValue = "\(Int(canvas.zoomScale * 100))%"
    }

    @objc func zoomCanvasOut() {
        guard let canvas = selectedNote.flatMap({ canvasViews[$0.id] }) else { return }
        canvas.setZoomScale(canvas.zoomScale / 1.15)
        zoomLabel.stringValue = "\(Int(canvas.zoomScale * 100))%"
    }

    @objc func actualSizeCanvas() {
        guard let canvas = selectedNote.flatMap({ canvasViews[$0.id] }) else { return }
        canvas.setZoomScale(1.0)
        zoomLabel.stringValue = "100%"
    }

    func showWelcomeGuide() {
        // The launch guide and Help > Notesy Help can both fire; never stack
        // two overlays, or the two text layers draw on top of each other.
        for case let existing as OnboardingGuideView in subviews {
            existing.removeFromSuperview()
        }
        let guide = OnboardingGuideView(frame: bounds)
        guide.autoresizingMask = [.width, .height]
        addSubview(guide, positioned: .above, relativeTo: nil)
        guide.frame = bounds
        guide.start()
    }
}

/// Custom row view with cozy warm selection
private class CozyTableRowView: NSTableRowView {
    private let cozyColor = NSColor(srgbRed: 0.98, green: 0.72, blue: 0.32, alpha: 1)
    
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let rect = bounds.insetBy(dx: 4, dy: 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        cozyColor.withAlphaComponent(0.25).setFill()
        path.fill()
        
        // Subtle border
        cozyColor.withAlphaComponent(0.4).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
    
    override func drawBackground(in dirtyRect: NSRect) {
        // Transparent background
    }
}

private struct SavedNotes: Codable {
    var notes: [WorkspaceNote]
    var folders: [String]
}
