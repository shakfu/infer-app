# SQLiteVec patches

We vendor [jkrukowski/SQLiteVec](https://github.com/jkrukowski/SQLiteVec) at `thirdparty/SQLiteVec/` because upstream has four issues that either break our build outright or produce silently-wrong behavior at runtime. This doc records each patch, the reason it's needed, and what to re-apply if/when the vendored copy is bumped.

**Upstream version at time of vendoring**: tagged `0.0.14` (cloned from `main` shortly after that tag; no local modifications to the tag itself).

If upstream fixes any of these, remove the corresponding patch here and update the "Upstream version" line above.

---

## 1. `sqlite3ext.h` moved out of the public include directory

**File**: `Sources/CSQLiteVec/sqlite3ext.h` (was `Sources/CSQLiteVec/include/sqlite3ext.h`).

**Why.** Upstream exposes both `sqlite3.h` and `sqlite3ext.h` via the `include/` directory. SwiftPM's auto-generated module map for the `CSQLiteVec` C target makes every `.h` in `include/` publicly visible. That's fine under `swift build`, which compiles each target in isolation, but **xcodebuild** pulls sibling-target public headers into dependent targets' Clang search paths. When the `Infer` target also links `GRDB` (which has its own `GRDBSQLite` shim expecting Apple's system SQLite headers), the Clang module processor finds `sqlite3ext.h` and activates its `sqlite3_db_config → sqlite3_api->db_config` macro redirection inside GRDB's compile unit. `sqlite3_api` isn't in scope there — the compile fails:

```
GRDBSQLite/shim.h:15:5: error: use of undeclared identifier 'sqlite3_api'
  sqlite3_db_config(db, SQLITE_DBCONFIG_DQS_DDL, 0, (void *)0);
```

**Fix.** Move `sqlite3ext.h` out of `include/` into the sibling source directory. SQLiteVec's own `sqlite-vec.c` still reaches it via `#include "sqlite3ext.h"` (local quoted include resolves next to the `.c` file). It's no longer a public header, so the Clang module map doesn't umbrella it, and GRDB's compile unit only sees Apple's system `sqlite3.h`.

**To re-apply on a bump.**

```sh
mv thirdparty/SQLiteVec/Sources/CSQLiteVec/include/sqlite3ext.h \
   thirdparty/SQLiteVec/Sources/CSQLiteVec/sqlite3ext.h
```

---

## 2. `Package.swift` macOS platform floor raised `10_15` → `14`

**File**: `Package.swift`.

**Why.** Upstream declares `.macOS(.v10_15)`. `Database.modifiedRowsCount` calls `sqlite3_changes64`, which Swift's availability model marks as macOS 12.3+ only. Under Swift's strict availability checking, compiling SQLiteVec against the declared 10.15 floor fails:

```
error: 'sqlite3_changes64' is only available in macOS 12.3 or newer
```

The bundled SQLite amalgamation actually has the symbol unconditionally — this is a purely declarative mismatch in the upstream `Package.swift`.

**Fix.** Bump the platform floor in the vendored Package.swift to match the Infer app's own minimum (macOS 14). Swift now sees the symbol as always-available for the set of platforms we care about.

**To re-apply on a bump.** Edit `thirdparty/SQLiteVec/Package.swift`:

```swift
platforms: [
    .iOS(.v13),
    .watchOS(.v6),
    .tvOS(.v13),
    .macOS(.v14),   // was .v10_15
],
```

---

## 3. `Database.execute(_ stmt:)` passes the DB handle to `SQLiteVecError.check`

**File**: `Sources/SQLiteVec/Database.swift`, function `private func execute(_ stmt: OpaquePointer)`.

**Why.** Upstream's private `execute` calls:

```swift
try SQLiteVecError.check(sqlite3_step(stmt))  // no handle passed
```

