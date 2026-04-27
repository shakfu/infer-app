import Foundation

/// Three sibling tools for writing tabular data to disk: `csv.write`,
/// `tsv.write`, `xlsx.write`. They share the sandbox / argument
/// parsing / atomic-write plumbing because the only meaningful
/// differences are the on-disk format.
///
/// Why three instead of one with a `format` arg:
/// - `xlsx.write` supports multi-sheet, formulas, formatting — the
///   argument schema is genuinely different.
/// - `csv.write` and `tsv.write` *could* share a tool, but the
///   escaping rules are different (CSV does RFC-4180 quoting; TSV
///   replaces embedded tabs/newlines), and the typical Excel-on-
///   Windows BOM convention applies to CSV but not TSV.
/// - Mode-arguments on tools are an anti-pattern — agents pick the
///   wrong mode often enough that explicit tool names earn their
///   keep.

// MARK: - Cell value (shared)

/// Reuse `XlsxWorksheet.Cell` as the canonical spreadsheet cell type
/// across all three tools. The xlsx writer needs the typed cases
/// directly; CSV / TSV use the same enum with format-specific
/// serialisation via `plainText()` below. Keeping a single cell type
/// avoids a useless mapping layer between two near-identical enums.

extension XlsxWorksheet.Cell {
    /// Decode one cell from a raw JSON value. The argument decoder
    /// represents JSON values as `Any`, so we pattern-match on the
    /// underlying type. Anything that isn't scalar (nested array /
    /// nested object) is rejected as `nil` so the tool can return a
    /// clear error message naming the offending row/column.
    static func decode(_ raw: Any) -> XlsxWorksheet.Cell? {
        if raw is NSNull { return .empty }
        if let s = raw as? String {
            return s.hasPrefix("=") ? .formula(s) : .text(s)
        }
        if let n = raw as? NSNumber {
            // NSNumber bridges both Bool and the numeric types. The
            // CoreFoundation type-id is the only reliable discriminator
            // — `objCType` is "c" for Bool but also for `Int8`.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return .bool(n.boolValue)
            }
            return .number(n.doubleValue)
        }
        if let b = raw as? Bool { return .bool(b) }
        if let d = raw as? Double { return .number(d) }
        if let i = raw as? Int { return .number(Double(i)) }
        if let i = raw as? Int64 { return .number(Double(i)) }
        return nil
    }

    /// Serialise to plain text for CSV / TSV. Returns the literal
    /// string a cell should contribute to a delimited file BEFORE
    /// any escaping is applied. Numbers use `%g`-equivalent
    /// formatting (no trailing zeroes); integers print without a
    /// decimal point.
    func plainText() -> String {
        switch self {
        case .empty: return ""
        case .text(let s): return s
        case .number(let d):
            if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
            return String(d)
        case .formula(let s): return s
        case .bool(let b): return b ? "TRUE" : "FALSE"
        }
    }
}

/// Local error wrapper for argument-validation paths that want to
/// return a user-facing message string. `Result<_, String>` would
/// require `String: Error`, which it isn't; this two-case enum is the
/// minimum that satisfies the type system without inventing a
/// throwing-error newtype just for argument parsing.
private enum ValidatedRows {
    case ok([[XlsxWorksheet.Cell]])
    case invalid(String)
}

private enum ResolvedTarget {
    case ok(URL)
    case invalid(String)
}

// MARK: - Shared argument validation

/// Parses `rows: [[Any]]` from the raw JSON object, validates each
/// cell is scalar, and (for CSV/TSV) checks every row has the same
/// column count as the first non-empty row.
private func validateRows(_ raw: [[Any]], requireRectangular: Bool) -> ValidatedRows {
    var firstColumnCount: Int?
    var out: [[XlsxWorksheet.Cell]] = []
    out.reserveCapacity(raw.count)
    for (rowIdx, rawRow) in raw.enumerated() {
        var row: [XlsxWorksheet.Cell] = []
        row.reserveCapacity(rawRow.count)
        for (colIdx, rawCell) in rawRow.enumerated() {
            guard let cell = XlsxWorksheet.Cell.decode(rawCell) else {
                return .invalid("cell at row \(rowIdx + 1), column \(colIdx + 1) is not a scalar (string, number, bool, or null)")
            }
            row.append(cell)
        }
        if requireRectangular {
            if let expected = firstColumnCount {
                if row.count != expected {
                    return .invalid("row \(rowIdx + 1) has \(row.count) columns; expected \(expected) (rows must be rectangular)")
                }
            } else if !row.isEmpty {
                firstColumnCount = row.count
            }
        }
        out.append(row)
    }
    return .ok(out)
}

