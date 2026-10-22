import ArgumentParser
import Darwin
import Foundation
import MawCore
import MawDaemonKit
import MawTerminalIO
import MawVirtualization
import MawXPC
import Virtualization

/// `mawd serve`: the daemon. launchd runs it through the LaunchAgent that `mawd install`
/// writes, when a client connects to its Mach service.
struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Run the daemon (started by launchd; see mawd install).",
        discussion: """
            Serves the XPC interface on the Mach service that launchd registered for the \
            LaunchAgent, owns the virtual machines, and exits after five minutes without a \
            client or a running machine. SIGTERM stops every machine cleanly before it exits.
            """
    )

    @OptionGroup var settings: DaemonSettings

    func run() async throws {
        // A client that disappears must not take the daemon with it.
        signal(SIGPIPE, SIG_IGN)
        let log = DaemonLog { line in FileHandle.standardError.write(Data(line.utf8)) }
        let label = settings.label
        let paths = MawPaths()
        guard let lock = try DaemonLock.acquire(at: paths.daemonLockFile(label: label)) else {
            throw ValidationError("Another mawd serve already runs for \(label).")
        }

        let canRunVirtualMachines = VirtualizationErrors.processHasEntitlement()
        log.notice(
            "mawd \(MawVersion.current) starting for \(label), process \(getpid()), "
                + "interface version \(DaemonInterface.version)")
        if !canRunVirtualMachines {
            log.error(
                "this executable lacks the \(VirtualizationErrors.entitlement) entitlement; "
                    + "sessions will fail until it is signed with scripts/sign-dev.sh and "
                    + "registered again with mawd install")
        }

        let clock = ContinuousClock()
        let lifetime = DaemonLifetime(clock: clock, idleTimeout: settings.daemonIdleDuration) {
            log.notice("no client and no machine for \(settings.daemonIdleDuration); exiting")
            Darwin.exit(0)
        }
        // The registry reports activity changes in order through this stream, so that the
        // lifetime never sees them out of order.
        let (activity, activityContinuation) = AsyncStream.makeStream(of: Bool.self)
        Task {
            for await active in activity {
                await lifetime.setMachinesActive(active)
            }
        }
        let store = DistributionStore(paths: paths)
        // Left by an installation that the daemon could not clean up, such as one interrupted
        // by a crash or a power loss.
        for leftover in store.removeStagingLeftovers() {
            log.notice("removed \(leftover), left by an interrupted installation")
        }
        let registry = MachineRegistry(
            clock: clock, idleTimeout: settings.machineIdleDuration, log: log,
            factory: VirtualMachineHandle.factory(
                kernelDirectory: paths.kernelDirectory, logDirectory: settings.logDirectoryURL,
                store: store, log: log, canRunVirtualMachines: canRunVirtualMachines),
            activityChanged: { activityContinuation.yield($0) })
        let installLog = settings.logDirectoryURL.appending(path: "install.log")
        let installer = Installer(
            store: store,
            images: ImageCache(directory: settings.imageCacheDirectoryURL, log: log),
            makeMachine: { () throws(MawError) -> any ProvisioningMachine in
                guard canRunVirtualMachines else { throw .virtualizationEntitlementMissing }
                return VirtualProvisioningMachine(
                    kernelDirectory: paths.kernelDirectory, consoleLog: installLog, log: log)
            },
            freeSpace: FreeSpace.probe,
            startMachine: { machine throws(MawError) in try await registry.start(machine) },
            makeMACAddress: { VZMACAddress.randomLocallyAdministered().string },
            log: log)
        let service = DaemonService(
            clock: clock, registry: registry, lifetime: lifetime,
            canRunVirtualMachines: canRunVirtualMachines, store: store, installer: installer,
            log: log)

        let signals = SignalMonitor([SIGTERM, SIGINT, SIGHUP])
        Task {
            for await number in signals.signals {
                log.notice("received signal \(number); stopping every machine")
                await service.cancelInstallations()
                let summary = await registry.shutdown(reason: "the maw daemon is stopping")
                log.notice(
                    "stopped \(summary.stoppedMachines.count) machines and "
                        + "\(summary.endedSessions) sessions; exiting")
                Darwin.exit(0)
            }
        }

        let listener = XPCServiceListener(
            machService: label, codeSigningRequirement: PeerRequirement.codeSigningRequirement)
        listener.activate()
        await service.serve(listener)
        withExtendedLifetime(lock) {}
    }
}

/// The settings that `mawd install` passes to `mawd serve` through the LaunchAgent. All but
/// the defaults exist for the integration tests, which run a daemon of their own.
struct DaemonSettings: ParsableArguments {
    @Option(help: .hidden)
    var label = DaemonInterface.defaultLabel

    @Option(name: .customLong("log-directory"), help: .hidden)
    var logDirectory: String?

    @Option(name: .customLong("machine-idle-timeout"), help: .hidden)
    var machineIdleTimeout: Int?

    @Option(name: .customLong("daemon-idle-timeout"), help: .hidden)
    var daemonIdleTimeout: Int?

    @Option(name: .customLong("image-cache-directory"), help: .hidden)
    var imageCacheDirectory: String?

    func validate() throws {
        if label.isEmpty || label.contains("/") {
            throw ValidationError("--label must be a launchd label such as dev.maw.mawd.")
        }
        for (name, value) in [
            ("--machine-idle-timeout", machineIdleTimeout),
            ("--daemon-idle-timeout", daemonIdleTimeout),
        ] {
            if let value, value < 1 {
                throw ValidationError("\(name) must be at least 1 second.")
            }
        }
    }

    var logDirectoryURL: URL {
        logDirectory.map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? MawPaths().logsDirectory
    }

    var imageCacheDirectoryOverride: URL? {
        imageCacheDirectory.map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    var imageCacheDirectoryURL: URL {
        imageCacheDirectoryOverride ?? MawPaths().imageCacheDirectory
    }

    var machineIdleDuration: Duration {
        machineIdleTimeout.map { .seconds($0) } ?? DaemonTimeouts.machineIdle
    }

    var daemonIdleDuration: Duration {
        daemonIdleTimeout.map { .seconds($0) } ?? DaemonTimeouts.daemonIdle
    }
}
