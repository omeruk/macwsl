#if os(macOS)
    import Foundation
    import MawCore
    import MawProtocol
    import MawVirtualization
    import MawXPC
    import os

    /// Provisions a distribution's disk in the initramfs machine: the guest kernel and
    /// initramfs with the new disk attached, whose `mkfs.ext4` and `bsdtar` do the Linux side,
    /// as decision record 0003 requires.
    ///
    /// Every step is a command run as root through the guest agent. The image is decompressed
    /// on the Mac by `/usr/bin/tar` (libarchive) and streamed to `bsdtar` in the guest as a
    /// plain tar archive; decompressing on the Mac measured faster than in the guest.
    public final class VirtualProvisioningMachine: ProvisioningMachine, @unchecked Sendable {
        /// The provisioning machine's memory: enough for the page cache of an extraction.
        static let memorySize = ByteSize.gibibytes(4)
        /// Whether new users linger, so that their user manager keeps running between
        /// sessions and a login shell does not wait for it to start.
        static let lingers = true

        private let kernelDirectory: URL
        private let consoleLog: URL
        private let log: DaemonLog
        private let handle = OSAllocatedUnfairLock<VirtualMachineHandle?>(initialState: nil)

        public init(kernelDirectory: URL, consoleLog: URL, log: DaemonLog = DaemonLog()) {
            self.kernelDirectory = kernelDirectory
            self.consoleLog = consoleLog
            self.log = log
        }

        public func boot(disk: URL) async throws(MawError) {
            let guest = try GuestFiles(directory: kernelDirectory)
            try? FileManager.default.removeItem(at: consoleLog)
            let configuration = VMConfiguration(
                kernelURL: guest.kernelURL, initramfsURL: guest.initramfsURL,
                consoleLogURL: consoleLog,
                cpuCount: VMConfiguration.distributionResources().cpuCount,
                memorySize: Self.memorySize,
                commandLine: VMConfiguration.commandLine(
                    appending: "maw.clock=\(Int(Date().timeIntervalSince1970))"),
                disks: [.init(url: disk)])
            let machine = try VirtualMachineHandle(
                machine: .initramfs, configuration: configuration, log: log)
            handle.withLock { $0 = machine }
            try await machine.start()
        }

        public func format() async throws(MawError) {
            // assume_storage_prezeroed: the sparse disk reads as zeros, so neither mke2fs nor
            // the kernel's lazy initialization writes zeros to it, which would allocate them on
            // the Mac. nodiscard: there is nothing to discard on a new sparse file.
            try await run(
                "formatting the disk",
                [
                    "/bin/sh", "-c",
                    "mkfs.ext4 -q -F -L maw-root -m 1 -E assume_storage_prezeroed=1,nodiscard "
                        + "/dev/vda && mkdir -p /mnt/root && mount -t ext4 /dev/vda /mnt/root",
                ])
        }

        public func extract(image: URL, format: CatalogImage.Format) async throws(MawError) {
            let step = "extracting the root file system"
            let errors = OutputCollector()
            let process = try await client().exec(
                ExecRequest(
                    argv: [
                        "bsdtar", "-x", "-p", "--numeric-owner", "--xattrs", "-f", "-", "-C",
                        "/mnt/root",
                    ]),
                output: errors.handler)
            // /usr/bin/tar re-encodes the image as an uncompressed pax archive, which keeps the
            // extended attributes. Its output goes to bsdtar's standard input on a thread of
            // its own, because reading the pipe and `GuestProcess.write` both block.
            let tar = await withCheckedContinuation {
                (
                    continuation: CheckedContinuation<
                        Result<StreamingProcess.Outcome, any Error>, Never
                    >
                ) in
                startDetachedThread {
                    let outcome = Result {
                        try StreamingProcess.run(
                            "/usr/bin/tar",
                            [
                                "-c", "-f", "-", "--format", "pax",
                                "@" + image.path(percentEncoded: false),
                            ]
                        ) { chunk in process.write(chunk) }
                    }
                    process.closeInput()
                    continuation.resume(returning: outcome)
                }
            }
            let status = try await process.waitForExit()
            guard status == .exited(code: 0) else {
                throw .provisioningFailed(step: step, reason: "bsdtar \(status): \(errors.tail)")
            }
            switch tar {
            case .failure(let error):
                throw .provisioningFailed(
                    step: step, reason: "/usr/bin/tar cannot start: \(error.localizedDescription)")
            case .success(let outcome) where outcome.status != 0:
                throw .provisioningFailed(
                    step: step,
                    reason: "/usr/bin/tar exited with status \(outcome.status): \(outcome.errors)")
            case .success:
                break
            }
        }

        public func configure(_ configuration: GuestConfiguration) async throws(MawError) {
            let step = "configuring the distribution"
            let arguments = try ProvisioningScript.arguments(
                for: configuration, linger: Self.lingers)
            try await run(
                step, ["/bin/sh", "-s", "--"] + arguments,
                input: Data(ProvisioningScript.text.utf8))
            // The password travels only as chpasswd's standard input.
            try await run(
                "setting the password", ["chroot", "/mnt/root", "/usr/sbin/chpasswd"],
                input: Data("\(configuration.user.rawValue):\(configuration.password.value)\n".utf8)
            )
        }

        public func finish() async throws(MawError) {
            try await run("writing the disk", ["/bin/sh", "-c", "sync && umount /mnt/root"])
            if let machine = handle.withLock({ $0 }) {
                let outcome = await machine.stop()
                log.notice("provisioning machine: \(outcome)")
            }
        }

        public func discard() async {
            guard let machine = handle.withLock({ $0 }) else { return }
            await machine.forceStop(reason: "the installation was cancelled or failed")
        }

        // MARK: Commands

        private func client() throws(MawError) -> GuestAgentClient {
            guard let machine = handle.withLock({ $0 }) else {
                throw .provisioningFailed(
                    step: "provisioning", reason: "the provisioning machine is not running")
            }
            return GuestAgentClient(guestName: "the provisioning machine") {
                () throws(MawError) in
                try await machine.connectToAgent()
            }
        }

        /// Runs `argv` as root and throws `provisioningFailed` unless it exits with 0. The
        /// command's standard output and error are kept for the error message, never logged.
        private func run(_ step: String, _ argv: [String], input: Data? = nil)
            async throws(MawError)
        {
            let output = OutputCollector()
            let process = try await client().exec(
                ExecRequest(argv: argv), output: output.handler)
            if let input {
                process.write(input)
            }
            process.closeInput()
            let status = try await process.waitForExit()
            guard status == .exited(code: 0) else {
                throw .provisioningFailed(step: step, reason: "\(status): \(output.tail)")
            }
        }
    }

    /// The last 2 KiB of a command's output, for an error message.
    private final class OutputCollector: Sendable {
        private let bytes = OSAllocatedUnfairLock(initialState: [UInt8]())

        var handler: GuestAgentClient.OutputHandler {
            { [bytes] _, buffer in
                let received = Array(buffer.suffix(2048))
                bytes.withLock {
                    $0.append(contentsOf: received)
                    if $0.count > 2048 {
                        $0.removeFirst($0.count - 2048)
                    }
                }
            }
        }

        var tail: String {
            let text = String(decoding: bytes.withLock { $0 }, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "no output" : text
        }
    }
#endif
