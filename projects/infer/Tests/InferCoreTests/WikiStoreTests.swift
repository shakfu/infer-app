import XCTest
@testable import InferCore

final class WikiLinkResolverExtractTests: XCTestCase {
    func testSimpleLink() {
        XCTAssertEqual(
            WikiLinkResolver.extractLinks(from: "See [[Other Page]] for context."),
            ["Other Page"]
        )
    }

    func testAliasedLinkUsesTargetNotAlias() {
        XCTAssertEqual(
            WikiLinkResolver.extractLinks(from: "See [[Real Target|the alias]]."),
            ["Real Target"]
        )
    }

    func testSectionFragmentStripped() {
        XCTAssertEqual(
            WikiLinkResolver.extractLinks(from: "Jump to [[Page A#section]]."),
            ["Page A"]
        )
    }

    func testMultipleLinksDedupedCaseInsensitive() {
        let body = "See [[Page A]], also [[page a]] and [[Page B]]."
        XCTAssertEqual(
            WikiLinkResolver.extractLinks(from: body),
            ["Page A", "Page B"]
        )
    }

    func testFencedCodeBlockSkipsLinks() {
        let body = """
            Real [[Linked]].
            ```
            example: [[Not A Link]]
            ```
            """
        XCTAssertEqual(
            WikiLinkResolver.extractLinks(from: body),
            ["Linked"]
        )
    }

    func testInlineCodeSkipsLinks() {
        XCTAssertEqual(
            WikiLinkResolver.extractLinks(from: "Use `[[notalink]]` here, but [[real]] there."),
            ["real"]
        )
    }

    func testEmbedSyntaxResolvesSamePage() {
        // ![[Page]] is an embed; the target is still extracted because
        // the resolver only cares about reachability.
        XCTAssertEqual(
            WikiLinkResolver.extractLinks(from: "![[Embedded]]"),
            ["Embedded"]
        )
    }

    func testEmptyAndWhitespaceTargetsDropped() {
        XCTAssertEqual(
            WikiLinkResolver.extractLinks(from: "[[]] and [[   ]] are noise"),
            []
        )
    }

    func testUnclosedLinkIgnored() {
        XCTAssertEqual(
            WikiLinkResolver.extractLinks(from: "[[Real]] vs [[unclosed"),
            ["Real"]
        )
    }
}

final class WikiLinkResolverTransitiveTests: XCTestCase {
    private func page(_ id: String, _ content: String) -> WikiPage {
        WikiPage(id: id, url: URL(fileURLWithPath: "/tmp/\(id).md"), content: content)
    }

    func testRootsOnlyWhenNoLinks() {
        let pages = [page("A", "no links"), page("B", "no links")]
        let index = Dictionary(uniqueKeysWithValues: pages.map { ($0.id.lowercased(), $0) })
        let result = WikiLinkResolver.transitiveClosure(roots: ["A"], index: index)
        XCTAssertEqual(result.included.map(\.id), ["A"])
        XCTAssertTrue(result.unresolved.isEmpty)
    }

    func testTransitiveFollowsLinks() {
        let pages = [
            page("A", "See [[B]]."),
            page("B", "Then [[C]]."),
            page("C", "leaf"),
            page("D", "unreachable"),
        ]
        let index = Dictionary(uniqueKeysWithValues: pages.map { ($0.id.lowercased(), $0) })
        let result = WikiLinkResolver.transitiveClosure(roots: ["A"], index: index)
        XCTAssertEqual(Set(result.included.map(\.id)), Set(["A", "B", "C"]))
        XCTAssertFalse(result.included.contains { $0.id == "D" })
    }

    func testCycleDoesNotInfiniteLoop() {
        let pages = [
            page("A", "[[B]]"),
            page("B", "[[A]]"),
        ]
        let index = Dictionary(uniqueKeysWithValues: pages.map { ($0.id.lowercased(), $0) })
        let result = WikiLinkResolver.transitiveClosure(roots: ["A"], index: index)
        XCTAssertEqual(Set(result.included.map(\.id)), Set(["A", "B"]))
    }

    func testUnresolvedLinkReported() {
        let pages = [page("A", "See [[Missing]].")]
        let index = Dictionary(uniqueKeysWithValues: pages.map { ($0.id.lowercased(), $0) })
        let result = WikiLinkResolver.transitiveClosure(roots: ["A"], index: index)
        XCTAssertEqual(result.included.map(\.id), ["A"])
        XCTAssertEqual(result.unresolved.map { $0.lowercased() }, ["missing"])
    }
}

