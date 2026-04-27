import Foundation
import CoreXLSX

/// Read tabular data out of a local `.xlsx` file via CoreXLSX
/// (CoreOffice, Apache-2.0; pure Swift, parse-only). Pairs with
/// `xlsx.write` for the round-trip — libxlsxwriter is write-only by
/// design, CoreXLSX is read-only by design, so we use both.
///
/// What this tool surfaces to the model:
/// - The selected sheet's cells, row by row, in either TSV (default)
///   or JSON (`format: "json"`). TSV is the right shape for the
///   common "show me what's in this spreadsheet" prompt — short,
///   readable, no extra structure for the model to navigate.
/// - String cells via the workbook's shared-strings table.
/// - Number cells as their numeric value (CoreXLSX's `value` is the
///   raw string from the XML; we parse to Double and re-serialise).
/// - Booleans as `TRUE` / `FALSE` (matches `csv.write` output —
///   round-trips through write→read symmetric).
/// - Formulas: returns the cached value the spreadsheet last
///   computed, NOT the formula expression. Same behaviour Excel
///   shows in the cell when you open the file.
///
/// What it does NOT do:
/// - Date deserialization. Excel stores dates as serial numbers
///   (days-since-1900) tagged with a "date format" style; CoreXLSX
///   surfaces them as numbers, and parsing the style table to
///   detect "this number is actually a date" is a substantial
///   amount of code for a feature the model can do downstream by
///   just being told the column is a date. Punted.
/// - Cell formatting (font, fill, border). The tool is for data
///   extraction, not visual fidelity.
/// - Merged cells. CoreXLSX can read them; we don't expose merge
///   ranges. The model gets the value of the top-left cell of each
///   merge; the rest are empty.
public struct XlsxReadTool: BuiltinTool {
    public let name: ToolName = "xlsx.read"

