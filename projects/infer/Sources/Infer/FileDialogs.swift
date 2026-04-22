import AppKit
import UniformTypeIdentifiers

/// Thin wrappers over `NSOpenPanel` / `NSSavePanel`. Exist so ViewModel
/// methods don't each re-invent panel configuration; also the one place to
/// swap later if this target grows an iOS sibling (`.fileImporter` /
/// `.fileExporter` live inside SwiftUI views, so the replacement isn't
/// 1:1 — keeping the call-site shape short makes that day easier).
enum FileDialogs {
    /// Pick a single existing file. `contentTypes` restricts the picker;
    /// returns nil on cancel.
    static func openFile(message: String, contentTypes: [UTType]) -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = contentTypes
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Pick a directory (create-on-pick allowed); returns nil on cancel.
    static func openDirectory(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Choose a save destination. `defaultName` seeds the filename field;
    /// returns nil on cancel.
    static func saveFile(
        message: String,
        defaultName: String,
        contentTypes: [UTType]
    ) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = contentTypes
        panel.nameFieldStringValue = defaultName
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }
}