/// Resolve `path` against `allowedRoots` using the same rules as
/// `fs.write`: tilde expansion, symlink resolution on the parent so
/// a symlink-into-the-root can't escape, exists-check on the parent
/// dir, refuse-overwrite default.
private func resolveSandboxedTarget(
    path: String,
    overwrite: Bool,
    allowedRoots: [URL],
    toolName: String
) -> ResolvedTarget {
    guard !allowedRoots.isEmpty else {
        return .invalid("\(toolName) is not configured: no allowed roots")
    }
    let expanded = (path as NSString).expandingTildeInPath
    let candidate = URL(fileURLWithPath: expanded).standardizedFileURL
    let parent = candidate.deletingLastPathComponent().resolvingSymlinksInPath()
    let resolved = parent.appendingPathComponent(candidate.lastPathComponent)
    let allowed = allowedRoots.contains { root in
        resolved.path == root.path || resolved.path.hasPrefix(root.path + "/")
    }
    guard allowed else {
        return .invalid("path is outside the allowed sandbox")
    }
    var isDir: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir)
    if exists && isDir.boolValue {
        return .invalid("path is a directory, not a file")
    }
    if exists && !overwrite {
        return .invalid("file exists; pass `\"overwrite\": true` to replace it")
    }
    var parentIsDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &parentIsDir),
          parentIsDir.boolValue else {
        return .invalid("parent directory does not exist: \(parent.path)")
    }
    return .ok(resolved)
}

// MARK: - csv.write

/// RFC 4180 CSV writer. Sandboxed under the same allowed-roots model
/// as `fs.read` / `fs.write`. Quotes any cell containing the delimiter,
/// a double-quote, or a line break; doubles internal quotes per RFC
/// 4180. Optional UTF-8 BOM (default ON) so Excel-on-Windows opens
/// non-ASCII characters correctly.
public struct CSVWriteTool: BuiltinTool {
    public let name: ToolName = "csv.write"
    public static let maxBytes = 4 * 1024 * 1024   // 4 MB

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: """
                Write a CSV file. Arguments: \
                {"path": "<absolute or ~/-relative path>", \
                "rows": [["col-A", "col-B"], ["1", 2], ...], \
                "overwrite": false, "bom": true}. \
                Each cell value can be a string, number, boolean, or null. \
                Strings beginning with `=` are written verbatim — Excel still \
                interprets them as formulas on open. RFC 4180 quoting is \
                applied automatically; cells containing commas, quotes, or \
                newlines are wrapped in double quotes with internal quotes \
                doubled. The `bom` flag controls the optional UTF-8 BOM \
                (default true; required for Excel-on-Windows to open \
                non-ASCII text correctly). Rows must be rectangular (same \
                column count). Maximum file size: \(Self.maxBytes) bytes.
                """
        )
    }

    public let allowedRoots: [URL]

    public init(allowedRoots: [URL]) {
        self.allowedRoots = allowedRoots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
    }

    private struct Args: Decodable {
        let path: String
        let rows: [[SpreadsheetJSONValue]]
        let overwrite: Bool?
        let bom: Bool?
    }

    public func invoke(arguments: String) async throws -> ToolResult {
        let parsed: Args
        do {
            parsed = try JSONDecoder().decode(Args.self, from: Data(arguments.utf8))
        } catch {
            return ToolResult(output: "", error: "could not parse arguments: \(error.localizedDescription)")
        }
        let raw = parsed.rows.map { $0.map(\.asAny) }
        let cells: [[XlsxWorksheet.Cell]]
        switch validateRows(raw, requireRectangular: true) {
        case .ok(let r): cells = r
        case .invalid(let msg): return ToolResult(output: "", error: msg)
        }
        let target: URL
        switch resolveSandboxedTarget(
            path: parsed.path,
            overwrite: parsed.overwrite ?? false,
            allowedRoots: allowedRoots,
            toolName: name
        ) {
        case .ok(let u): target = u
        case .invalid(let msg): return ToolResult(output: "", error: msg)
        }

        var body = Data()
        if parsed.bom ?? true {
            // UTF-8 BOM (EF BB BF) — Excel uses it as a hint that the
            // file is UTF-8 even though the byte sequence isn't a valid
            // CSV record on its own.
            body.append(contentsOf: [0xEF, 0xBB, 0xBF])
        }
        for row in cells {
            let line = row.map { Self.escape($0.plainText()) }.joined(separator: ",")
            body.append(line.data(using: .utf8) ?? Data())
            // CRLF per RFC 4180 — matters for some Windows tools that
            // refuse LF-only line endings.
            body.append(contentsOf: [0x0D, 0x0A])
        }
        guard body.count <= Self.maxBytes else {
            return ToolResult(output: "", error: "encoded output exceeds \(Self.maxBytes) bytes (\(body.count) bytes)")
        }
        do {
            try body.write(to: target, options: [.atomic])
        } catch {
            return ToolResult(output: "", error: "write failed: \(error.localizedDescription)")
        }
        return ToolResult(output: "wrote \(body.count) bytes to \(target.path) (\(cells.count) row\(cells.count == 1 ? "" : "s"))")
    }

    /// RFC 4180 escape: wrap in double quotes when the value contains
    /// the delimiter, a double quote, or a line break; double internal
    /// quotes. Otherwise emit the raw string.
    static func escape(_ s: String) -> String {
        let needsQuoting = s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r")
        guard needsQuoting else { return s }
        let doubled = s.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(doubled)\""
    }
}

