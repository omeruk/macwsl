import Foundation

/// Calls `onChange` shortly after a file is changed, created, replaced, or removed.
///
/// Editors save in different ways: some write the file in place, others write a new file and
/// rename it over the old one. The watcher therefore observes both the file and the directory
/// that contains it, and reopens the file after a rename or deletion. Bursts of events are
/// coalesced into one call after `delay`.
@MainActor
final class FileWatcher {
    private let fileURL: URL
    private let delay: Duration
    private let onChange: @MainActor () -> Void
    private var directorySource: (any DispatchSourceFileSystemObject)?
    private var fileSource: (any DispatchSourceFileSystemObject)?
    private var pending: Task<Void, Never>?

    init(
        fileURL: URL, delay: Duration = .milliseconds(100),
        onChange: @escaping @MainActor () -> Void
    ) {
        self.fileURL = fileURL
        self.delay = delay
        self.onChange = onChange
    }

    func start() {
        stop()
        directorySource = makeSource(
            path: fileURL.deletingLastPathComponent().path,
            events: [.write, .rename, .delete, .link]
        ) { [weak self] _ in
            self?.changed(reopenFile: true)
        }
        watchFile()
    }

    func stop() {
        directorySource?.cancel()
        directorySource = nil
        fileSource?.cancel()
        fileSource = nil
        pending?.cancel()
        pending = nil
    }

    private func watchFile() {
        fileSource?.cancel()
        fileSource = makeSource(
            path: fileURL.path, events: [.write, .extend, .attrib, .rename, .delete]
        ) { [weak self] events in
            self?.changed(reopenFile: !events.isDisjoint(with: [.rename, .delete]))
        }
    }

    private func changed(reopenFile: Bool) {
        if reopenFile || fileSource == nil {
            watchFile()
        }
        pending?.cancel()
        pending = Task { [delay, onChange] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            onChange()
        }
    }

    /// A dispatch source for `path` on the main queue, or `nil` if the path cannot be opened,
    /// for example a file that does not exist yet. The directory source notices its creation.
    private func makeSource(
        path: String, events: DispatchSource.FileSystemEvent,
        handler: @escaping @MainActor (DispatchSource.FileSystemEvent) -> Void
    ) -> (any DispatchSourceFileSystemObject)? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        // Dispatch sources need a queue; the main queue keeps the handler on the main actor.
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: events, queue: .main)
        source.setEventHandler { [weak source] in
            let data = source?.data ?? []
            MainActor.assumeIsolated { handler(data) }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }
}
