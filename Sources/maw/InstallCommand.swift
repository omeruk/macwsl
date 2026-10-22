import Darwin
import Foundation
import MawClient
import MawCore
import MawTerminalIO
import MawXPC

/// `maw --install`: asks for the new account, has the daemon install the distribution while
/// it shows the progress, and opens a shell in it when run in a terminal, as `wsl --install`
/// does.
///
/// Ctrl-C asks the daemon to cancel and waits until it has removed the installation's traces,
/// so that nothing is left when maw exits.
struct InstallCommand {
    let options: InstallOptions

    /// How long maw waits for the daemon to confirm a cancellation before it exits anyway.
    static let cancelTimeout = Duration.seconds(5)

    func run() async throws -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        let catalog = DistroCatalog.builtIn
        let entry: CatalogEntry
        if let wanted = options.distro {
            guard let found = catalog.entry(named: wanted.rawValue) else {
                throw MawError.unknownDistribution(wanted.rawValue)
            }
            entry = found
        } else {
            entry = catalog.recommendedEntry
        }
        let name = options.name ?? entry.name
        // Checked before asking for anything; the daemon checks again.
        if FileManager.default.fileExists(
            atPath: MawPaths().metadataFile(for: name).path(percentEncoded: false))
        {
            throw MawError.distributionAlreadyInstalled(name)
        }

        let interactive = isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
        print(
            "Installing \(entry.displayName)"
                + (name == entry.name ? "." : " as \(name)."))
        let (user, password): (UserName, Secret)
        if let given = options.user {
            user = try UserName(given, reservedNames: entry.reservedNames)
            password = try Self.readPasswordLine()
        } else if interactive {
            (user, password) = try Self.askForAccount(reservedNames: entry.reservedNames)
        } else {
            throw MawError.installNeedsTerminal
        }

        let client = try await DaemonClient.connect()
        defer { client.close() }
        let view = InstallProgressView(
            text: InstallProgressText(name: name, displayName: entry.displayName),
            isTerminal: isatty(STDOUT_FILENO) == 1)
        let request = InstallRequest(
            distribution: entry.name.rawValue, name: options.name, user: user.rawValue,
            password: password,
            locale: GuestLocale.preferred(
                languageCode: Locale.current.language.languageCode?.identifier,
                regionCode: Locale.current.region?.identifier))

        let signals = SignalMonitor([SIGINT, SIGTERM, SIGHUP])
        let outcome = await Self.firstOutcome(
            install: { () async throws(MawError) -> InstallSummary in
                try await client.install(request)
            },
            events: client.events, view: view, signals: signals.signals)

