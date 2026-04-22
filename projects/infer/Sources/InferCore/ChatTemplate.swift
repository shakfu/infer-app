import Foundation

/// Pure helpers for tracking the delta between successive chat-template
/// renders. The actual template rendering (llama_chat_apply_template) lives
/// in `LlamaRunner` because it binds to the llama C API; this type only
/// handles the bookkeeping around the UTF-8 prefix the model has already
/// consumed.
public enum ChatPromptDelta {
    /// Given the freshly rendered full prompt and the UTF-8 byte length of
    /// the previous render (without the assistant tag), return the suffix
    /// the model has not yet seen.
    ///
    /// - `previousByteLength == 0` -> the whole prompt is new (first turn).
    /// - `previousByteLength >= fullRendered.utf8.count` -> empty string.
    ///   This can happen if the caller passes a stale length; clamping
    ///   keeps the caller from reading past the end.
    public static func delta(fullRendered: String, previousByteLength: Int) -> String {
        if previousByteLength <= 0 { return fullRendered }
        let utf8 = Array(fullRendered.utf8)
        let start = min(previousByteLength, utf8.count)
        if start == utf8.count { return "" }
        return String(decoding: utf8[start...], as: UTF8.self)
    }

    /// UTF-8 byte length to record after a render with `add_ass=false`.
    /// This is what the next call to `delta(fullRendered:previousByteLength:)`
    /// should receive.
    public static func byteLength(of rendered: String) -> Int {
        rendered.utf8.count
    }
}
