import Foundation

/// Product and override paths for the residual Wax few-shot store.
///
/// Default product location: Application Support / ryk / fm-steward / ambig.wax.
/// Legacy (pre–Phase 5a): Application Support / Orca / fm-steward / ambig.wax.
/// First resolve migrates/copies legacy → primary when primary is missing.
/// Sidecar reseed key lives at `ambig.wax.seedsha`
/// (`v{N}:<seed-sha256>:<store-sha256>`; see `FewShotSeedBootstrap`);
/// reseed lock at `ambig.wax.reseed.lock`.
/// This type only resolves store URLs and parent directories.
public enum FewShotStorePaths: Sendable {
    /// On-disk file name for the residual Wax store.
    public static let storeFileName = "ambig.wax"

    /// Relative directory under Application Support for product data (Phase 5a primary).
    public static let productRelativeDirectory = "ryk/fm-steward"

    /// Pre–Phase 5a location kept for fallback/migration.
    public static let legacyProductRelativeDirectory = "Orca/fm-steward"

    /// Application Support base directory.
    public static func applicationSupportBase(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    /// Product default store URL under Application Support (primary ryk path).
    ///
    /// - Parameter fileManager: Inject for tests; defaults to `.default`.
    public static func productStoreURL(fileManager: FileManager = .default) -> URL {
        applicationSupportBase(fileManager: fileManager)
            .appendingPathComponent(productRelativeDirectory, isDirectory: true)
            .appendingPathComponent(storeFileName, isDirectory: false)
    }

    /// Legacy store URL under Application Support / Orca / fm-steward.
    public static func legacyProductStoreURL(fileManager: FileManager = .default) -> URL {
        applicationSupportBase(fileManager: fileManager)
            .appendingPathComponent(legacyProductRelativeDirectory, isDirectory: true)
            .appendingPathComponent(storeFileName, isDirectory: false)
    }

    /// Resolve store URL: explicit override wins; otherwise primary product path.
    /// When primary store is missing and legacy exists, best-effort copy legacy
    /// tree into the primary directory (first-run migrate), then return primary.
    ///
    /// Intended for CLI `--wax-store` and test temp paths.
    public static func storeURL(override: URL?, fileManager: FileManager = .default) -> URL {
        if let override {
            return override
        }
        migrateLegacyStoreIfNeeded(fileManager: fileManager)
        return productStoreURL(fileManager: fileManager)
    }

    /// If primary ambig.wax is missing and legacy exists, copy legacy directory contents.
    /// Failures are ignored (callers remain fail-open on residual quality).
    public static func migrateLegacyStoreIfNeeded(fileManager: FileManager = .default) {
        let primary = productStoreURL(fileManager: fileManager)
        let legacy = legacyProductStoreURL(fileManager: fileManager)
        if fileManager.fileExists(atPath: primary.path) {
            return
        }
        guard fileManager.fileExists(atPath: legacy.path) else {
            return
        }
        let primaryDir = primary.deletingLastPathComponent()
        let legacyDir = legacy.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: primaryDir, withIntermediateDirectories: true)
            let items = try fileManager.contentsOfDirectory(
                at: legacyDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for item in items {
                let dest = primaryDir.appendingPathComponent(item.lastPathComponent)
                if fileManager.fileExists(atPath: dest.path) { continue }
                try fileManager.copyItem(at: item, to: dest)
            }
            // Always ensure the store file itself is present if only store was there.
            if !fileManager.fileExists(atPath: primary.path),
               fileManager.fileExists(atPath: legacy.path)
            {
                try fileManager.copyItem(at: legacy, to: primary)
            }
        } catch {
            // Fail-open: residual quality may be colder until next successful seed.
        }
    }

    /// Create parent directory of `storeURL` if missing (intermediate dirs ok).
    ///
    /// Does not create the store file itself. Throws on FileManager failures
    /// (callers that need fail-open should catch).
    public static func ensureParentDirectory(
        for storeURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let parent = storeURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
    }
}
