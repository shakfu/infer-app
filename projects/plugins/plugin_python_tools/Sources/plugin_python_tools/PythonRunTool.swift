import Foundation
import PluginAPI

/// `python.run`: spawn the embedded interpreter, feed it `code` on
/// stdin, return stdout + stderr + exit_code + timed_out.
struct PythonRunTool: BuiltinTool {
    let runner: PythonRunner

    var name: ToolName { "python.run" }

    var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: """
                Run Python 3 code in an isolated subprocess. The code is fed to a fresh \
                `python3 -` process; the working directory is a per-call temp dir that \
                is deleted on return. Returns a JSON object \
                {"stdout": str, "stderr": str, "exit_code": int, "timed_out": bool}. \
                The interpreter has full network and filesystem access as the user \
                running Infer — do not pass code from untrusted sources. Packages \
                available depend on what was baked in by `make fetch-python` (typically \
                openai, anthropic). No `pip install` at runtime.

                Parameters:
                  code (string, required): the Python source to run.
                  timeout_seconds (integer, optional): kill the process after this many \
                  seconds. Default 10, min 1, max 120. On timeout, partial stdout/stderr \
                  is still returned and `timed_out` is true.
                """
        )
    }

    func invoke(arguments: String) async throws -> ToolResult {
        struct Args: Decodable {
            let code: String
            let timeout_seconds: Int?
        }
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: Data(arguments.utf8))
        } catch {
            return ToolResult(output: "", error: "invalid arguments: \(error)")
        }
        if args.code.isEmpty {
            return ToolResult(output: "", error: "code must be non-empty")
        }
        let timeout = PythonTimeoutBounds.clamp(args.timeout_seconds)
        do {
            let result = try await runner.run(code: args.code, timeoutSeconds: timeout)
            return ToolResult(output: encode(result))
        } catch {
            return ToolResult(output: "", error: "spawn failed: \(error)")
        }
    }

    private func encode(_ result: PythonRunResult) -> String {
        // Hand-rolled JSON: a `Codable` wrapper would round-trip
        // through `JSONEncoder` for what's a four-key object — clearer
        // to keep the wire format explicit here.
        let out = jsonEscape(result.stdout)
        let err = jsonEscape(result.stderr)
        return #"{"stdout":\#(out),"stderr":\#(err),"exit_code":\#(result.exitCode),"timed_out":\#(result.timedOut)}"#
    }
}

/// `python.eval`: evaluate a single expression and return its `repr()`.
/// Implemented on top of `PythonRunner.run` with a tiny stdin shim
/// that reads the expression from an env var (avoids quoting hazards
/// when the expression contains backslashes, quotes, or newlines).
struct PythonEvalTool: BuiltinTool {
    let runner: PythonRunner

    var name: ToolName { "python.eval" }

    var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: """
                Evaluate a single Python expression and return its `repr()`. \
                Returns a JSON object {"value": str, "timed_out": bool} on success, \
                or {"error": str, "timed_out": bool} when the expression raises or \
                fails to parse. Use `python.run` for multi-statement scripts. Same \
                runtime, same package set, same trust model as `python.run`.

                Parameters:
                  expression (string, required): the Python expression to evaluate.
                  timeout_seconds (integer, optional): default 10, min 1, max 120.
                """
        )
    }

    private static let evalShim = """
        import os, sys
        expr = os.environ['__INFER_PY_EXPR']
        try:
            print(repr(eval(expr)))
        except Exception as e:
            print(f'{type(e).__name__}: {e}', file=sys.stderr)
            sys.exit(1)
        """

    func invoke(arguments: String) async throws -> ToolResult {
        struct Args: Decodable {
            let expression: String
            let timeout_seconds: Int?
        }
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: Data(arguments.utf8))
        } catch {
            return ToolResult(output: "", error: "invalid arguments: \(error)")
        }
        if args.expression.isEmpty {
            return ToolResult(output: "", error: "expression must be non-empty")
        }
        let timeout = PythonTimeoutBounds.clamp(args.timeout_seconds)
        do {
            let result = try await runner.run(
                code: Self.evalShim,
                timeoutSeconds: timeout,
                extraEnv: ["__INFER_PY_EXPR": args.expression]
            )
            if result.exitCode != 0 || result.timedOut {
                let err = jsonEscape(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
                return ToolResult(output: #"{"error":\#(err),"timed_out":\#(result.timedOut)}"#)
            }
            // Drop the trailing newline from `print()`.
            var value = result.stdout
            if value.hasSuffix("\n") { value.removeLast() }
            let out = jsonEscape(value)
            return ToolResult(output: #"{"value":\#(out),"timed_out":false}"#)
        } catch {
            return ToolResult(output: "", error: "spawn failed: \(error)")
        }
    }
}

/// JSON-escape a string and wrap it in double quotes. Sufficient for
/// the fields we emit (no NaN, no infinite numerics, no nested
/// objects). Returns the literal `"..."` ready to splice into a JSON
/// object.
func jsonEscape(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case "\u{08}": out += "\\b"
        case "\u{0C}": out += "\\f"
        default:
            if scalar.value < 0x20 {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out += String(scalar)
            }
        }
    }
    out += "\""
    return out
}
