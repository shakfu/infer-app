import Foundation
import PluginAPI

/// Contributes four tabular-file tools — `csv.write`, `tsv.write`,
/// `xlsx.write`, `xlsx.read` — sandboxed under the host's
/// `userDocuments` + `agentsRoot` policy. The same roots back the
/// built-in `fs.read` / `fs.write` tools in the host, so a host-side
/// policy change (tighten/widen sandbox) propagates here without a
/// plugin edit.
public enum SpreadsheetToolsPlugin: Plugin {
    public static let id = "spreadsheet_tools"

    public static func register(
        config _: PluginConfig,
        invoker _: ToolInvoker,
        host: any HostServices
    ) async throws -> PluginContributions {
        let roots = host.sandbox.roots(for: .userDocuments)
            + host.sandbox.roots(for: .agentsRoot)
        return PluginContributions(tools: [
            CSVWriteTool(allowedRoots: roots),
            TSVWriteTool(allowedRoots: roots),
            XlsxWriteTool(allowedRoots: roots),
            XlsxReadTool(allowedRoots: roots),
        ])
    }
}
