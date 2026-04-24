import Foundation
import SQLiteVec

/// Namespace for RAG-wide lifecycle hooks. Exists so the app target
/// (`Infer`) can initialize the vector-extension machinery without
/// importing `SQLiteVec` itself — which would drag its CSQLiteVec
/// C headers into the Infer target's compile unit and collide with
/// GRDB's system-SQLite shims.
///
/// Keeping the SQLiteVec boundary inside `InferRAG` isolates the two
/// SQLite worlds: GRDB (Apple system SQLite, used by the vault) and
/// SQLiteVec (bundled SQLite with sqlite-vec statically linked, used
/// by the vector store). They coexist fine at runtime but can't
/// share a compile unit without header conflicts.
public enum RAG {
    /// Idempotent wrapper over `SQLiteVec.initialize()`. Registers
    /// the vec0 extension with SQLiteVec's bundled SQLite so every
    /// subsequent `Database(...)` open picks it up. Call once from
    /// `AppDelegate.applicationDidFinishLaunching`.
    public static func initialize() throws {
        try SQLiteVec.initialize()
    }
}
