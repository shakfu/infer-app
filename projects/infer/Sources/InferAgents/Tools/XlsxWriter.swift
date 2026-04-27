import Foundation
import libxlsxwriter

/// Thin Swift shim around the libxlsxwriter C API. Existence rationale
/// in `Tools/SpreadsheetWriteTools.swift` and the project changelog —
/// short version: there's a Swift wrapper out there
/// (`damuellen/xlsxwriter.swift`) but its `Workbook.close()` calls
/// `fatalError` on any error, which is unacceptable in a long-running
/// chat process. Wrapping the ~12 C functions we need ourselves takes
/// ~120 lines and gives us proper `throws` semantics.
///
/// Lifecycle:
/// 1. `XlsxWorkbook(path:)` opens the file for writing.
/// 2. Add worksheets, write cells, optionally add bold/header
///    formatting via `addBoldFormat()`.
/// 3. **`try workbook.close()` is mandatory.** Most write errors
///    (disk full, permission denied, invalid sheet name) only surface
///    here when libxlsxwriter serialises XML and zips it together.
///    A workbook that's not closed leaks the underlying allocations
///    AND produces no file. The shim does NOT auto-close in deinit —
///    silently ignoring errors at deinit time would mask exactly the
///    failures `close()` is meant to surface.
///
/// Memory: libxlsxwriter owns the workbook + its descendants. The
/// `Workbook` struct holds the opaque C pointer; the C library frees
/// every worksheet, format, and chart on `workbook_close`. That's why
/// the worksheet / format wrappers are non-owning value types — their
/// lifetime is tied to the workbook's.

public enum XlsxError: Error, CustomStringConvertible, Sendable {
    case openFailed(path: String)
    case writeFailed(message: String, row: Int, col: Int)
    case closeFailed(message: String)
    case invalidSheetName(String)

    public var description: String {
        switch self {
        case .openFailed(let path):
            return "could not open xlsx for writing: \(path)"
        case .writeFailed(let message, let row, let col):
            return "write failed at (row \(row), col \(col)): \(message)"
        case .closeFailed(let message):
            return "close failed: \(message)"
        case .invalidSheetName(let name):
            return "invalid sheet name '\(name)'"
        }
    }
}

/// One xlsx file in flight. Holds the underlying `lxw_workbook*`.
public final class XlsxWorkbook {
    private var ptr: OpaquePointer?
    private(set) var closed = false

    public init(path: String) throws {
        guard let p = path.withCString({ workbook_new($0) }) else {
            throw XlsxError.openFailed(path: path)
        }
        // `workbook_new` returns a pointer to `lxw_workbook`. Swift's
        // imported type is `UnsafeMutablePointer<lxw_workbook>?`. We
        // erase to OpaquePointer so the rest of the shim doesn't have
        // to thread through the imported struct names everywhere.
        self.ptr = OpaquePointer(p)
    }

    /// Close the workbook and write its contents to disk. Throws on
    /// the failures that only manifest at close time (encoding
    /// errors, zip write failures, sheet-naming clashes
    /// libxlsxwriter validates lazily).
    public func close() throws {
        guard !closed, let p = ptr else { return }
        let err = workbook_close(UnsafeMutablePointer(p))
        closed = true
        ptr = nil
        if err.rawValue != 0 {
            let cstr = lxw_strerror(err)
            let message = cstr.map { String(cString: $0) } ?? "unknown error \(err.rawValue)"
            throw XlsxError.closeFailed(message: message)
        }
    }

    public func addWorksheet(name: String? = nil) throws -> XlsxWorksheet {
        guard let workbook = ptr else {
            throw XlsxError.closeFailed(message: "workbook is already closed")
        }
        let wb = UnsafeMutablePointer<lxw_workbook>(workbook)
        let raw: UnsafeMutablePointer<lxw_worksheet>?
        if let name = name {
            // Validate locally before letting libxlsxwriter fail at
            // close time — its sheet-name validation is permissive at
            // creation but enforces uniqueness + character rules
            // during serialisation. Catching the obvious cases here
            // surfaces a useful error message immediately.
            guard !name.isEmpty, name.count <= 31,
                  !name.contains(where: { ":\\/?*[]".contains($0) }) else {
                throw XlsxError.invalidSheetName(name)
            }
            raw = name.withCString { workbook_add_worksheet(wb, $0) }
        } else {
            raw = workbook_add_worksheet(wb, nil)
        }
        guard let ws = raw else {
            throw XlsxError.invalidSheetName(name ?? "<default>")
        }
        return XlsxWorksheet(ptr: ws)
    }

