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
/// so that nothing is left when maw exits. Output from then on goes through an `OutputQueue`,
/// so that a terminal that does not read, such as one stopped with Ctrl-S, cannot hold up the
/// cancellation or the exit.
struct InstallCommand {
    let options: InstallOptions
    /// Connects to the daemon. The tests replace it.
    var connect: @Sendable () async throws(MawError) -> any InstallDaemon = {
        () async throws(MawError) -> any InstallDaemon in
        try await DaemonClient.connect()
    }
    /// Announces the installation and asks for the account, or reads it. The tests replace it.
    var askForAccount: ((Preparation) throws -> (UserName, Secret))?

    /// How long maw waits for the daemon to confirm a cancellation before it exits anyway.
    static let cancelTimeout = Duration.seconds(5)
    /// How long the messages after Ctrl-C may wait for a terminal that does not read before
    /// maw exits without them. The daemon has removed the installation by then.
    static let outputTimeout = Duration.milliseconds(250)

    /// What is known before the account is asked for.
    struct Preparation {
        let entry: CatalogEntry
        let name: DistroName
        let isInteractive: Bool
    }

    /// Everything before the installation starts, in an order that asks for nothing before
    /// an error that is knowable without it: the catalog entry and the name, the terminal,
    /// the connection to the daemon with its signature check, the daemon's checks of the
    /// name and the free space, and only then the account.
    func prepare() async throws -> (Preparation, any InstallDaemon, UserName, Secret) {
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
        let isInteractive = isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
        if options.user == nil, !isInteractive {
            throw MawError.installNeedsTerminal
        }

        let client = try await connect()
        let account: (UserName, Secret)
        do {
            try await client.checkInstall(distribution: entry.name.rawValue, name: options.name)
            let preparation = Preparation(entry: entry, name: name, isInteractive: isInteractive)
            account = try (askForAccount ?? readAccount)(preparation)
            return (preparation, client, account.0, account.1)
        } catch {
            client.close()
            throw error
        }
    }

    func run() async throws -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        let (preparation, client, user, password) = try await prepare()
        defer { client.close() }
        let entry = preparation.entry
        let name = preparation.name

        let output = OutputQueue()
        let view = InstallProgressView(
            text: InstallProgressText(name: name, displayName: entry.displayName),
            isTerminal: isatty(STDOUT_FILENO) == 1, output: output.write)
        let request = InstallRequest(
            distribution: entry.name.rawValue, name: options.name, user: user.rawValue,
            password: password,
            locale: GuestLocale.preferred(
                languageCode: Locale.current.language.languageCode?.identifier,
                regionCode: Locale.current.region?.identifier))
        let signals = SignalMonitor([SIGINT, SIGTERM, SIGHUP])
        // A resized window gets the download's line redrawn at once, not at the next update.
        let resizes = SignalMonitor([SIGWINCH])

