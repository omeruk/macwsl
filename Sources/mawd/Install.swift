import ArgumentParser
import Foundation
import MawClient
import MawCore
import MawDaemonKit
import MawVirtualization
import MawXPC

/// `mawd install`: registers the daemon with launchd, for development builds.
/// docs/decisions/0011-launchctl-registration.md explains why this is not `SMAppService` yet.
struct Install: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Register this mawd with launchd as the maw daemon.",
        discussion: """
            Writes ~/Library/LaunchAgents/dev.maw.mawd.plist, which runs this executable with \
            "serve" when maw connects, and loads it with launchctl bootstrap. If the agent is \
            already loaded, it is replaced and the daemon restarts, so that a rebuilt mawd takes \
            effect. The daemon's output goes to ~/Library/Logs/maw/mawd.log.

            Sign the build with scripts/sign-dev.sh first: the daemon needs the virtualization \
            entitlement, and maw must be signed for the daemon to accept it.
            """
    )

    /// How long `bootstrap` is retried while launchd still removes the previous job.
    static let bootstrapRetryTimeout = Duration.seconds(5)

    @OptionGroup var settings: DaemonSettings

    func run() async throws {
        guard let program = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            throw MawError.launchAgentFailed(reason: "the path of this executable is unknown")
        }
        let paths = MawPaths()
        let agent = LaunchAgent(
            label: settings.label, program: program.path(percentEncoded: false),
            logDirectory: settings.logDirectoryURL,
            machineIdleTimeout: settings.machineIdleTimeout,
            daemonIdleTimeout: settings.daemonIdleTimeout)
        let plist = paths.launchAgentFile(label: settings.label)

        do {
            try FileManager.default.createDirectory(
                at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: agent.logDirectory, withIntermediateDirectories: true)
            try agent.propertyListData().write(to: plist, options: .atomic)
        } catch let error as MawError {
            throw error
        } catch {
            throw MawError.launchAgentFailed(
                reason: "\(plist.path(percentEncoded: false)) could not be written: \(error)")
        }

        let replaced = Launchctl.isLoaded(settings.label)
        if replaced {
            // The daemon receives SIGTERM and stops its machines cleanly first.
            try Launchctl.bootout(settings.label)
        }
        try await bootstrap(plist)

        print(
            replaced
                ? "Replaced \(settings.label); the daemon restarts when maw next connects."
                : "Registered \(settings.label); launchd starts the daemon when maw connects.")
        print("Program: \(program.path(percentEncoded: false)) serve")
        print("Log: \(agent.logFile.path(percentEncoded: false))")
        if !VirtualizationErrors.processHasEntitlement() {
            print(
                "warning: this mawd is not signed with the virtualization entitlement, so "
                    + "sessions will fail. Run scripts/sign-dev.sh, then mawd install again.")
        }
    }

    /// `launchctl bootstrap`, retried briefly: right after `bootout`, launchd may still be
    /// removing the previous job and refuse the new one.
    private func bootstrap(_ plist: URL) async throws {
        let deadline = ContinuousClock.now + Self.bootstrapRetryTimeout
        while true {
            do throws(MawError) {
                try Launchctl.bootstrap(plist)
                return
            } catch {
                guard ContinuousClock.now < deadline else { throw error }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}

/// `mawd uninstall`: stops the daemon's machines and removes its LaunchAgent.
struct Uninstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Stop the maw daemon and remove it from launchd.",
        discussion: """
            Stops every virtual machine cleanly, unloads the LaunchAgent with launchctl \
            bootout, and removes its plist. The logs in ~/Library/Logs/maw are kept.
            """
    )

    @Option(help: .hidden)
    var label = DaemonInterface.defaultLabel

    func run() async throws {
        let paths = MawPaths()
        let plist = paths.launchAgentFile(label: label)
        let loaded = Launchctl.isLoaded(label)
        let exists = FileManager.default.fileExists(atPath: plist.path(percentEncoded: false))
        guard loaded || exists else {
            print("\(label) is not installed.")
            return
        }

        if loaded {
            if DaemonClient.isRunning(label: label, paths: paths) {
                // bootout's SIGTERM also stops the machines cleanly; asking first reports it.
                do {
                    let client = try await DaemonClient.connect(label: label, paths: paths)
                    let summary = try await client.shutdown()
                    client.close()
                    print(Self.describe(summary))
                } catch {
                    print("The daemon could not be asked to stop its machines; launchd stops it.")
                }
            }
            try Launchctl.bootout(label)
        }
        if exists {
            do {
                try FileManager.default.removeItem(at: plist)
            } catch {
                throw MawError.launchAgentFailed(
                    reason: "\(plist.path(percentEncoded: false)) could not be removed: \(error)")
            }
        }
        print("Removed \(label).")
    }

    static func describe(_ summary: ShutdownSummary) -> String {
        switch summary.stoppedMachines.count {
        case 0: "No virtual machine was running."
        case 1: "Stopped 1 virtual machine."
        case let count: "Stopped \(count) virtual machines."
        }
    }
}
