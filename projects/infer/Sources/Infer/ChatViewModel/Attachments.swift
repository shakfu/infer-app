import Foundation
import AppKit
import UniformTypeIdentifiers

extension ChatViewModel {
    /// Extensions routed to the whisper transcription pipeline.
    static let audioExtensions: Set<String> = [
        "wav", "mp3", "m4a", "aac", "aiff", "aif", "caf",
        "flac", "mp4", "mov", "mpeg", "mpg", "ogg", "opus"
    ]

    /// Extensions treated as image attachments for VLM input.
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "webp", "gif", "bmp", "tiff", "tif"
    ]

    /// Open a file picker for audio and image files. Audio routes to the
    /// whisper transcription flow; image becomes a pending attachment for
    /// the next send.
    func pickAttachment() {
        guard let url = FileDialogs.openFile(
            message: "Attach an audio or image file",
            contentTypes: [.audiovisualContent, .audio, .image]
        ) else { return }
        attachURL(url)
    }

    /// Route a URL (from picker or drag-drop) to the right attachment handler.
    func attachURL(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        if Self.audioExtensions.contains(ext) {
            transcribeDroppedFile(url: url)
        } else if Self.imageExtensions.contains(ext) {
            pendingImageURL = url
        } else {
            errorMessage = "Unsupported attachment type: .\(ext)"
        }
    }

    func clearPendingImage() {
        pendingImageURL = nil
    }

    /// True when the current composer state can be submitted. Composer
    /// validates send on top of this (non-empty text, model loaded, not
    /// generating). A pending image requires the MLX backend.
    var canSendAttachment: Bool {
        pendingImageURL == nil || backend == .mlx
    }
}
