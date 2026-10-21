#if os(macOS)
    import Foundation
    import MawCore

    /// What a maw virtual machine consists of, independent of Virtualization.framework.
    ///
    /// `VirtualMachine` turns this value into a `VZVirtualMachineConfiguration` when it starts.
    /// Keeping framework types out of this interface lets callers build, compare, and pass
    /// configurations across actors freely.
    public struct VMConfiguration: Sendable, Equatable {
        /// A disk image attached as a virtio block device (`/dev/vda`, `/dev/vdb`, ...), in order.
        public struct Disk: Sendable, Equatable {
            public var url: URL
            public var isReadOnly: Bool

            public init(url: URL, isReadOnly: Bool = false) {
                self.url = url
                self.isReadOnly = isReadOnly
            }
        }

        /// The CPU counts and memory sizes a virtual machine may have.
        public struct Limits: Sendable, Equatable {
            public var cpuCount: ClosedRange<Int>
            public var memorySize: ClosedRange<ByteSize>

            public init(cpuCount: ClosedRange<Int>, memorySize: ClosedRange<ByteSize>) {
                self.cpuCount = cpuCount
                self.memorySize = memorySize
            }
        }

        /// The kernel command line every VM starts with: the console is the virtio console.
        public static let baseCommandLine = "console=hvc0"
        public static let defaultMemorySize = ByteSize.gibibytes(2)

        /// `min(4, hostCPUCount)`, and at least 1.
        public static func defaultCPUCount(
            hostCPUCount: Int = ProcessInfo.processInfo.processorCount
        ) -> Int {
            max(1, min(4, hostCPUCount))
        }

        public var cpuCount: Int
        public var memorySize: ByteSize
        public var kernelURL: URL
        public var initramfsURL: URL
        public var commandLine: String
        public var disks: [Disk]
        /// Where the guest's console output is written. See `VirtualMachine`.
        public var consoleLogURL: URL

        public init(
            kernelURL: URL,
            initramfsURL: URL,
            consoleLogURL: URL,
            cpuCount: Int = VMConfiguration.defaultCPUCount(),
            memorySize: ByteSize = VMConfiguration.defaultMemorySize,
            commandLine: String = VMConfiguration.baseCommandLine,
            disks: [Disk] = []
        ) {
            self.kernelURL = kernelURL
            self.initramfsURL = initramfsURL
            self.consoleLogURL = consoleLogURL
            self.cpuCount = cpuCount
            self.memorySize = memorySize
            self.commandLine = commandLine
            self.disks = disks
        }

        /// `console=hvc0`, followed by `extra` if it contains anything but whitespace.
        public static func commandLine(appending extra: String?) -> String {
            let extra = extra?.split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
            return extra.isEmpty ? baseCommandLine : "\(baseCommandLine) \(extra)"
        }

        /// A copy whose CPU count and memory size lie within `limits`. Memory is also rounded
        /// down to whole mebibytes, which Virtualization.framework requires.
        public func clamped(to limits: Limits) -> VMConfiguration {
            var copy = self
            copy.cpuCount = cpuCount.clamped(to: limits.cpuCount)
            copy.memorySize = memorySize.clamped(to: limits.memorySize).roundedDownToMebibytes
            if copy.memorySize < limits.memorySize.lowerBound {
                copy.memorySize = limits.memorySize.lowerBound
            }
            return copy
        }
    }

    extension Comparable {
        fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
            min(max(self, range.lowerBound), range.upperBound)
        }
    }
#endif