// MARK: - tsv.write

/// Tab-separated values writer. Strict TSV has no escape mechanism for
/// tabs / newlines inside a cell — different conventions handle this
/// differently. We follow the most-compatible-with-Excel-and-Numbers
/// approach: replace embedded tabs and CRs with a single space, embedded
/// LFs likewise. Information loss, but reliable round-trip into any
/// spreadsheet target.
///
/// Argument schema is `csv.write`'s minus `bom` (TSV consumers don't
/// expect a BOM; some tools mishandle one).
public struct TSVWriteTool: BuiltinTool {
    public let name: ToolName = "tsv.write"
    public static let maxBytes = 4 * 1024 * 1024

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: """
                Write a TSV (tab-separated values) file. Arguments: \
                {"path": "<absolute or ~/-relative path>", \
                "rows": [["col-A", "col-B"], ...], "overwrite": false}. \
                Each cell value can be a string, number, boolean, or null. \
                Strings beginning with `=` are written verbatim. TSV has no \
                escape mechanism for embedded tabs / newlines, so any of \
                those characters in a cell value are silently replaced with \
                a single space — paste-into-spreadsheet compatibility is \
                preferred over information preservation here. Rows must be \
                rectangular. Maximum file size: \(Self.maxBytes) bytes.
                """
        )
    }

    public let allowedRoots: [URL]

    public init(allowedRoots: [URL]) {
        self.allowedRoots = allowedRoots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
    }

    private struct Args: Decodable {
        let path: String
        let rows: [[SpreadsheetJSONValue]]
        let overwrite: Bool?
    }

    public func invoke(arguments: String) async throws -> ToolResult {
        let parsed: Args
        do {
            parsed = try JSONDecoder().decode(Args.self, from: Data(arguments.utf8))
        } catch {
            return ToolResult(output: "", error: "could not parse arguments: \(error.localizedDescription)")
        }
        let raw = parsed.rows.map { $0.map(\.asAny) }
        let cells: [[XlsxWorksheet.Cell]]
        switch validateRows(raw, requireRectangular: true) {
        case .ok(let r): cells = r
        case .invalid(let msg): return ToolResult(output: "", error: msg)
        }
        let target: URL
        switch resolveSandboxedTarget(
            path: parsed.path,
            overwrite: parsed.overwrite ?? false,
            allowedRoots: allowedRoots,
            toolName: name
        ) {
        case .ok(let u): target = u
        case .invalid(let msg): return ToolResult(output: "", error: msg)
        }

        var body = Data()
        for row in cells {
            let line = row.map { Self.sanitise($0.plainText()) }.joined(separator: "\t")
            body.append(line.data(using: .utf8) ?? Data())
            // LF — consensus line ending for TSV (Excel handles either,
            // but most TSV-aware tools standardise on Unix-style).
            body.append(0x0A)
        }
        guard body.count <= Self.maxBytes else {
            return ToolResult(output: "", error: "encoded output exceeds \(Self.maxBytes) bytes (\(body.count) bytes)")
        }
        do {
            try body.write(to: target, options: [.atomic])
        } catch {
            return ToolResult(output: "", error: "write failed: \(error.localizedDescription)")
        }
        return ToolResult(output: "wrote \(body.count) bytes to \(target.path) (\(cells.count) row\(cells.count == 1 ? "" : "s"))")
    }

    /// Replace embedded tabs / CRs / LFs with a single space. Public
    /// for unit tests; not exported to the model.
    static func sanitise(_ s: String) -> String {
        var out = s
        for c: Character in ["\t", "\r", "\n"] {
            out = out.replacingOccurrences(of: String(c), with: " ")
        }
        return out
    }
}

