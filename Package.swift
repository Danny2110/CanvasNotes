// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Notesy",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Notesy", targets: ["NotesyApp"])],
    targets: [
        .executableTarget(
            name: "NotesyApp",
            path: ".",
            exclude: ["dist", "docs", ".build", "scripts"],
            sources: ["Sources/NotesyApp/main.swift", "Sources/NotesyApp/NotesWorkspaceView.swift", "Sources/NotesyApp/OnboardingGuideView.swift", "NoteModel.swift", "WorkspaceScrollView.swift", "LiquidGlassBoxView.swift", "HapticCanvasView.swift", "GlassSurface.swift"]
        )
    ]
)
