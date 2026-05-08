import Foundation

extension ChatViewModel {
    /// Open the find bar with an empty query. Idempotent — re-firing
    /// Cmd+F while already open just refocuses the field (the SwiftUI
    /// side handles that via `onAppear` on the bar).
    func transcriptFindOpen() {
        if transcriptFindQuery == nil {
            transcriptFindQuery = ""
            transcriptFindActiveMatch = 0
        }
    }

    func transcriptFindClose() {
        transcriptFindQuery = nil
        transcriptFindActiveMatch = 0
    }

    /// Cmd+G — advance to the next match, wrapping around at the end.
    /// The match-count clamp lives in `ChatTranscript` because this
    /// VM-side helper doesn't know how many matches the rendered
    /// transcript currently has; the index just keeps incrementing
    /// and the view modulos against the count when computing the
    /// active range.
    func transcriptFindStepNext() {
        transcriptFindActiveMatch += 1
    }

    /// Shift+Cmd+G — previous match. Decrement; wrap below zero is
    /// handled by the view's modulo.
    func transcriptFindStepPrev() {
        transcriptFindActiveMatch -= 1
    }
}