final class WikiStoreTests: XCTestCase {
    private var tempRoot: URL!
    private var store: WikiStore!

    override func setUp() async throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("WikiStoreTests-\(UUID().uuidString)", isDirectory: true)
        store = WikiStore(rootURL: tempRoot)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testSaveListLoadRoundTrip() async throws {
        _ = try await store.savePage(workspaceId: 1, id: "Alpha", content: "# Alpha\n\nbody")
        _ = try await store.savePage(workspaceId: 1, id: "Beta", content: "linked: [[Alpha]]")

        let pages = try await store.listPages(workspaceId: 1)
        XCTAssertEqual(pages.map(\.id), ["Alpha", "Beta"])

        let alpha = try await store.loadPage(workspaceId: 1, id: "Alpha")
        XCTAssertEqual(alpha?.content, "# Alpha\n\nbody")
    }

    func testInvalidIdRejected() async throws {
        do {
            _ = try await store.savePage(workspaceId: 1, id: "../escape", content: "x")
            XCTFail("expected throw on slash in id")
        } catch is WikiError {
            // ok
        }
        do {
            _ = try await store.savePage(workspaceId: 1, id: "  ", content: "x")
            XCTFail("expected throw on empty id")
        } catch is WikiError {
            // ok
        }
    }

    func testPinSetRoundTrip() async throws {
        _ = try await store.savePage(workspaceId: 2, id: "Root", content: "x")
        try await store.setPin(workspaceId: 2, id: "Root", pinned: true)
        let pins = try await store.loadPins(workspaceId: 2)
        XCTAssertEqual(pins, ["Root"])

        try await store.setPin(workspaceId: 2, id: "Root", pinned: false)
        let pinsAfter = try await store.loadPins(workspaceId: 2)
        XCTAssertTrue(pinsAfter.isEmpty)
    }

    func testDeletePageClearsPin() async throws {
        _ = try await store.savePage(workspaceId: 3, id: "Doomed", content: "x")
        try await store.setPin(workspaceId: 3, id: "Doomed", pinned: true)
        try await store.deletePage(workspaceId: 3, id: "Doomed")
        let pins = try await store.loadPins(workspaceId: 3)
        XCTAssertTrue(pins.isEmpty)
        let pages = try await store.listPages(workspaceId: 3)
        XCTAssertTrue(pages.isEmpty)
    }

    func testBuildContextNoPinsReturnsEmpty() async throws {
        _ = try await store.savePage(workspaceId: 4, id: "Unpinned", content: "x")
        let ctx = try await store.buildContext(workspaceId: 4)
        XCTAssertEqual(ctx, .empty)
    }

    func testBuildContextIncludesOnlyPinned() async throws {
        // Phase 5: pins now mean "inject this exact page" — no
        // transitive [[wikilink]] expansion at injection time. The
        // rest of the wiki is reachable via RAG retrieval.
        _ = try await store.savePage(workspaceId: 5, id: "Pinned",
            content: "see [[Linked]] and [[Other]]")
        _ = try await store.savePage(workspaceId: 5, id: "Linked", content: "leaf [[Deep]]")
        _ = try await store.savePage(workspaceId: 5, id: "Deep", content: "deepest")
        _ = try await store.savePage(workspaceId: 5, id: "Other", content: "sibling")
        _ = try await store.savePage(workspaceId: 5, id: "Unreachable", content: "not linked")
        try await store.setPin(workspaceId: 5, id: "Pinned", pinned: true)

        let ctx = try await store.buildContext(workspaceId: 5)
        XCTAssertEqual(Set(ctx.pageIds), Set(["Pinned"]))
        XCTAssertFalse(ctx.pageIds.contains("Linked"))
        XCTAssertFalse(ctx.pageIds.contains("Unreachable"))
        XCTAssertTrue(ctx.text.contains("<wiki_context>"))
        XCTAssertTrue(ctx.text.contains("## Pinned"))
    }

    func testBuildContextIgnoresBudgetForPinnedSet() async throws {
        // Phase 5: budgetTokens is informational, not enforced. The
        // hard cap is on the pin set itself (max 20). A pinned page
        // bigger than `budgetTokens` is fully included.
        let huge = String(repeating: "x", count: 80_000)
        _ = try await store.savePage(workspaceId: 7, id: "Big", content: huge)
        try await store.setPin(workspaceId: 7, id: "Big", pinned: true)
        let ctx = try await store.buildContext(workspaceId: 7, budgetTokens: 1000)
        XCTAssertEqual(ctx.pageIds, ["Big"])
    }

