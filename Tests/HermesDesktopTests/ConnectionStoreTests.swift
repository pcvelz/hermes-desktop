import Foundation
import Testing

@testable import HermesDesktop

@MainActor
struct ConnectionStoreTests {
    @Test
    func missingFilesLoadDefaultStateWithoutPersistenceError() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ConnectionStore(paths: makeTestAppPaths(root: root))

        #expect(store.connections.isEmpty)
        #expect(store.lastConnectionID == nil)
        #expect(store.workspaceFileBookmarks.isEmpty)
        #expect(store.pinnedSessions.isEmpty)
        #expect(store.persistenceError == nil)
    }

    @Test
    func corruptedConnectionsJSONIsReportedAndIgnored() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = makeTestAppPaths(root: root)
        paths.ensureApplicationSupportDirectory()
        try Data("not-json".utf8).write(to: paths.connectionsURL)

        let store = ConnectionStore(paths: paths)

        #expect(store.connections.isEmpty)
        #expect(store.persistenceError?.contains("Unable to load saved hosts") == true)
    }

    @Test
    func corruptedPreferencesJSONFallsBackToDefaultsAndReportsError() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = makeTestAppPaths(root: root)
        paths.ensureApplicationSupportDirectory()
        try Data("{broken".utf8).write(to: paths.preferencesURL)

        let store = ConnectionStore(paths: paths)

        #expect(store.lastConnectionID == nil)
        #expect(store.terminalTheme == .defaultValue)
        #expect(store.windowMaterial == .solid)
        #expect(store.backgroundImageFit == .fill)
        #expect(store.backgroundImageBlur == 0)
        #expect(store.automaticallyChecksForUpdates)
        #expect(store.workspaceFileBookmarks.isEmpty)
        #expect(store.pinnedSessions.isEmpty)
        #expect(store.persistenceError?.contains("Unable to load app preferences") == true)
    }

    @Test
    func savingRecreatesPrunedSupportDirectoryAndAppliesPrivatePermissions() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = makeTestAppPaths(root: root)
        let store = ConnectionStore(paths: paths)
        try FileManager.default.removeItem(at: paths.applicationSupportURL)

        store.lastConnectionID = UUID()
        store.upsert(
            ConnectionProfile(
                label: "Prod",
                sshHost: "example.com",
                sshUser: "alice"
            )
        )

        #expect(FileManager.default.fileExists(atPath: paths.preferencesURL.path))
        #expect(FileManager.default.fileExists(atPath: paths.connectionsURL.path))
        #expect(try posixPermissions(at: paths.preferencesURL) == 0o600)
        #expect(try posixPermissions(at: paths.connectionsURL) == 0o600)
    }

    @Test
    func backgroundImageIsCopiedPersistedAndCleared() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = makeTestAppPaths(root: root)
        let sourceURL = root.appendingPathComponent("source-background.png")
        try samplePNGData.write(to: sourceURL)

        let store = ConnectionStore(paths: paths)
        store.setBackgroundImage(from: sourceURL)

        let savedURL = try #require(store.backgroundImageURL)
        #expect(savedURL != sourceURL)
        #expect(savedURL.deletingLastPathComponent() == paths.appearanceAssetsURL)
        #expect(store.backgroundImageOriginalFileName == "source-background.png")
        #expect(store.isBackgroundImageActive)
        #expect(try posixPermissions(at: savedURL) == 0o600)

        let reloadedStore = ConnectionStore(paths: paths)
        let reloadedURL = try #require(reloadedStore.backgroundImageURL)
        #expect(reloadedURL == savedURL)
        #expect(reloadedStore.isBackgroundImageActive)

        try FileManager.default.removeItem(at: reloadedURL)
        #expect(reloadedStore.backgroundImageURL == nil)
        #expect(reloadedStore.isBackgroundImageMissing)
        #expect(!reloadedStore.isBackgroundImageActive)

        reloadedStore.clearBackgroundImage()
        #expect(reloadedStore.backgroundImageOriginalFileName == nil)
        #expect(!reloadedStore.isBackgroundImageMissing)
    }
}

private func posixPermissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let number = try #require(attributes[.posixPermissions] as? NSNumber)
    return number.intValue
}

private let samplePNGData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=")!