    public static let maxBytes = 256 * 1024
    public static let defaultMaxRows = 1000
    public static let maxMaxRows = 10_000
    public static let defaultMaxCols = 50
    public static let maxMaxCols = 200

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: """
                Read a local Excel `.xlsx` file. Arguments: \
                {"path": "<absolute or ~/-relative path>", \
                "sheet": "<name>", "format": "tsv", "maxRows": \(Self.defaultMaxRows), \
                "maxCols": \(Self.defaultMaxCols)}. \
                `sheet` is optional; default is the first sheet in the workbook. \
                If you pass a name that doesn't exist, the error message lists \
                the available sheet names. \
                `format` is optional, default `"tsv"` (tab-separated, one row \
                per line). Pass `"json"` for a `[[...], [...]]` array of arrays \
                of cell values (strings, numbers, booleans). \
                `maxRows` / `maxCols` cap the slice (defaults \(Self.defaultMaxRows) / \
                \(Self.defaultMaxCols); maxes \(Self.maxMaxRows) / \(Self.maxMaxCols)). \
                Output is capped at \(Self.maxBytes) bytes; truncated reads end \
                with a marker so the model can re-call with a tighter slice. \
                Formulas return their cached value, not the formula text. Date \
                cells return the raw serial number (Excel's day-since-1900); \
                interpret accordingly if you know a column is dates.
                """
        )
    }

    public let allowedRoots: [URL]

    public init(allowedRoots: [URL]) {
        self.allowedRoots = allowedRoots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
    }

    public enum Format: String, Decodable {
        case tsv
        case json
    }

    private struct Args: Decodable {
        let path: String
        let sheet: String?
        let format: Format?
        let maxRows: Int?
        let maxCols: Int?
    }

    public func invoke(arguments: String) async throws -> ToolResult {
        let parsed: Args
        do {
            parsed = try JSONDecoder().decode(Args.self, from: Data(arguments.utf8))
        } catch {
            return ToolResult(output: "", error: "could not parse arguments: \(error.localizedDescription)")
        }

        // Sandbox check — same logic as fs.read / pdf.extract.
        let expanded = (parsed.path as NSString).expandingTildeInPath
        let candidate = URL(fileURLWithPath: expanded)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard !allowedRoots.isEmpty else {
            return ToolResult(output: "", error: "xlsx.read is not configured: no allowed roots")
        }
        let allowed = allowedRoots.contains { root in
            candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")
        }
        guard allowed else {
            return ToolResult(output: "", error: "path is outside the allowed sandbox")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
            return ToolResult(output: "", error: "no such file: \(parsed.path)")
        }
        if isDirectory.boolValue {
            return ToolResult(output: "", error: "path is a directory, not a file")
        }

        let format = parsed.format ?? .tsv
        let maxRows = max(1, min(Self.maxMaxRows, parsed.maxRows ?? Self.defaultMaxRows))
        let maxCols = max(1, min(Self.maxMaxCols, parsed.maxCols ?? Self.defaultMaxCols))

        // Open the file. CoreXLSX returns nil for "couldn't read /
        // not a valid xlsx" — the same model recovery applies (try
        // a different file).
        guard let xlsx = XLSXFile(filepath: candidate.path) else {
            return ToolResult(output: "", error: "could not open as xlsx (corrupt or not an xlsx file)")
        }

        let workbooks: [Workbook]
        let sharedStrings: SharedStrings?
        let sheetIndex: [(name: String?, path: String)]
        do {
            workbooks = try xlsx.parseWorkbooks()
            sharedStrings = try xlsx.parseSharedStrings()
            // Flatten across workbooks (typically one). Each entry
            // pairs the user-facing sheet name with its internal XML
            // path used by `parseWorksheet`.
            sheetIndex = try workbooks.flatMap { wb in
                try xlsx.parseWorksheetPathsAndNames(workbook: wb)
                    .map { (name: $0.name, path: $0.path) }
            }
        } catch {
            return ToolResult(output: "", error: "could not parse xlsx structure: \(error.localizedDescription)")
        }
        guard !sheetIndex.isEmpty else {
            return ToolResult(output: "", error: "xlsx contains no worksheets")
        }

        // Sheet selection: requested name → first sheet → error.
        let chosen: (name: String?, path: String)
        if let requested = parsed.sheet {
            guard let match = sheetIndex.first(where: { ($0.name ?? "") == requested }) else {
                let available = sheetIndex.compactMap(\.name).joined(separator: ", ")
                return ToolResult(
                    output: "",
                    error: "no sheet named '\(requested)'. Available: \(available.isEmpty ? "<unnamed>" : available)"
                )
            }
            chosen = match
        } else {
            chosen = sheetIndex[0]
        }

        let worksheet: Worksheet
        do {
            worksheet = try xlsx.parseWorksheet(at: chosen.path)
        } catch {
            return ToolResult(output: "", error: "could not parse sheet '\(chosen.name ?? "<default>")': \(error.localizedDescription)")
        }

        // Build a row-major matrix of cell values. Sparse cells (no
        // entry in the source XML) default to empty strings — that's
        // what the model expects for a tabular view, and it
        // round-trips through `xlsx.write`'s `.empty` case.
        let rows = worksheet.data?.rows ?? []
        var matrix: [[String]] = []
        matrix.reserveCapacity(min(rows.count, maxRows))
        for row in rows.prefix(maxRows) {
            // Cells in CoreXLSX are sparse — a row with values in
            // columns A and D has three cells (A, D), not four.
            // Build a column-indexed dict, then walk 0..<maxCols to
            // densify with empty strings for the gaps.
            var byColumn: [Int: String] = [:]
            for cell in row.cells {
                let col = Self.columnIndex(from: cell.reference.column.value)
                guard col >= 0, col < maxCols else { continue }
                byColumn[col] = stringValue(of: cell, sharedStrings: sharedStrings)
            }
            // The matrix's column count is the max column index seen
            // across all rows up to this point — same shape as Excel
            // shows. We use the rowʼs widest column or the running
            // max so each row's array length matches the others when
            // we serialise.
            let widest = byColumn.keys.max().map { $0 + 1 } ?? 0
            var rowOut: [String] = []
            rowOut.reserveCapacity(widest)
            for c in 0..<widest {
                rowOut.append(byColumn[c] ?? "")
            }
            matrix.append(rowOut)
        }

        // Pad each row to the matrix-wide column count so the
        // serialised output is rectangular. Lossless: empty strings
        // in trailing columns just mean "no cell at that location."
        let widest = matrix.map(\.count).max() ?? 0
        for i in matrix.indices {
            while matrix[i].count < widest {
                matrix[i].append("")
            }
        }

        let serialised: String
        switch format {
        case .tsv:
            serialised = matrix.map { row in
                row.map { Self.sanitiseTSVCell($0) }.joined(separator: "\t")
            }.joined(separator: "\n")
        case .json:
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let payload = try encoder.encode(matrix)
                serialised = String(decoding: payload, as: UTF8.self)
            } catch {
                return ToolResult(output: "", error: "could not encode matrix: \(error.localizedDescription)")
            }
        }

        if serialised.utf8.count > Self.maxBytes {
            let marker = "\n\n[... truncated at \(Self.maxBytes) bytes; re-call with a smaller maxRows/maxCols ...]"
            let budget = Self.maxBytes - marker.utf8.count
            var truncated = serialised
            while truncated.utf8.count > budget {
                truncated.removeLast()
            }
            truncated.append(marker)
            return ToolResult(output: truncated)
        }

        return ToolResult(output: serialised)
    }

    /// Convert a column letter (`"A"`, `"AA"`, `"BC"`) to a 0-indexed
    /// column number. Excel-style base-26 with A=1, returned as
    /// 0-indexed here.
    static func columnIndex(from letters: String) -> Int {
        var n = 0
        for char in letters.uppercased() {
            guard let scalar = char.unicodeScalars.first?.value, scalar >= 65, scalar <= 90 else {
                return -1
            }
            n = n * 26 + Int(scalar - 64)
        }
        return n - 1
    }

    /// Resolve a cell to its display string. Mirrors what Excel
    /// shows in the cell on file open. The branches in priority:
    /// 1. Shared-string cell (`type == "s"`): look up via
    ///    `stringValue(sharedStrings)`.
    /// 2. Inline string cell (`type == "str"` / `inlineStr`): the
    ///    value is the literal string already.
    /// 3. Boolean (`type == "b"`): "TRUE" / "FALSE".
    /// 4. Number / formula cached value: the raw `value` string,
    ///    falling back to "" when CoreXLSX gives us nil (rare;
    ///    happens for explicitly-empty cells).
    private func stringValue(of cell: Cell, sharedStrings: SharedStrings?) -> String {
        if let ss = sharedStrings, let resolved = cell.stringValue(ss) {
            return resolved
        }
        // CoreXLSX's `inlineString.text` is the inline-string value
        // when the cell has `type="inlineStr"`. Falls through to
        // `value` for plain numeric / formula cells.
        if let inline = cell.inlineString?.text {
            return inline
        }
        if let raw = cell.value {
            // Cell type "b" → boolean, stored as "0" / "1"; render
            // as TRUE/FALSE for consistency with `csv.write`'s output.
            if cell.type == .bool {
                return raw == "1" ? "TRUE" : "FALSE"
            }
            return raw
        }
        return ""
    }

    /// Replace tab / CR / LF in a TSV cell with a single space.
    /// Same convention as `tsv.write` (round-trip-safe).
    static func sanitiseTSVCell(_ s: String) -> String {
        var out = s
        for c: Character in ["\t", "\r", "\n"] {
            out = out.replacingOccurrences(of: String(c), with: " ")
        }
        return out
    }
}