    func testBuildContextSkipsMissingPinnedPages() async throws {
        // Pin set persisted but the file was deleted out from under
        // it — context build should skip silently rather than throw.
        try await store.setPin(workspaceId: 8, id: "Phantom", pinned: true)
        let ctx = try await store.buildContext(workspaceId: 8)
        XCTAssertTrue(ctx.pageIds.isEmpty)
    }

    func testNestedPathSaveAndList() async throws {
        _ = try await store.savePage(workspaceId: 30, id: "Notes/Daily/2026-05-07", content: "today")
        _ = try await store.savePage(workspaceId: 30, id: "Notes/Index", content: "index")
        _ = try await store.savePage(workspaceId: 30, id: "RootPage", content: "root")

        let pages = try await store.listPages(workspaceId: 30)
        XCTAssertEqual(
            Set(pages.map(\.id)),
            Set(["Notes/Daily/2026-05-07", "Notes/Index", "RootPage"])
        )
    }

    func testCreateAndDeleteFolder() async throws {
        try await store.createFolder(workspaceId: 31, path: "Empty")
        let folders = try await store.listFolders(workspaceId: 31)
        XCTAssertEqual(folders, ["Empty"])
        try await store.deleteFolder(workspaceId: 31, path: "Empty")
        let after = try await store.listFolders(workspaceId: 31)
        XCTAssertTrue(after.isEmpty)
    }

    func testDeleteFolderRemovesNestedPagesAndPins() async throws {
        _ = try await store.savePage(workspaceId: 32, id: "Folder/Page1", content: "x")
        _ = try await store.savePage(workspaceId: 32, id: "Folder/Sub/Page2", content: "y")
        _ = try await store.savePage(workspaceId: 32, id: "Other", content: "z")
        try await store.setPin(workspaceId: 32, id: "Folder/Page1", pinned: true)
        try await store.setPin(workspaceId: 32, id: "Folder/Sub/Page2", pinned: true)
        try await store.setPin(workspaceId: 32, id: "Other", pinned: true)

        try await store.deleteFolder(workspaceId: 32, path: "Folder")

        let pages = try await store.listPages(workspaceId: 32)
        XCTAssertEqual(pages.map(\.id), ["Other"])
        let pins = try await store.loadPins(workspaceId: 32)
        XCTAssertEqual(pins, ["Other"])
    }

    func testValidatePathRejectsTraversal() {
        XCTAssertThrowsError(try WikiStore.validatePath(""))
        XCTAssertThrowsError(try WikiStore.validatePath("/abs"))
        XCTAssertThrowsError(try WikiStore.validatePath("../escape"))
        XCTAssertThrowsError(try WikiStore.validatePath("a/../b"))
        XCTAssertThrowsError(try WikiStore.validatePath("a//b"))
        XCTAssertThrowsError(try WikiStore.validatePath(".hidden/p"))
    }

    func testValidatePathAllowsNestedPaths() throws {
        XCTAssertNoThrow(try WikiStore.validatePath("a"))
        XCTAssertNoThrow(try WikiStore.validatePath("a/b"))
        XCTAssertNoThrow(try WikiStore.validatePath("a/b/c"))
        XCTAssertNoThrow(try WikiStore.validatePath("Notes/Daily/2026-05-07"))
    }

    func testTransitiveClosureBasenameFallback() {
        let pages = [
            WikiPage(id: "Folder/Linked", url: URL(fileURLWithPath: "/tmp/x.md"), content: ""),
            WikiPage(id: "Pinned", url: URL(fileURLWithPath: "/tmp/p.md"),
                     content: "see [[Linked]]"),
        ]
        let index = Dictionary(uniqueKeysWithValues: pages.map { ($0.id.lowercased(), $0) })
        let result = WikiLinkResolver.transitiveClosure(roots: ["Pinned"], index: index)
        XCTAssertEqual(Set(result.included.map(\.id)), Set(["Pinned", "Folder/Linked"]))
    }

    func testPathQualifiedLinkResolvesToExact() {
        let pages = [
            WikiPage(id: "Folder/Page", url: URL(fileURLWithPath: "/x.md"), content: ""),
            WikiPage(id: "Other/Page", url: URL(fileURLWithPath: "/y.md"), content: ""),
            WikiPage(id: "Pinned", url: URL(fileURLWithPath: "/p.md"),
                     content: "[[Other/Page]]"),
        ]
        let index = Dictionary(uniqueKeysWithValues: pages.map { ($0.id.lowercased(), $0) })
        let result = WikiLinkResolver.transitiveClosure(roots: ["Pinned"], index: index)
        XCTAssertTrue(result.included.contains { $0.id == "Other/Page" })
        XCTAssertFalse(result.included.contains { $0.id == "Folder/Page" })
    }

