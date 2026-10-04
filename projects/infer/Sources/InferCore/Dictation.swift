import Foundation

/// Speech-to-text engine behind the composer's mic.
public enum DictationBackend: String, CaseIterable, Sendable {
    /// `SFSpeechRecognizer`: streaming partials, on-device when available.
    case system
    /// whisper.cpp over a rolling capture buffer, using the model picked
    /// under File Transcription.
    case whisper

    public var label: String {
        switch self {
        case .system: return "System"
        case .whisper: return "Whisper"
        }
    }
}

/// How the mic is armed.
public enum DictationMode: String, CaseIterable, Sendable {
    /// Mic button / shortcut toggles recording on and off.
    case toggle
    /// Hold `PushToTalkKey` while Infer is active; release stops and sends.
    case pushToTalk

    public var label: String {
        switch self {
        case .toggle: return "Toggle"
        case .pushToTalk: return "Push-to-talk"
        }
    }
}

/// Modifier keys usable for push-to-talk. Right-hand modifiers avoid
/// clashing with left-hand shortcuts; a chord (any key pressed during
/// the hold) cancels the gesture, so typing with them still works.
public enum PushToTalkKey: String, CaseIterable, Sendable {
    case fn
    case rightOption
    case rightCommand

    /// macOS virtual key code reported on `flagsChanged`.
    public var keyCode: UInt16 {
        switch self {
        case .fn: return 63
        case .rightOption: return 61
        case .rightCommand: return 54
        }
    }

    public var label: String {
        switch self {
        case .fn: return "Fn / Globe"
        case .rightOption: return "Right Option"
        case .rightCommand: return "Right Command"
        }
    }
}

/// Push-to-talk state machine over raw key events. Pure so it can be
/// tested without AppKit; the app maps `NSEvent`s onto it.
public struct PushToTalkGesture: Sendable {
    public enum Action: Equatable, Sendable {
        /// Key went down: start dictation.
        case begin
        /// Key released with no chord: stop, finalize, send.
        case end
        /// Another key was pressed during the hold: abandon dictation.
        case chord
    }

    public let key: PushToTalkKey
    public private(set) var holding = false
    private var chorded = false

    public init(key: PushToTalkKey) {
        self.key = key
    }

    /// `keyIsDown` is whether the key's modifier flag is set after the
    /// event.
    public mutating func flagsChanged(keyCode: UInt16, keyIsDown: Bool) -> Action? {
        guard keyCode == key.keyCode else { return nil }
        if keyIsDown, !holding {
            holding = true
            chorded = false
            return .begin
        }
        if !keyIsDown, holding {
            holding = false
            return chorded ? nil : .end
        }
        return nil
    }

    public mutating func keyDown() -> Action? {
        guard holding, !chorded else { return nil }
        chorded = true
        return .chord
    }
}

public enum WhisperText {
    /// Drop whisper.cpp's non-speech annotations (`[BLANK_AUDIO]`,
    /// `[MUSIC]`, `(silence)`) and collapse the whitespace they leave.
    public static func clean(_ text: String) -> String {
        var out = ""
        var closing: Character?
        for c in text {
            if let close = closing {
                if c == close { closing = nil }
                continue
            }
            if c == "[" { closing = "]"; continue }
            if c == "(" { closing = ")"; continue }
            out.append(c)
        }
        return out
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