        switch try await Self.perform(
            request, name: name, on: client, view: view, output: output,
            signals: signals.signals, resizes: resizes.signals)
        {
        case .status(let status):
            return status
        case .installed(let summary):
            guard preparation.isInteractive else { return 0 }
            // As wsl --install does: the new distribution opens.
            let plan = SessionPlan(machine: .distribution(summary.name), program: .loginShell)
            return try await SessionRunner(plan: plan, mode: .terminal).run()
        }
    }

    /// How `perform` ended, when it did not throw.
    enum Ending {
        /// The distribution is installed, and the summary written.
        case installed(InstallSummary)
        /// maw exits with this status: a signal cancelled the installation.
        case status(Int32)
    }

    /// Runs the installation with its progress and returns once it has ended. A signal cancels
    /// it.
    ///
    /// After a signal, everything that maw still writes waits at most `outputTimeout` for the
    /// terminal. After the end in any other way, SIGINT, SIGTERM, and SIGHUP regain their
    /// default action while maw waits for the terminal to take its last lines, since there is
    /// nothing left to cancel.
    static func perform(
        _ request: InstallRequest, name: DistroName, on client: any InstallDaemon,
        view: InstallProgressView, output: OutputQueue, signals: AsyncStream<Int32>,
        resizes: AsyncStream<Int32>
    ) async throws -> Ending {
        let resizing = Task {
            for await _ in resizes {
                view.resized()
            }
        }
        let outcome = await firstOutcome(
            install: { () async throws(MawError) -> InstallSummary in
                try await client.install(request)
            },
            events: client.events, view: view, signals: signals)
        resizing.cancel()

        switch outcome {
        case .installed(let summary):
            view.finish()
            output.write("\n" + Self.summary(summary) + "\n")
            restoreDefaultSignalActions()
            await output.waitUntilWritten()
            return .installed(summary)
        case .failed(let error):
            view.interrupt()
            restoreDefaultSignalActions()
            await output.waitUntilWritten()
            throw error
        case .signal(let number):
            view.interrupt()
            output.writeError("Cancelling the installation...\n")
            let error: MawError
            switch await cancel(on: client) {
            case .cancelled:
                error = .installationCancelled(name)
            case .alreadyFinished:
                output.write(
                    "The installation had already finished. Run maw -d \(name) to use it.\n")
                await output.waitUntilWritten(timeout: outputTimeout)
                return .status(0)
            case .unconfirmed:
                error = .daemonConnectionLost(during: "cancelling the installation")
            }
            output.writeError(Maw.failure(for: error)?.output ?? "")
            await output.waitUntilWritten(timeout: outputTimeout)
            return .status(128 + number)
        }
    }

    /// Gives SIGINT, SIGTERM, and SIGHUP their default action again, which ends maw.
    private static func restoreDefaultSignalActions() {
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_DFL)
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
                    let summary = try await install()
                    // The reply can arrive before the last step's event, which travels as a
                    // message of its own; give it a moment so that the step's line is complete.
                    await view.waitUntilIdle(timeout: .milliseconds(500))
                    first.settle(.installed(summary))
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
    static func cancel(on client: any InstallDaemon) async -> Cancellation {
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

    /// Announces the installation, then asks for the account on the terminal, or, with
    /// `--user`, reads the password.
    func readAccount(_ preparation: Preparation) throws -> (UserName, Secret) {
        let entry = preparation.entry
        print(
            "Installing \(entry.displayName)"
                + (preparation.name == entry.name ? "." : " as \(preparation.name)."))
        if let given = options.user {
            let user = try UserName(given, reservedNames: entry.reservedNames)
            // On a terminal, the password is asked for without echo, never read as typed text.
            let password =
                isatty(STDIN_FILENO) == 1 ? try Self.askForPassword() : try Self.readPasswordLine()
            return (user, password)
        }
        return try Self.askForAccount(reservedNames: entry.reservedNames)
    }

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
        return (user!, try askForPassword())
    }

    /// Asks for the password twice, without echoing it, until both entries match.
    static func askForPassword() throws -> Secret {
        while true {
            let first = try readSecret(prompt: "New password: ")
            if first.value.isEmpty {
                print("The password must not be empty.")
                continue
            }
            let second = try readSecret(prompt: "Retype the new password: ")
            if first == second {
                return first
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
/// starts and its duration when it ends, on the same line.
///
/// `output` must not block, and in maw it only queues the text on an `OutputQueue`: the view
/// calls it while it holds its lock, which keeps the lines in order, and `stop()`, on the way
/// from Ctrl-C to the exit, takes the same lock.
///
/// On a terminal, the download's line is redrawn in place. It is fitted to the terminal's
/// width at every update, and erased to the end of the screen before it is drawn again. A
/// terminal that is made narrower wraps the line already drawn onto more rows, as Terminal.app
/// and iTerm2 do; the redraw first moves up over those rows. Elsewhere, only each step's final
/// line is written.
final class InstallProgressView: @unchecked Sendable {
    private let text: InstallProgressText
    private let isTerminal: Bool
    private let columns: @Sendable () -> Int?
    private let output: @Sendable (String) -> Void
    private let lock = NSLock()
    private var current: InstallStep?
    private var lastDownload: DownloadProgress?
    /// The length of the download's line on the screen, while it is drawn.
    private var drawnLength = 0
    private var stopped = false

    init(
        text: InstallProgressText, isTerminal: Bool,
        columns: @escaping @Sendable () -> Int? = {
            Terminal.windowSize().map { Int($0.columns) }
        },
        output: @escaping @Sendable (String) -> Void
    ) {
        self.text = text
        self.isTerminal = isTerminal
        self.columns = columns
        self.output = output
    }

    func show(_ progress: InstallProgress) {
        lock.withLock {
            guard !stopped else { return }
            switch progress {
            case .started(let step):
                current = step
                if step == .download, isTerminal {
                    drawDownload(columns: columns())
                } else {
                    output(text.padded(step))
                }
            case .download(let download):
                lastDownload = download
                if isTerminal {
                    drawDownload(columns: columns())
                }
            case .finished(let step, let milliseconds):
                if step == .download, isTerminal {
                    let width = columns()
                    redraw(
                        text.downloadedLine(
                            lastDownload, milliseconds: milliseconds,
                            columns: width.map(Self.usable)),
                        columns: width)
                    output("\n")
                    drawnLength = 0
                } else if step == .download {
                    output(
                        InstallProgressText.downloaded(lastDownload, milliseconds: milliseconds)
                            + "\n")
                } else {
                    output(InstallProgressText.duration(milliseconds: milliseconds) + "\n")
                }
                current = nil
            }
        }
    }

    /// Draws the download's line again for the terminal's new width.
    func resized() {
        lock.withLock {
            guard !stopped, isTerminal, current == .download else { return }
            drawDownload(columns: columns())
        }
    }

    /// Returns once no step is in progress, or after `timeout`.
    func waitUntilIdle(timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while lock.withLock({ current != nil }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
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
                output("\n")
                current = nil
                drawnLength = 0
            }
        }
    }

    func finish() {
        interrupt()
    }

    /// The columns a line may use: all but the last, so that the cursor never waits at the
    /// right margin, where terminals differ in what a carriage return does.
    static func usable(_ columns: Int) -> Int {
        max(1, columns - 1)
    }

    private func drawDownload(columns width: Int?) {
        redraw(
            text.downloadingLine(lastDownload, columns: width.map(Self.usable)), columns: width)
    }

    /// Replaces the download's line on the screen with `line`: back to the start of the line,
    /// up over the rows that a narrower window wrapped it onto, and erased to the end of the
    /// screen.
    private func redraw(_ line: String, columns width: Int?) {
        var sequence = "\r"
        if let width, drawnLength > 0 {
            let rowsAbove = (drawnLength - 1) / width
            if rowsAbove > 0 {
                sequence += "\u{1B}[\(rowsAbove)A"
            }
        }
        sequence += "\u{1B}[J" + line
        drawnLength = line.count
        output(sequence)
    }
}

/// What `maw --install` needs from the daemon. The tests supply a fake.
protocol InstallDaemon: Sendable {
    var events: AsyncStream<DaemonClient.Event> { get }
    func checkInstall(distribution: String?, name: DistroName?) async throws(MawError)
    func install(_ request: InstallRequest) async throws(MawError) -> InstallSummary
    func cancelInstall() async throws(MawError) -> Bool
    func close()
}

extension DaemonClient: InstallDaemon {}

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