    func testMovePageRoundTrip() async throws {
        _ = try await store.savePage(workspaceId: 40, id: "Loose", content: "body")
        let moved = try await store.movePage(
            workspaceId: 40, from: "Loose", to: "Folder/Loose"
        )
        XCTAssertEqual(moved.id, "Folder/Loose")
        let pages = try await store.listPages(workspaceId: 40)
        XCTAssertEqual(pages.map(\.id), ["Folder/Loose"])
    }

    func testMovePageCarriesPin() async throws {
        _ = try await store.savePage(workspaceId: 41, id: "Pinned", content: "x")
        try await store.setPin(workspaceId: 41, id: "Pinned", pinned: true)
        _ = try await store.movePage(
            workspaceId: 41, from: "Pinned", to: "Notes/Pinned"
        )
        let pins = try await store.loadPins(workspaceId: 41)
        XCTAssertEqual(pins, ["Notes/Pinned"])
    }

    func testMovePageRewritesInboundLinks() async throws {
        _ = try await store.savePage(workspaceId: 42, id: "Target", content: "ok")
        _ = try await store.savePage(
            workspaceId: 42, id: "Sibling",
            content: "see [[Target]] and [[target|alias]]"
        )
        _ = try await store.movePage(
            workspaceId: 42, from: "Target", to: "Folder/Target"
        )
        let sibling = try await store.loadPage(workspaceId: 42, id: "Sibling")
        XCTAssertEqual(
            sibling?.content,
            "see [[Folder/Target]] and [[Folder/Target|alias]]"
        )
    }

    func testMovePageRefusesToOverwrite() async throws {
        _ = try await store.savePage(workspaceId: 43, id: "A", content: "1")
        _ = try await store.savePage(workspaceId: 43, id: "Folder/A", content: "2")
        do {
            _ = try await store.movePage(workspaceId: 43, from: "A", to: "Folder/A")
            XCTFail("expected overwrite refusal")
        } catch is WikiError {
            // ok
        }
        // Both pages must still be present.
        let pages = try await store.listPages(workspaceId: 43)
        XCTAssertEqual(Set(pages.map(\.id)), Set(["A", "Folder/A"]))
    }

    func testMoveFolderRelocatesNestedPagesAndPin() async throws {
        _ = try await store.savePage(workspaceId: 50, id: "Old/A", content: "a")
        _ = try await store.savePage(workspaceId: 50, id: "Old/Sub/B", content: "b")
        _ = try await store.savePage(workspaceId: 50, id: "Other", content: "ref [[A]]")
        try await store.setPin(workspaceId: 50, id: "Old/A", pinned: true)

        let count = try await store.moveFolder(
            workspaceId: 50, from: "Old", to: "New"
        )
        XCTAssertEqual(count, 2)

        let pages = try await store.listPages(workspaceId: 50)
        XCTAssertEqual(
            Set(pages.map(\.id)),
            Set(["New/A", "New/Sub/B", "Other"])
        )

        // Pin carried.
        let pins = try await store.loadPins(workspaceId: 50)
        XCTAssertEqual(pins, ["New/A"])

        // Inbound link rewritten — basename `A` now resolves to
        // New/A, but more importantly, an explicit `[[Old/A]]`
        // would have been rewritten too. Test the explicit form:
        _ = try await store.savePage(workspaceId: 50, id: "Old/A", content: "x")
        // (re-creating an already-moved old path to make sure nothing else broke)
        // Cleanup for clarity:
        try await store.deletePage(workspaceId: 50, id: "Old/A")
    }

    func testMoveFolderRewritesPathQualifiedInboundLinks() async throws {
        _ = try await store.savePage(workspaceId: 51, id: "Old/Page", content: "ok")
        _ = try await store.savePage(
            workspaceId: 51, id: "Reference",
            content: "see [[Old/Page]] for details"
        )
        _ = try await store.moveFolder(
            workspaceId: 51, from: "Old", to: "New"
        )
        let ref = try await store.loadPage(workspaceId: 51, id: "Reference")
        XCTAssertEqual(ref?.content, "see [[New/Page]] for details")
    }