        switch outcome {
        case .installed(let summary):
            view.finish()
            print("")
            print(Self.summary(summary))
            guard interactive else { return 0 }
            // As wsl --install does: the new distribution opens.
            let plan = SessionPlan(machine: .distribution(summary.name), program: .loginShell)
            return try await SessionRunner(plan: plan, mode: .terminal).run()
        case .failed(let error):
            view.interrupt()
            throw error
        case .signal(let number):
            view.interrupt()
            FileHandle.standardError.write(Data("Cancelling the installation...\n".utf8))
            let error: MawError
            switch await Self.cancel(on: client) {
            case .cancelled:
                error = .installationCancelled(name)
            case .alreadyFinished:
                print("The installation had already finished. Run maw -d \(name) to use it.")
                return 0
            case .unconfirmed:
                error = .daemonConnectionLost(during: "cancelling the installation")
            }
            FileHandle.standardError.write(Data((Maw.failure(for: error)?.output ?? "").utf8))
            return 128 + number
        }
    }

    enum Outcome {
        case installed(InstallSummary)
        case failed(MawError)
        case signal(Int32)
    }

    /// Waits for the installation to end or a signal, showing progress meanwhile.
    ///
    /// The three run as tasks of their own rather than in a task group, which would wait for
    /// the installation's request to return even after a signal: that request cannot be
    /// cancelled from here, only by `cancelInstall`, which must be sent at once.
    static func firstOutcome(
        install: @escaping @Sendable () async throws(MawError) -> InstallSummary,
        events: AsyncStream<DaemonClient.Event>, view: InstallProgressView,
        signals: AsyncStream<Int32>
    ) async -> Outcome {
        let first = FirstResult<Outcome>()
        return await withCheckedContinuation { continuation in
            first.onResult { outcome in
                view.stop()
                continuation.resume(returning: outcome)
            }
            Task {
                do throws(MawError) {
                    first.settle(.installed(try await install()))
                } catch {
                    first.settle(.failed(error))
                }
            }
            Task {
                for await event in events {
                    switch event {
                    case .installProgress(let progress):
                        view.show(progress)
                    case .connectionLost:
                        first.settle(.failed(.daemonConnectionLost(during: "the installation")))
                    case .sessionEnded:
                        continue
                    }
                }
            }
            Task {
                for await number in signals {
                    first.settle(.signal(number))
                    return
                }
            }
        }
    }

    enum Cancellation {
        /// The daemon stopped the installation and removed its traces.
        case cancelled
        /// The installation had already finished.
        case alreadyFinished
        /// The daemon did not confirm within `cancelTimeout`.
        case unconfirmed
    }

    /// Asks the daemon to cancel and waits, for at most `cancelTimeout`, until it has removed
    /// the installation's traces.
    static func cancel(on client: DaemonClient) async -> Cancellation {
        let first = FirstResult<Cancellation>()
        return await withCheckedContinuation { continuation in
            first.onResult { continuation.resume(returning: $0) }
            Task {
                switch try? await client.cancelInstall() {
                case true: first.settle(.cancelled)
                case false: first.settle(.alreadyFinished)
                case nil: first.settle(.unconfirmed)
                }
            }
            Task {
                try? await Task.sleep(for: cancelTimeout)
                first.settle(.unconfirmed)
            }
        }
    }

    static func summary(_ summary: InstallSummary) -> String {
        let role = summary.isDefault ? ", and is the default distribution" : ""
        let open =
            summary.isDefault ? "Run maw" : "Run maw -d \(summary.name)"
        return "\(summary.name) is installed\(role). \(open) to open a shell as "
            + "\(summary.defaultUser)."
    }

    // MARK: The account

    /// Asks for the user name until it is valid, then for the password twice, without
    /// echoing it, until both entries match.
    static func askForAccount(reservedNames: [String]) throws -> (UserName, Secret) {
        print(
            "Create the default Linux user account. Its name does not need to match your "
                + "Mac user name.")
        var user: UserName?
        while user == nil {
            print("New user name: ", terminator: "")
            fflush(stdout)
            guard let line = readLine(strippingNewline: true) else {
                throw MawError.invalidUserName("", reason: "no name was entered")
            }
            do {
                user = try UserName(line, reservedNames: reservedNames)
            } catch {
                print(error.errorDescription ?? "", error.recoverySuggestion ?? "")
            }
        }
        while true {
            let first = try readSecret(prompt: "New password: ")
            if first.value.isEmpty {
                print("The password must not be empty.")
                continue
            }
            let second = try readSecret(prompt: "Retype the new password: ")
            if first == second {
                return (user!, first)
            }
            print("The passwords do not match. Try again.")
        }
    }

    /// Reads a password from the terminal without echoing it. Ctrl-C ends maw, and
    /// `readpassphrase` restores the terminal first.
    static func readSecret(prompt: String) throws -> Secret {
        var buffer = [CChar](repeating: 0, count: 1024)
        defer { buffer.withUnsafeMutableBytes { _ = memset($0.baseAddress, 0, $0.count) } }
        guard
            readpassphrase(prompt, &buffer, buffer.count, RPP_ECHO_OFF | RPP_REQUIRE_TTY) != nil
        else {
            throw MawError.invalidPassword(reason: "no password was entered")
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return Secret(String(decoding: bytes, as: UTF8.self))
    }

    /// With `--user`: the password is the first line of standard input.
    static func readPasswordLine() throws -> Secret {
        guard let line = readLine(strippingNewline: true) else {
            throw MawError.invalidPassword(reason: "standard input contained no password")
        }
        return Secret(line)
    }
}

/// Writes the progress of an installation to standard output: each step's label when it
/// starts and its duration when it ends, on the same line. On a terminal, the download's line
/// is updated in place.
final class InstallProgressView: @unchecked Sendable {
    private let text: InstallProgressText
    private let isTerminal: Bool
    private let lock = NSLock()
    private var current: InstallStep?
    private var lastDownload: DownloadProgress?
    private var stopped = false

    init(text: InstallProgressText, isTerminal: Bool) {
        self.text = text
        self.isTerminal = isTerminal
    }

    func show(_ progress: InstallProgress) {
        lock.withLock {
            guard !stopped else { return }
            switch progress {
            case .started(let step):
                current = step
                write(text.padded(step))
            case .download(let download):
                lastDownload = download
                if isTerminal {
                    write(
                        "\r\u{1B}[K" + text.padded(.download)
                            + InstallProgressText.downloading(download))
                }
            case .finished(let step, let milliseconds):
                if step == .download {
                    let result = InstallProgressText.downloaded(
                        lastDownload, milliseconds: milliseconds)
                    write((isTerminal ? "\r\u{1B}[K" + text.padded(.download) : "") + result + "\n")
                } else {
                    write(InstallProgressText.duration(milliseconds: milliseconds) + "\n")
                }
                current = nil
            }
        }
    }

    /// Ignores later progress: the outcome is known, and the daemon may still report steps
    /// while it cancels.
    func stop() {
        lock.withLock { stopped = true }
    }

    /// Ends a step's line that a failure or Ctrl-C interrupted.
    func interrupt() {
        lock.withLock {
            if current != nil {
                write("\n")
                current = nil
            }
        }
    }

    func finish() {
        interrupt()
    }

    /// Through `stdout`, as `print` writes, so that the two never interleave out of order.
    private func write(_ string: String) {
        print(string, terminator: "")
        fflush(stdout)
    }
}

/// Delivers the first of several results to one handler, once.
final class FirstResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((Value) -> Void)?
    private var pending: Value?
    private var isSettled = false

    func onResult(_ handler: @escaping (Value) -> Void) {
        let value = lock.withLock { () -> Value? in
            self.handler = handler
            return pending
        }
        if let value {
            handler(value)
        }
    }

    func settle(_ value: Value) {
        let handler = lock.withLock { () -> ((Value) -> Void)?? in
            guard !isSettled else { return nil }
            isSettled = true
            if self.handler == nil {
                pending = value
            }
            return .some(self.handler)
        }
        if case .some(.some(let handler)) = handler {
            handler(value)
        }
    }
}
