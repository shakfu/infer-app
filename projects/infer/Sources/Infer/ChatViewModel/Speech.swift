import Foundation
import AppKit

extension ChatViewModel {
    /// If `text` ends with the configured trigger phrase (case-insensitive,
    /// ignoring trailing punctuation/whitespace), return the text with the
    /// phrase removed. Returns nil otherwise. Returns nil if `phrase` is empty.
    static func stripTrailingTrigger(_ text: String, phrase: String) -> String? {
        let trigger = phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trigger.isEmpty else { return nil }

        let trailingPunct = CharacterSet(charactersIn: " .,!?;:\n\t")
        // Peel trailing whitespace/punctuation off the text for comparison.
        var lowered = text.lowercased()
        while let last = lowered.unicodeScalars.last, trailingPunct.contains(last) {
            lowered.unicodeScalars.removeLast()
        }
        guard lowered.hasSuffix(trigger) else { return nil }

        // Require a word boundary before the trigger so "resend it"
        // doesn't match "send it". Boundary = start-of-string or whitespace.
        let triggerStartLowered = lowered.index(lowered.endIndex, offsetBy: -trigger.count)
        if triggerStartLowered > lowered.startIndex {
            let prev = lowered[lowered.index(before: triggerStartLowered)]
            if !prev.isWhitespace { return nil }
        }

        // Map the lowercased boundary back to the original string by walking
        // from the end past the same number of trailing punct/whitespace
        // scalars we peeled.
        var peelOffset = 0
        var scratch = text
        while let last = scratch.unicodeScalars.last, trailingPunct.contains(last) {
            scratch.unicodeScalars.removeLast()
            peelOffset += 1
        }
        let originalCore = text.prefix(text.count - peelOffset)
        guard originalCore.count >= trigger.count else { return nil }
        let triggerStart = originalCore.index(originalCore.endIndex, offsetBy: -trigger.count)
        var result = String(originalCore[..<triggerStart])
        // Trim the now-trailing comma/space/period left behind.
        let tailTrim = CharacterSet(charactersIn: " ,.;:\n\t")
        while let last = result.unicodeScalars.last, tailTrim.contains(last) {
            result.unicodeScalars.removeLast()
        }
        return result
    }

    /// Transcribe a dropped audio file with whisper.cpp. Output is prefixed
    /// with the source filename so the LLM gets context about what it's
    /// reading.
    func transcribeDroppedFile(url: URL) {
        transcribeURL(url, prefix: "[Transcript of \(url.lastPathComponent)]\n\n",
                      statusLabel: url.lastPathComponent)
    }

    /// Transcribe an in-app recording. Output is inserted as bare text —
    /// the user originates the recording, so they already know what it is.
    func transcribeRecording(url: URL) {
        transcribeURL(url, prefix: nil, statusLabel: "recording")
    }

    fileprivate func transcribeURL(_ url: URL, prefix: String?, statusLabel: String) {
        guard !isTranscribingFile else {
            errorMessage = "Already transcribing an audio file. Please wait."
            return
        }
        isTranscribingFile = true
        transcriptionStatus = "Preparing \(statusLabel)…"

        Task { [weak self] in
            guard let self else { return }
            do {
                let modelURL = try await self.whisperModels.ensureDownloaded()
                try await WhisperRunner.shared.load(modelPath: modelURL.path)

                await MainActor.run {
                    self.transcriptionStatus = "Transcribing \(statusLabel)…"
                }
                let translate = self.whisperModels.translate
                let text = try await WhisperRunner.shared.transcribeFile(
                    url: url, translate: translate
                )

                await MainActor.run {
                    self.transcriptionStatus = nil
                    self.isTranscribingFile = false
                    if text.isEmpty {
                        self.errorMessage = "Transcription of \(statusLabel) produced no text."
                        return
                    }
                    let toInsert = (prefix ?? "") + text
                    if self.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.input = toInsert
                    } else {
                        let sep = self.input.hasSuffix("\n") ? "\n" : "\n\n"
                        self.input += sep + toInsert
                    }
                }
            } catch {
                await MainActor.run {
                    self.transcriptionStatus = nil
                    self.isTranscribingFile = false
                    self.errorMessage = "Transcription failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Toggle the mic recorder. On stop, kicks off transcription of the
    /// recorded .wav. Runs concurrently with normal dictation (they use
    /// separate AVAudioEngine instances) but is disabled in the UI when
    /// dictation is active to avoid audio routing surprises.
    func toggleAudioRecording() {
        if audioRecorder.isRecording {
            if let url = audioRecorder.stop() {
                transcribeRecording(url: url)
            }
        } else {
            do {
                try audioRecorder.start()
            } catch {
                errorMessage = "Could not start recording: \(error.localizedDescription)"
            }
        }
    }

    func cancelAudioRecording() {
        audioRecorder.cancel()
    }

    /// Open the recordings directory in Finder. Creates it on demand so the
    /// user doesn't hit a "nothing selected" window on first use.
    func revealRecordingsInFinder() {
        do {
            let dir = try AudioFileRecorder.recordingsDirectory()
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        } catch {
            errorMessage = "Could not open recordings folder: \(error.localizedDescription)"
        }
    }

    /// Delete every `.wav` under the recordings directory. Caller is
    /// expected to have confirmed via NSAlert.
    func clearRecordings() {
        do {
            let dir = try AudioFileRecorder.recordingsDirectory()
            let fm = FileManager.default
            let urls = try fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for url in urls where url.pathExtension.lowercased() == "wav" {
                try? fm.removeItem(at: url)
            }
        } catch {
            errorMessage = "Could not clear recordings: \(error.localizedDescription)"
        }
    }
}