    func testMoveFolderRefusesCycle() async throws {
        _ = try await store.savePage(workspaceId: 52, id: "Top/Page", content: "x")
        do {
            _ = try await store.moveFolder(
                workspaceId: 52, from: "Top", to: "Top/Inner"
            )
            XCTFail("expected cycle refusal")
        } catch is WikiError {
            // ok
        }
    }

    func testMoveFolderRefusesOverwrite() async throws {
        _ = try await store.savePage(workspaceId: 53, id: "A/x", content: "1")
        _ = try await store.savePage(workspaceId: 53, id: "B/y", content: "2")
        do {
            _ = try await store.moveFolder(
                workspaceId: 53, from: "A", to: "B"
            )
            XCTFail("expected overwrite refusal")
        } catch is WikiError {
            // ok
        }
        let pages = try await store.listPages(workspaceId: 53)
        XCTAssertEqual(Set(pages.map(\.id)), Set(["A/x", "B/y"]))
    }

    func testRewriteBodyReplacesSimpleLink() {
        let body = "Refer to [[Old Page]] for context."
        let out = WikiStore.rewriteBody(body, from: "Old Page", to: "New Page")
        XCTAssertEqual(out, "Refer to [[New Page]] for context.")
    }

    func testRewriteBodyPreservesAlias() {
        let body = "See [[Old|the alias]] later."
        let out = WikiStore.rewriteBody(body, from: "Old", to: "New")
        XCTAssertEqual(out, "See [[New|the alias]] later.")
    }

    func testRewriteBodyPreservesSectionFragment() {
        let body = "Jump to [[Old#section]]."
        let out = WikiStore.rewriteBody(body, from: "Old", to: "New")
        XCTAssertEqual(out, "Jump to [[New#section]].")
    }

    func testRewriteBodyPreservesAliasAndFragment() {
        let body = "[[Old#section|nice text]]"
        let out = WikiStore.rewriteBody(body, from: "Old", to: "New")
        XCTAssertEqual(out, "[[New#section|nice text]]")
    }

    func testRewriteBodyCaseInsensitiveMatch() {
        let body = "[[OLD page]] and [[old page]] and [[Old Page]]."
        let out = WikiStore.rewriteBody(body, from: "Old Page", to: "Renamed")
        XCTAssertEqual(out, "[[Renamed]] and [[Renamed]] and [[Renamed]].")
    }

    func testRewriteBodyDoesNotTouchUnrelatedLinks() {
        let body = "[[Other]] should stay."
        let out = WikiStore.rewriteBody(body, from: "Old", to: "New")
        XCTAssertEqual(out, body)
    }

    func testRewriteWikilinksAcrossWorkspace() async throws {
        _ = try await store.savePage(workspaceId: 99, id: "A",
            content: "links to [[Original]]")
        _ = try await store.savePage(workspaceId: 99, id: "B",
            content: "also references [[original|aliased]]")
        _ = try await store.savePage(workspaceId: 99, id: "C", content: "no links here")

        let changed = try await store.rewriteWikilinks(
            workspaceId: 99, from: "Original", to: "Renamed"
        )
        XCTAssertEqual(changed, 2)

        let a = try await store.loadPage(workspaceId: 99, id: "A")
        XCTAssertEqual(a?.content, "links to [[Renamed]]")
        let b = try await store.loadPage(workspaceId: 99, id: "B")
        XCTAssertEqual(b?.content, "also references [[Renamed|aliased]]")
        let c = try await store.loadPage(workspaceId: 99, id: "C")
        XCTAssertEqual(c?.content, "no links here")
    }

    func testWikilinksAreCaseInsensitive() {
        // Phase 5 dropped transitive expansion from buildContext, but
        // the resolver still does case-insensitive matching for
        // autocomplete + future link-graph features. Test against the
        // resolver directly rather than the no-longer-relevant inject
        // path.
        let pages = [
            WikiPage(id: "Pinned", url: URL(fileURLWithPath: "/p.md"),
                     content: "see [[lower case target]]"),
            WikiPage(id: "Lower Case Target", url: URL(fileURLWithPath: "/t.md"),
                     content: "found"),
        ]
        let index = Dictionary(uniqueKeysWithValues: pages.map { ($0.id.lowercased(), $0) })
        let result = WikiLinkResolver.transitiveClosure(roots: ["Pinned"], index: index)
        XCTAssertTrue(result.included.contains { $0.id == "Lower Case Target" })
    }
}
