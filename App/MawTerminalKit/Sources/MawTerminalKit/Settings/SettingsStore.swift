import Foundation
import Observation
import os

/// Owns the settings: loads them from `settings.json`, writes changes made in the app, and
/// reloads the file when it is edited elsewhere, as Windows Terminal does.
///
/// An invalid file never replaces the settings in use. `problem` describes it, the app shows a
/// banner, and the next valid save clears it.
@MainActor
@Observable
public final class SettingsStore {
    public private(set) var settings: Settings
    /// Why the file on disk is not in use, if it is not.
    public private(set) var problem: SettingsError?
    public let fileURL: URL

    @ObservationIgnored private let migration: SettingsMigration
    /// The bytes last read or written, so that the app's own writes do not trigger a reload.
    @ObservationIgnored private var lastData: Data?
    @ObservationIgnored private var watcher: FileWatcher?

    /// `~/Library/Application Support/maw/settings.json`.
    public static var defaultFileURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "maw", directoryHint: .isDirectory)
            .appending(path: "settings.json", directoryHint: .notDirectory)
    }

    public init(
        fileURL: URL = SettingsStore.defaultFileURL, migration: SettingsMigration = .standard
    ) {
        self.fileURL = fileURL
        self.migration = migration
        self.settings = Settings()
    }

    /// Reads the file, or creates it with the defaults if it does not exist.
    public func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            write(settings)
            return
        }
        reload()
    }

    /// Starts reloading the file whenever it changes on disk.
    public func startWatching(delay: Duration = .milliseconds(100)) {
        let watcher = FileWatcher(fileURL: fileURL, delay: delay) { [weak self] in
            self?.reload()
        }
        watcher.start()
        self.watcher = watcher
    }

    public func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    /// Changes the settings and saves them.
    ///
    /// While the file on disk is invalid or from a newer version, the change applies to this
    /// session only: writing would replace the user's unfinished edit or the newer format.
    public func update(_ change: (inout Settings) -> Void) {
        var updated = settings
        change(&updated)
        guard updated != settings else { return }
        settings = updated
        switch problem {
        case .invalid?, .newerVersion?:
            return
        case nil, .readFailed?, .writeFailed?:
            write(updated)
        }
    }

    /// Reads the file again. Called by the watcher; public so that tests and the app's
    /// "reload" paths can call it directly.
    public func reload() {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            // Removed, or in the middle of a replace. Keep the settings; a new file reloads.
            return
        } catch {
            problem = .readFailed(path: fileURL.path, reason: error.localizedDescription)
            return
        }
        guard data != lastData else { return }
        lastData = data
        do {
            let decoded = try SettingsCoding.decode(data, migration: migration)
            problem = nil
            if decoded != settings {
                settings = decoded
            }
        } catch {
            Logger.settings.error(
                "Ignoring invalid settings: \(error.localizedDescription, privacy: .public)")
            problem = error
        }
    }

    private func write(_ settings: Settings) {
        do {
            let data = try SettingsCoding.encode(settings)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            lastData = data
            problem = nil
        } catch let error as SettingsError {
            problem = error
        } catch {
            problem = .writeFailed(path: fileURL.path, reason: error.localizedDescription)
        }
    }
}
