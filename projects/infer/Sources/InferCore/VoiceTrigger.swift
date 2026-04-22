import Foundation

/// Detection of a trailing "submit" phrase in dictated text. Pure function;
/// lives here so it can be unit-tested without pulling in the Infer target's
/// speech / UI dependencies.
public enum VoiceTrigger {
    /// If `text` ends with `phrase` (case-insensitive, ignoring trailing
    /// punctuation/whitespace, and requiring a word boundary before the
    /// phrase), returns `text` with the phrase and trailing delimiters
    /// stripped. Returns `nil` otherwise and when `phrase` is empty.
    ///
    /// The word-boundary check prevents `"resend it"` from matching
    /// `"send it"` — we require the character before the phrase to be
    /// whitespace (or the phrase to start at position 0).
    public static func stripTrailingTrigger(_ text: String, phrase: String) -> String? {
        let trigger = phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trigger.isEmpty else { return nil }

        let trailingPunct = CharacterSet(charactersIn: " .,!?;:\n\t")
        var lowered = text.lowercased()
        while let last = lowered.unicodeScalars.last, trailingPunct.contains(last) {
            lowered.unicodeScalars.removeLast()
        }
        guard lowered.hasSuffix(trigger) else { return nil }

        let triggerStartLowered = lowered.index(lowered.endIndex, offsetBy: -trigger.count)
        if triggerStartLowered > lowered.startIndex {
            let prev = lowered[lowered.index(before: triggerStartLowered)]
            if !prev.isWhitespace { return nil }
        }

        // Map the stripped boundary back to the original string by walking
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
        let tailTrim = CharacterSet(charactersIn: " ,.;:\n\t")
        while let last = result.unicodeScalars.last, tailTrim.contains(last) {
            result.unicodeScalars.removeLast()
        }
        return result
    }
}
