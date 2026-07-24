import Foundation

/// Resolve the residual few-shot seed JSON path for product / host attach.
///
/// # Resolution contract (Host attach / README)
///
/// Seed path selection is **existence-checked** and ordered:
///
/// 1. **Explicit** seed URL (CLI / host override) — if the file exists
/// 2. When **both** App Support and package seeds exist:
///    - Prefer **package** unless content SHA-256 is equal (true copy of package) —
///      in which case App Support may be returned (operator-local mirror)
/// 3. Else first existing of: App Support → package → nil
///
/// # Trust model (assist only)
///
/// App Support `seed.json` is **operator-trusted** (same-user FS). When it
/// diverges from the package curated seed, product resolve prefers the package
/// fixture so a poisoned/stale App Support copy cannot shadow curated content
/// without an explicit `--seed` override. This is **not** a multi-user security
/// fence and does not replace Zig hard deny.
///
/// This type is a pure path helper: it does **not** load seed JSON into Wax,
/// reseed, or talk to `FewShotRuntime`. For first-run materialization of App
/// Support from the package fixture, call
/// `FewShotSeedBootstrap.bootstrapAppSupportSeedIfNeeded` **before** resolve.
/// Callers pass concrete layer URLs (or use `productAppSupportSeedURL()` for
/// the App Support default).
///
/// Existence means a **regular file** (directories do not win).
public enum SeedPathResolver: Sendable {
    /// On-disk file name for the residual seed JSON (App Support copy).
    public static let seedFileName = "seed.json"

    /// Product App Support seed copy URL (same directory as `ambig.wax`).
    ///
    /// Path: Application Support / `ryk/fm-steward` / `seed.json` (legacy: Orca/fm-steward).
    /// Built from `FewShotStorePaths.productRelativeDirectory`.
    public static func productAppSupportSeedURL(fileManager: FileManager = .default) -> URL {
        FewShotStorePaths.productStoreURL(fileManager: fileManager)
            .deletingLastPathComponent()
            .appendingPathComponent(seedFileName, isDirectory: false)
    }

    /// Resolve seed path with package preference on content divergence.
    ///
    /// - Parameters:
    ///   - explicit: Host/CLI override (e.g. `--seed`); skipped when nil or missing.
    ///   - appSupportSeed: Product App Support seed copy URL; skipped when nil/missing.
    ///   - packageSeed: Package `Fixtures/ambig-fewshot/seed.json`; skipped when nil/missing.
    ///   - fileManager: Inject for tests; defaults to `.default`.
    /// - Returns: Chosen existing **file** URL, or `nil` if none exist.
    public static func resolve(
        explicit: URL?,
        appSupportSeed: URL?,
        packageSeed: URL?,
        fileManager: FileManager = .default
    ) -> URL? {
        if let explicit, isExistingFile(explicit, fileManager: fileManager) {
            return explicit
        }

        let appSupportOK = appSupportSeed.map { isExistingFile($0, fileManager: fileManager) } ?? false
        let packageOK = packageSeed.map { isExistingFile($0, fileManager: fileManager) } ?? false

        if appSupportOK, packageOK, let appSupportSeed, let packageSeed {
            // Both present: prefer package unless bytes match (true copy).
            if contentSHA256Equal(appSupportSeed, packageSeed) {
                return appSupportSeed
            }
            return packageSeed
        }
        if appSupportOK, let appSupportSeed {
            return appSupportSeed
        }
        if packageOK, let packageSeed {
            return packageSeed
        }
        return nil
    }

    /// True when `url` exists on disk and is not a directory.
    private static func isExistingFile(_ url: URL, fileManager: FileManager) -> Bool {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return false
        }
        return !isDir.boolValue
    }

    /// Content-equal check via SHA-256 of file bytes (size-capped seed policy).
    /// Returns false on any read/hash failure (fail toward package preference).
    private static func contentSHA256Equal(_ a: URL, _ b: URL) -> Bool {
        guard let ha = try? FewShotSeedBootstrap.seedContentSHA256(of: a),
              let hb = try? FewShotSeedBootstrap.seedContentSHA256(of: b)
        else {
            return false
        }
        return ha == hb
    }
}