`SQLiteVecError.check(_:_:)` only fetches the `sqlite3_errmsg` text when a handle is provided. Without it, any statement-level failure surfaces as just `"Error N"` with no message — every CONSTRAINT violation, schema error, or binding failure shows the user a bare error code and forces round-trip debugging. The first two bugs in our build manifested exactly this way ("Error 19" instead of "NOT NULL constraint failed: workspace_meta.created_at") and took longer than they should have to localize.

**Fix.** Pass `handler.handle` so `check` can read `sqlite3_errmsg` and attach the actual SQLite message to the thrown `SQLiteVecError`.

**To re-apply on a bump.**

```swift
private func execute(_ stmt: OpaquePointer) throws {
    defer { sqlite3_finalize(stmt) }
    try SQLiteVecError.check(sqlite3_step(stmt), handler.handle)
    //                                        ^^^^^^^^^^^^^^ added
}
```

---

## 4. `Database.prepare` param binding adds `Int64` case; `Int` case uses `bind_int64`

**File**: `Sources/SQLiteVec/Database.swift`, `private func prepare(_:params:)`.

**Why.** The upstream `switch param` only handles `String`, `Data`, `Bool`, `Double`, `Int`, `[Float]`, `[Int8]`, `[Bool]`. `Int64` is not a case — Swift treats `Int64` and `Int` as distinct types (even though they share representation on 64-bit platforms, a value typed as `Int64` does not match `case let value as Int`). Any `Int64` parameter falls into `default` and binds as **NULL**.

This is catastrophic for our use case: vault/workspace ids, `lastInsertRowId`, and `Date().timeIntervalSince1970` values are all `Int64`. Inserting a row with an `Int64` FK silently writes NULL; a `NOT NULL` column then throws a CONSTRAINT error far from the root cause.

Additionally, the upstream `Int` case narrows to `Int32`:

```swift
case let value as Int:
    result = sqlite3_bind_int(stmt, Int32(index + 1), Int32(value))  // narrows!
```

`Int` on Apple's 64-bit platforms is `Int64`-wide. Narrowing to `Int32` silently truncates any value ≥ 2³¹ — e.g., recent Unix timestamps don't fit, and large rowids wrap.

**Fix.** Add an `Int64` case before the `Int` case (order matters so `Int64` isn't shadowed on platforms where the two types are distinct), and route both through `sqlite3_bind_int64`. SQLite stores integers as 64-bit internally; there's no reason to narrow.

**To re-apply on a bump.** In `prepare`'s `switch param` block, replace the `Int` case with:

```swift
// Patched: upstream only handled `Int` and narrowed to `Int32`.
// `Int64` fell into `default` and bound as NULL, silently losing
// rowids, timestamps, and auto-increment ids at every call site.
// And narrowing `Int` to `Int32` truncates values > 2^31. Both
// cases now go through `bind_int64`, which is what SQLite uses
// internally anyway. Order matters: `Int64` first so the `Int`
// case doesn't shadow it on platforms where they're distinct.
case let value as Int64:
    result = sqlite3_bind_int64(stmt, Int32(index + 1), value)
case let value as Int:
    result = sqlite3_bind_int64(stmt, Int32(index + 1), Int64(value))
```

---

## Upstreaming

Patches 3 and 4 are clear bugs and worth filing upstream as issues or PRs:

- **Patch 3** — one-line fix, no behavior change for successful calls, strictly improves error reporting.
- **Patch 4** — adds an `Int64` case and eliminates silent truncation. The only semantic change is that `Int` values > 2³¹ now bind correctly instead of being truncated. No existing caller that was working will break; callers that were silently getting truncated values will now get correct ones.

Patch 1 is a SwiftPM / xcodebuild interaction; arguably a CSQLiteVec packaging change that could go upstream (move `sqlite3ext.h` to a non-public location) but the motivation only applies when CSQLiteVec shares a binary with another SQLite consumer — low-priority for upstream.

Patch 2 is non-essential for upstream to apply (they support older macOS; we don't).