// MARK: - xlsx.write

/// Multi-sheet `.xlsx` writer via the libxlsxwriter C library (Swift
/// shim in `Tools/XlsxWriter.swift`). Writes to a temp file, then
/// renames onto the target — same atomic-write convention as `fs.write`.
///
/// Argument schema:
/// ```
/// {
///   "path": "/path/to/file.xlsx",
///   "sheets": [
///     {
///       "name": "Quarterly",        // optional; libxlsxwriter assigns Sheet1/Sheet2 if omitted
///       "header": ["Q", "Revenue"], // optional bold-formatted first row
///       "rows": [["Q1", 12500], ["Q2", 14200]],
///       "freezeHeader": true        // optional, default false
///     },
///     ...
///   ],
///   "overwrite": false
/// }
/// ```
public struct XlsxWriteTool: BuiltinTool {
    public let name: ToolName = "xlsx.write"

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: """
                Write a real Excel `.xlsx` workbook. Arguments: \
                {"path": "<...>", "sheets": [{"name": "Sheet1", "header": [...], \
                "rows": [[...], ...], "freezeHeader": true}], "overwrite": false}. \
                Each sheet has an optional `name` (max 31 chars; characters \
                `:\\\\/?*[]` are forbidden by Excel), an optional `header` row \
                (rendered bold), `rows` of scalar cell values (string, number, \
                bool, null), and an optional `freezeHeader` flag (pins the \
                header row while scrolling). Strings beginning with `=` are \
                written as Excel formulas — for example `"=SUM(B2:B10)"`. \
                Use this when the user wants a real Excel file; use `csv.write` \
                for the simpler "table for any spreadsheet" workflow.
                """
        )
    }

    public let allowedRoots: [URL]

    public init(allowedRoots: [URL]) {
        self.allowedRoots = allowedRoots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
    }

    private struct Args: Decodable {
        let path: String
        let sheets: [Sheet]
        let overwrite: Bool?
    }
    private struct Sheet: Decodable {
        let name: String?
        let header: [SpreadsheetJSONValue]?
        let rows: [[SpreadsheetJSONValue]]?
        let freezeHeader: Bool?
    }

    public func invoke(arguments: String) async throws -> ToolResult {
        let parsed: Args
        do {
            parsed = try JSONDecoder().decode(Args.self, from: Data(arguments.utf8))
        } catch {
            return ToolResult(output: "", error: "could not parse arguments: \(error.localizedDescription)")
        }
        guard !parsed.sheets.isEmpty else {
            return ToolResult(output: "", error: "no sheets to write — provide at least one sheet")
        }

        let target: URL
        switch resolveSandboxedTarget(
            path: parsed.path,
            overwrite: parsed.overwrite ?? false,
            allowedRoots: allowedRoots,
            toolName: name
        ) {
        case .ok(let u): target = u
        case .invalid(let msg): return ToolResult(output: "", error: msg)
        }

        // Atomic write: libxlsxwriter writes directly to a path it
        // owns, so we point it at a sibling temp path and rename onto
        // the target on success. Failure path cleans up the temp.
        let tempURL = target.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString)-\(target.lastPathComponent)")

        do {
            let workbook = try XlsxWorkbook(path: tempURL.path)
            let bold = workbook.addBoldFormat()
            var totalRows = 0
            for sheet in parsed.sheets {
                let ws = try workbook.addWorksheet(name: sheet.name)
                var rowCursor = 0
                if let headerRow = sheet.header, !headerRow.isEmpty {
                    for (col, value) in headerRow.enumerated() {
                        guard let cell = XlsxWorksheet.Cell.decode(value.asAny) else {
                            try? FileManager.default.removeItem(at: tempURL)
                            return ToolResult(output: "", error: "header cell at column \(col + 1) is not a scalar")
                        }
                        try ws.write(row: rowCursor, col: col, value: cell, format: bold)
                    }
                    rowCursor += 1
                }
                if let body = sheet.rows {
                    let raw = body.map { $0.map(\.asAny) }
                    let cells: [[XlsxWorksheet.Cell]]
                    switch validateRows(raw, requireRectangular: false) {
                    case .ok(let r): cells = r
                    case .invalid(let msg):
                        try? FileManager.default.removeItem(at: tempURL)
                        return ToolResult(output: "", error: "sheet '\(sheet.name ?? "<default>")': \(msg)")
                    }
                    for (rowIdx, row) in cells.enumerated() {
                        for (colIdx, cell) in row.enumerated() {
                            try ws.write(row: rowCursor + rowIdx, col: colIdx, value: cell)
                        }
                    }
                    rowCursor += cells.count
                }
                totalRows += rowCursor
                if sheet.freezeHeader ?? false, sheet.header?.isEmpty == false {
                    ws.freezePanes(row: 1, col: 0)
                }
            }
            try workbook.close()
        } catch let error as XlsxError {
            try? FileManager.default.removeItem(at: tempURL)
            return ToolResult(output: "", error: error.description)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return ToolResult(output: "", error: "xlsx write failed: \(error.localizedDescription)")
        }

        // Rename temp → target. If the target already existed and
        // `overwrite: true` was passed, we must remove it first; the
        // resolveSandboxedTarget gate already confirmed permission.
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.moveItem(at: tempURL, to: target)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return ToolResult(output: "", error: "could not rename temp file: \(error.localizedDescription)")
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: target.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        return ToolResult(output: "wrote \(size) bytes to \(target.path) (\(parsed.sheets.count) sheet\(parsed.sheets.count == 1 ? "" : "s"))")
    }
}

// MARK: - JSON cell-value helper

/// `Codable`-friendly representation of a single spreadsheet cell.
/// `JSONDecoder` doesn't decode arbitrary `Any`, so we wrap each cell
/// value as a heterogeneous union and unwrap to `Any` at the
/// validation step. Keeps the per-tool argument structs strictly
/// typed (no `Any` in the Decodable surface) without sacrificing the
/// model's ability to pass mixed scalars.
struct SpreadsheetJSONValue: Decodable {
    let asAny: Any

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self.asAny = NSNull(); return }
        if let b = try? c.decode(Bool.self) { self.asAny = b; return }
        if let i = try? c.decode(Int64.self) { self.asAny = i; return }
        if let d = try? c.decode(Double.self) { self.asAny = d; return }
        if let s = try? c.decode(String.self) { self.asAny = s; return }
        throw DecodingError.dataCorruptedError(
            in: c,
            debugDescription: "expected scalar (string, number, bool, null) for cell"
        )
    }
}
