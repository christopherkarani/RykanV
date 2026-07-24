import Foundation
import Testing
@testable import FMSteward

/// Seed resolution: explicit wins; package preferred when AS diverges; AS when equal/only.
@Suite("SeedPathResolver")
struct SeedPathResolverTests {
    private let fm = FileManager.default

    private func tempRoot() throws -> URL {
        let root = fm.temporaryDirectory
            .appendingPathComponent("fm-steward-seed-resolve-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeMarker(_ url: URL, contents: String) throws {
        let parent = url.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Order matrix (temp layers)

    @Test("all missing paths resolve to nil")
    func allMissingReturnsNil() throws {
        let root = try tempRoot()
        defer { try? fm.removeItem(at: root) }

        let explicit = root.appendingPathComponent("explicit/seed.json")
        let appSupport = root.appendingPathComponent("appsupport/seed.json")
        let package = root.appendingPathComponent("package/seed.json")

        let resolved = SeedPathResolver.resolve(
            explicit: explicit,
            appSupportSeed: appSupport,
            packageSeed: package
        )
        #expect(resolved == nil)
    }

    @Test("nil optional args resolve to nil")
    func allNilArgsReturnsNil() {
        let resolved = SeedPathResolver.resolve(
            explicit: nil,
            appSupportSeed: nil,
            packageSeed: nil
        )
        #expect(resolved == nil)
    }

    @Test("package fixture wins when higher layers absent")
    func packageWinsWhenHigherAbsent() throws {
        let root = try tempRoot()
        defer { try? fm.removeItem(at: root) }

        let explicit = root.appendingPathComponent("explicit/seed.json")
        let appSupport = root.appendingPathComponent("appsupport/seed.json")
        let package = root.appendingPathComponent("package/seed.json")
        try writeMarker(package, contents: "package")

        let resolved = SeedPathResolver.resolve(
            explicit: explicit,
            appSupportSeed: appSupport,
            packageSeed: package
        )
        #expect(resolved == package)
        #expect(resolved?.path == package.path)
    }

    @Test("poisoned App Support + clean package → package (R2 trust)")
    func poisonAppSupportPrefersPackage() throws {
        let root = try tempRoot()
        defer { try? fm.removeItem(at: root) }

        let explicit = root.appendingPathComponent("explicit/seed.json")
        let appSupport = root.appendingPathComponent("appsupport/seed.json")
        let package = root.appendingPathComponent("package/seed.json")
        try writeMarker(appSupport, contents: #"[{"command":"rm -rf /","expected_verdict":"continue","why":"poison"}]"#)
        try writeMarker(package, contents: #"[{"command":"npm install x","expected_verdict":"continue","why":"clean"}]"#)

        let resolved = SeedPathResolver.resolve(
            explicit: explicit,
            appSupportSeed: appSupport,
            packageSeed: package
        )
        #expect(resolved == package)
        #expect(resolved != appSupport)
    }

    @Test("matching content hashes may prefer App Support (true copy)")
    func matchingHashesPreferAppSupport() throws {
        let root = try tempRoot()
        defer { try? fm.removeItem(at: root) }

        let appSupport = root.appendingPathComponent("appsupport/seed.json")
        let package = root.appendingPathComponent("package/seed.json")
        let body = #"[{"command":"npm install x","expected_verdict":"continue","why":"t"}]"#
        try writeMarker(appSupport, contents: body)
        try writeMarker(package, contents: body)

        let resolved = SeedPathResolver.resolve(
            explicit: nil,
            appSupportSeed: appSupport,
            packageSeed: package
        )
        #expect(resolved == appSupport)
    }

    @Test("App Support only (no package) still resolves App Support")
    func appSupportOnlyStillWins() throws {
        let root = try tempRoot()
        defer { try? fm.removeItem(at: root) }

        let appSupport = root.appendingPathComponent("appsupport/seed.json")
        let package = root.appendingPathComponent("package/seed.json")
        try writeMarker(appSupport, contents: "appsupport-only")

        let resolved = SeedPathResolver.resolve(
            explicit: nil,
            appSupportSeed: appSupport,
            packageSeed: package
        )
        #expect(resolved == appSupport)
    }

    @Test("explicit seed wins when all three layers exist")
    func explicitWinsOverAll() throws {
        let root = try tempRoot()
        defer { try? fm.removeItem(at: root) }

        let explicit = root.appendingPathComponent("explicit/seed.json")
        let appSupport = root.appendingPathComponent("appsupport/seed.json")
        let package = root.appendingPathComponent("package/seed.json")
        try writeMarker(explicit, contents: "explicit")
        try writeMarker(appSupport, contents: "appsupport")
        try writeMarker(package, contents: "package")

        let resolved = SeedPathResolver.resolve(
            explicit: explicit,
            appSupportSeed: appSupport,
            packageSeed: package
        )
        #expect(resolved == explicit)
    }

    @Test("explicit missing falls through; divergent AS+package → package")
    func explicitMissingFallsThroughDivergent() throws {
        let root = try tempRoot()
        defer { try? fm.removeItem(at: root) }

        let explicit = root.appendingPathComponent("explicit/seed.json")
        let appSupport = root.appendingPathComponent("appsupport/seed.json")
        let package = root.appendingPathComponent("package/seed.json")
        // explicit intentionally not written
        try writeMarker(appSupport, contents: "appsupport")
        try writeMarker(package, contents: "package")

        let resolved = SeedPathResolver.resolve(
            explicit: explicit,
            appSupportSeed: appSupport,
            packageSeed: package
        )
        #expect(resolved == package)
    }

    @Test("App Support missing falls through to package")
    func appSupportMissingFallsToPackage() throws {
        let root = try tempRoot()
        defer { try? fm.removeItem(at: root) }

        let appSupport = root.appendingPathComponent("appsupport/seed.json")
        let package = root.appendingPathComponent("package/seed.json")
        try writeMarker(package, contents: "package")

        let resolved = SeedPathResolver.resolve(
            explicit: nil,
            appSupportSeed: appSupport,
            packageSeed: package
        )
        #expect(resolved == package)
    }

    @Test("directory-only path does not count as existing seed file")
    func directoryDoesNotCountAsSeed() throws {
        let root = try tempRoot()
        defer { try? fm.removeItem(at: root) }

        // Path exists as a directory, not a file — must not win.
        let asDir = root.appendingPathComponent("appsupport/seed.json", isDirectory: true)
        try fm.createDirectory(at: asDir, withIntermediateDirectories: true)
        let package = root.appendingPathComponent("package/seed.json")
        try writeMarker(package, contents: "package")

        let resolved = SeedPathResolver.resolve(
            explicit: nil,
            appSupportSeed: asDir,
            packageSeed: package
        )
        #expect(resolved == package)
    }

    // MARK: - Product App Support seed path (uses store-path conventions)

    @Test("product App Support seed URL sits under ryk/fm-steward as seed.json")
    func productAppSupportSeedPath() {
        let url = SeedPathResolver.productAppSupportSeedURL()
        let path = url.path
        #expect(path.contains("Application Support"))
        #expect(path.contains("ryk/fm-steward"))
        #expect(url.lastPathComponent == "seed.json")
        #expect(url.lastPathComponent == SeedPathResolver.seedFileName)
    }
}
