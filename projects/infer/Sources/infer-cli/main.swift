import Foundation
import InferCore
import InferSession

// Non-interactive CLI over `InferSession`'s cloud backend. Built for
// scriptability and CI: prompt in (argument or stdin), assistant reply out
// (streamed text, or one JSON object with `--json`), exit code signals
// success/failure. Cloud-only by design so it links no MLX/llama/Metal code
// and builds with plain `swift build --product infer-cli`.
//
// Usage:
//   infer-cli [--provider openai|anthropic|openrouter] --model <id>
//             [--system <text>] [--max-tokens <n>] [--temperature <t>]
//             [--json] [--no-stream] [PROMPT...]
//
// The prompt is the trailing positional arguments joined by spaces, or, if
// none are given, all of stdin. The API key is read from the keychain /
// environment via `APIKeyStore.resolve` (e.g. OPENAI_API_KEY,
// ANTHROPIC_API_KEY, OPENROUTER_API_KEY).

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("infer-cli: " + message + "\n").utf8))
    exit(code)
}

struct Options {
    var providerName = "anthropic"
    var model: String?
    var system: String?
    var maxTokens = 1024
    var temperature: Double?
    var json = false
    var stream = true
    var repl = false
    var promptWords: [String] = []
}

func parse(_ argv: [String]) -> Options {
    var opts = Options()
    var i = 0
    func value(_ flag: String) -> String {
        i += 1
        guard i < argv.count else { fail("missing value for \(flag)", code: 2) }
        return argv[i]
    }
    while i < argv.count {
        let arg = argv[i]
        switch arg {
        case "--provider", "-p": opts.providerName = value(arg)
        case "--model", "-m": opts.model = value(arg)
        case "--system", "-s": opts.system = value(arg)
        case "--max-tokens":
            let raw = value(arg)
            guard let n = Int(raw) else { fail("--max-tokens must be an integer", code: 2) }
            opts.maxTokens = n
        case "--temperature", "-t":
            let raw = value(arg)
            guard let t = Double(raw) else { fail("--temperature must be a number", code: 2) }
            opts.temperature = t
        case "--json": opts.json = true
        case "--no-stream": opts.stream = false
        case "--repl": opts.repl = true
        case "-h", "--help":
            print("""
            Usage: infer-cli [--provider openai|anthropic|openrouter] --model <id> \
            [--system <text>] [--max-tokens <n>] [--temperature <t>] [--json] [--no-stream] [--repl] [PROMPT...]

            One-shot: prompt is the trailing arguments, or all of stdin if none.
            --repl:   multi-turn; reads one user turn per line of stdin, keeping
                      conversation context across turns (replies separated by a
                      blank line). Ignores positional PROMPT.
            API key is read from the keychain or the provider's env var
            (OPENAI_API_KEY / ANTHROPIC_API_KEY / OPENROUTER_API_KEY).
            """)
            exit(0)
        default:
            if arg.hasPrefix("-") { fail("unknown option: \(arg)", code: 2) }
            opts.promptWords.append(arg)
        }
        i += 1
    }
    return opts
}

func provider(from name: String) -> CloudProvider {
    switch name.lowercased() {
    case "openai": return .openai
    case "anthropic": return .anthropic
    case "openrouter": return .openrouter
    default: fail("unknown provider '\(name)' (expected openai, anthropic, or openrouter)", code: 2)
    }
}

func readPrompt(_ opts: Options) -> String {
    if !opts.promptWords.isEmpty {
        return opts.promptWords.joined(separator: " ")
    }
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { fail("no prompt given (pass as arguments or on stdin)", code: 2) }
    return text
}

let opts = parse(Array(CommandLine.arguments.dropFirst()))
guard let model = opts.model else { fail("--model is required", code: 2) }
let prov = provider(from: opts.providerName)

guard let resolved = APIKeyStore.resolve(for: prov) else {
    fail("no API key for \(prov.displayName); set \(prov.envVarName ?? "the provider key") or store one in the keychain", code: 2)
}

var params = CloudGenerationParams(maxTokens: opts.maxTokens)
if let t = opts.temperature { params.temperature = t }

let session = ChatSession()

do {
    try await session.configure(
        provider: prov,
        model: model,
        apiKey: resolved.key,
        systemPrompt: opts.system,
        params: params
    )

    if opts.repl {
        // Multi-turn: each stdin line is a user turn; the session keeps
        // context across turns. JSON mode is not offered here — repl is for
        // interactive / scripted conversations, not single-object capture.
        while let line = readLine(strippingNewline: true) {
            let turn = line.trimmingCharacters(in: .whitespaces)
            if turn.isEmpty { continue }
            _ = try await session.send(turn, maxTokens: opts.maxTokens) { chunk in
                FileHandle.standardOutput.write(Data(chunk.utf8))
            }
            FileHandle.standardOutput.write(Data("\n\n".utf8))
        }
    } else {
        let prompt = readPrompt(opts)
        let streamToStdout = opts.stream && !opts.json
        let reply = try await session.send(prompt, maxTokens: opts.maxTokens) { chunk in
            if streamToStdout { FileHandle.standardOutput.write(Data(chunk.utf8)) }
        }

        if opts.json {
            struct Output: Encodable {
                let provider: String
                let model: String
                let response: String
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(Output(provider: opts.providerName, model: model, response: reply))
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else if streamToStdout {
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else {
            print(reply)
        }
    }
} catch {
    fail("\(error)")
}