    /// Returns a non-owning bold-text format. Pass to
    /// `XlsxWorksheet.write(...)` for any cell that should render in
    /// bold (e.g. a header row). The format is owned by the workbook
    /// and freed automatically on close.
    public func addBoldFormat() -> XlsxFormat {
        guard let workbook = ptr else { return XlsxFormat(ptr: nil) }
        let wb = UnsafeMutablePointer<lxw_workbook>(workbook)
        let fmt = workbook_add_format(wb)
        if let fmt { format_set_bold(fmt) }
        return XlsxFormat(ptr: fmt)
    }

    deinit {
        // Defensive cleanup if the caller forgot to `try close()`.
        // We can't throw from deinit, so we silently free the
        // workbook to avoid the leak. The file may be incomplete or
        // missing — that's the caller's bug, not ours to mask further.
        if !closed, let p = ptr {
            _ = workbook_close(UnsafeMutablePointer(p))
        }
    }
}

/// Non-owning worksheet handle. Lifetime is tied to the parent
/// `XlsxWorkbook` (libxlsxwriter frees worksheets in `workbook_close`).
public struct XlsxWorksheet {
    fileprivate let ptr: UnsafeMutablePointer<lxw_worksheet>

    /// Cell value the shim knows how to write. Maps onto
    /// libxlsxwriter's `worksheet_write_*` family.
    public enum Cell: Sendable {
        case empty
        case text(String)
        case number(Double)
        /// Excel formula. Pass without the leading `=` *or* with it —
        /// the shim strips a leading `=` to match libxlsxwriter's
        /// expectation. Example: `.formula("SUM(A1:A10)")`.
        case formula(String)
        case bool(Bool)
    }

    public func write(row: Int, col: Int, value: Cell, format: XlsxFormat? = nil) throws {
        let r = lxw_row_t(row)
        let c = lxw_col_t(col)
        let fmt = format?.ptr
        let err: lxw_error
        switch value {
        case .empty:
            err = worksheet_write_blank(ptr, r, c, fmt)
        case .text(let s):
            err = s.withCString { worksheet_write_string(ptr, r, c, $0, fmt) }
        case .number(let n):
            err = worksheet_write_number(ptr, r, c, n, fmt)
        case .formula(let raw):
            let trimmed = raw.hasPrefix("=") ? String(raw.dropFirst()) : raw
            err = trimmed.withCString { worksheet_write_formula(ptr, r, c, $0, fmt) }
        case .bool(let b):
            err = worksheet_write_boolean(ptr, r, c, b ? 1 : 0, fmt)
        }
        if err.rawValue != 0 {
            let message = lxw_strerror(err).map { String(cString: $0) } ?? "unknown error \(err.rawValue)"
            throw XlsxError.writeFailed(message: message, row: row, col: col)
        }
    }

    /// Freeze panes at `(row, col)` — rows above and columns to the
    /// left of the split point stay visible while scrolling. Most
    /// common use: `freezePanes(row: 1, col: 0)` to keep the header
    /// row pinned.
    public func freezePanes(row: Int, col: Int) {
        worksheet_freeze_panes(ptr, lxw_row_t(row), lxw_col_t(col))
    }

    /// Set the column width (in Excel's character-width units) for
    /// columns `[first, last]` inclusive. Useful for keeping header
    /// columns from looking squished. Ignored on error (libxlsxwriter
    /// only fails this for out-of-range column indices we already
    /// guard against).
    public func setColumnWidth(first: Int, last: Int, width: Double) {
        _ = worksheet_set_column(ptr, lxw_col_t(first), lxw_col_t(last), width, nil)
    }
}

/// Non-owning format handle. Returned by `XlsxWorkbook.addBoldFormat`
/// (and any future format helpers). Holds an opaque pointer that's
/// freed by libxlsxwriter on `workbook_close`.
public struct XlsxFormat {
    fileprivate let ptr: UnsafeMutablePointer<lxw_format>?
}
