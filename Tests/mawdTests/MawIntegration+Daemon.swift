import Foundation
import MawDaemonKit
import MawXPC
import Testing

/// Registering the test daemon again, for the measurements that need `mawd serve` options which
/// `mawd install` does not accept. Both act only on the test daemon's label, which `MawIntegration`
/// requires to differ from `dev.maw.mawd`.
extension MawIntegration {
    /// Registers the test daemon again with `mawd serve` options that `mawd install` does not
    /// accept: the plist that `mawd install` would write, with `options` added. The daemon
    /// restarts.
    func registerDaemon(_ options: [String]) async throws {
        let mawd = try #require(Self.environment["MAWD_PATH"])
        let agent = LaunchAgent(
            label: label, program: mawd, logDirectory: logDirectory,
            machineIdleTimeout: machineIdleTimeout, imageCacheDirectory: imageCache)
        var list = agent.propertyList
        list["ProgramArguments"] = agent.arguments + options
        let plist = paths.launchAgentFile(label: label)
        try PropertyListSerialization.data(fromPropertyList: list, format: .xml, options: 0)
            .write(to: plist, options: .atomic)
        try Launchctl.bootout(label)
        try await Launchctl.waitUntilRemoved(label)
        try Launchctl.bootstrap(plist)
    }

    /// Registers the test daemon again as scripts/integration-test.sh does.
    func reinstallDaemon() throws {
        let install = Process()
        install.executableURL = URL(filePath: try #require(Self.environment["MAWD_PATH"]))
        install.arguments = [
            "install", "--label", label, "--log-directory",
            logDirectory.path(percentEncoded: false), "--machine-idle-timeout",
            String(machineIdleTimeout), "--image-cache-directory",
            imageCache.path(percentEncoded: false),
        ]
        try install.run()
        install.waitUntilExit()
        try #require(install.terminationStatus == 0, "mawd install failed")
    }
}
