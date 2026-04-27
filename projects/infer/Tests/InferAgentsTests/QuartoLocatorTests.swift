import XCTest
@testable import InferAgents

final class QuartoLocatorTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quarto-locator-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Drop an executable shim at `path` that prints `output` and exits 0.
    private func makeFakeQuarto(at path: URL, output: String = "1.9.37\n") throws {
        let script = "#!/bin/bash\necho '\(output)'\n"
        try script.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: path.path
        )
    }

    func testOverridePathWinsWhenExecutable() async throws {
        let fake = tempDir.appendingPathComponent("quarto")
        try makeFakeQuarto(at: fake)
        let locator = QuartoLocator(
            override: fake.path,
            commonPaths: [],
            probe: QuartoLocator.defaultProbe
        )
        let install = await locator.resolve()
        XCTAssertNotNil(install)
        XCTAssertEqual(install?.url.path, fake.path)
        XCTAssertEqual(install?.version, "1.9.37")
    }

    func testNonExecutableOverrideFallsThrough() async throws {
        let nonExec = tempDir.appendingPathComponent("not-a-binary")
        try "hello".write(to: nonExec, atomically: true, encoding: .utf8)
        let common = tempDir.appendingPathComponent("common-quarto")
        try makeFakeQuarto(at: common, output: "1.9.0")
        let locator = QuartoLocator(
            override: nonExec.path,
            commonPaths: [common.path],
            // Stub login-shell probe so it returns nothing.
            probe: { exec, args in
                if exec == "/bin/bash" { return (1, "") }
                return await QuartoLocator.defaultProbe(exec, args)
            }
        )
        let install = await locator.resolve()
        XCTAssertEqual(install?.url.path, common.path)
    }

    func testReturnsNilWhenNothingFound() async throws {
        let locator = QuartoLocator(
            override: nil,
            commonPaths: ["\(tempDir.path)/does-not-exist"],
            probe: { _, _ in (1, "") }
        )
        let install = await locator.resolve()
        XCTAssertNil(install)
    }

    func testLoginShellPathIsProbed() async throws {
        let fake = tempDir.appendingPathComponent("quarto")
        try makeFakeQuarto(at: fake, output: "1.9.99")
        let locator = QuartoLocator(
            override: nil,
            commonPaths: [],
            probe: { exec, args in
                // Simulate `bash -lc 'command -v quarto'` returning the fake path.
                if exec == "/bin/bash", args == ["-lc", "command -v quarto"] {
                    return (0, fake.path + "\n")
                }
                return await QuartoLocator.defaultProbe(exec, args)
            }
        )
        let install = await locator.resolve()
        XCTAssertEqual(install?.url.path, fake.path)
        XCTAssertEqual(install?.version, "1.9.99")
    }
}
