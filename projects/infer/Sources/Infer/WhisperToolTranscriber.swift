import AVFoundation
import Foundation
import InferAgents

/// Connects `whisper.transcribe` to `WhisperRunner`, using the model selected
/// in the Speech sidebar.
struct WhisperToolTranscriber: AudioTranscriber {
    let models: WhisperModelManager

    func durationSeconds(of url: URL) async throws -> Double {
        do {
            let file = try AVAudioFile(forReading: url)
            return Double(file.length) / file.fileFormat.sampleRate
        } catch {
            throw WhisperError.audioDecodeFailed(error.localizedDescription)
        }
    }

    func transcribe(url: URL, translate: Bool) async throws -> String {
        let model = await models.selected
        // A tool call must not start a download of hundreds of MB.
        guard model.isDownloaded() else {
            throw WhisperError.modelLoadFailed("\(model.label) is not downloaded; download it from the Speech sidebar")
        }
        try await WhisperRunner.shared.load(modelPath: model.localURL().path)
        return try await WhisperRunner.shared.transcribeFile(url: url, translate: translate)
    }
}
