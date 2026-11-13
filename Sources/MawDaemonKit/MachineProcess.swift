#if os(macOS)
    import Darwin

    /// A process, by its ID and its start time, so that a reused process ID is never read.
    public struct ProcessIdentity: Hashable, Sendable {
        public var processID: pid_t
        /// Microseconds since 1970, from `PROC_PIDTBSDINFO`.
        public var startTime: UInt64

        public init(processID: pid_t, startTime: UInt64) {
            self.processID = processID
            self.startTime = startTime
        }
    }

    /// A file by its device and inode, as `stat` and `PROC_PIDFDVNODEPATHINFO` report them.
    public struct FileIdentity: Hashable, Sendable {
        public var device: UInt64
        public var inode: UInt64

        public init(device: UInt64, inode: UInt64) {
            self.device = device
            self.inode = inode
        }

        /// The identity of the file at `path`, or `nil` if it cannot be read.
        public init?(path: String) {
            var status = stat()
            guard stat(path, &status) == 0 else { return nil }
            self.init(
                device: UInt64(UInt32(bitPattern: status.st_dev)), inode: UInt64(status.st_ino))
        }
    }

    /// What a machine's process costs on the Mac.
    public struct ProcessUsage: Equatable, Sendable {
        /// User and system CPU time.
        public var cpuNanoseconds: UInt64
        /// The memory footprint (`ri_phys_footprint`), as Activity Monitor shows it.
        public var footprintBytes: UInt64

        public init(cpuNanoseconds: UInt64, footprintBytes: UInt64) {
            self.cpuNanoseconds = cpuNanoseconds
            self.footprintBytes = footprintBytes
        }
    }

    /// The Mac's processes, as the lookup reads them. `DarwinProcessTable` is the real one; the
    /// unit tests use a fake.
    public protocol ProcessTable: Sendable {
        func processIDs() -> [pid_t]
        /// The process's executable, or `nil` if the process has exited or cannot be read.
        func executablePath(of processID: pid_t) -> String?
        /// The process's user and start time, or `nil`.
        func owner(of processID: pid_t) -> (user: uid_t, startTime: UInt64)?
        /// The identities of the process's open files.
        func openFiles(of processID: pid_t) -> [FileIdentity]
        /// The process's CPU time and footprint, or `nil`.
        func usage(of processID: pid_t) -> ProcessUsage?
    }

    /// Finds the Virtualization.framework process that runs a machine
    /// ([decision record 0020](../../docs/decisions/0020-distribution-figures.md)).
    ///
    /// Each virtual machine runs in a process of its own, which Apple documents neither by name
    /// nor by ID. The machine's process is the one with the machine's disk image open. To keep
    /// the lookup to processes that can be machines, it reads the open files only of processes
    /// whose executable is Virtualization.framework's and whose user is the daemon's.
    public enum MachineProcessFinder {
        public static let executablePath =
            "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/"
            + "com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/"
            + "com.apple.Virtualization.VirtualMachine"

        /// The one process of `user` that runs Virtualization.framework's executable and has
        /// `diskImage` open, or `nil` if there is none or more than one.
        public static func find(
            diskImage: FileIdentity, user: uid_t, in table: some ProcessTable
        ) -> ProcessIdentity? {
            var matches: [ProcessIdentity] = []
            for processID in table.processIDs() where processID > 0 {
                guard table.executablePath(of: processID) == executablePath,
                    let owner = table.owner(of: processID), owner.user == user
                else {
                    continue
                }
                if table.openFiles(of: processID).contains(diskImage) {
                    matches.append(
                        ProcessIdentity(processID: processID, startTime: owner.startTime))
                }
            }
            return matches.count == 1 ? matches[0] : nil
        }

        /// The usage of `process`, or `nil` if it has exited or its ID now names another
        /// process.
        public static func usage(of process: ProcessIdentity, in table: some ProcessTable)
            -> ProcessUsage?
        {
            guard table.owner(of: process.processID)?.startTime == process.startTime else {
                return nil
            }
            return table.usage(of: process.processID)
        }
    }

    /// One machine run's lookup: it runs at the run's first sample and, while it finds
    /// nothing, at each following sample, at most `retries` more times. After that the run has
    /// no process, and `next(...)` reports it once.
    public struct MachineProcessLookup: Sendable {
        /// Lookups after the first: about 15 seconds at one sample every 1.5 seconds.
        public static let retries = 10

        public enum Outcome: Equatable, Sendable {
            case found(ProcessIdentity)
            /// Not found yet; the next sample looks again.
            case notYet
            /// Not found, and given up just now. The caller logs this once.
            case gaveUp
            /// Given up earlier in this run.
            case givenUp
        }

        private var process: ProcessIdentity?
        private var attempts = 0

        public init() {}

        /// The run's process, looking it up with `find` if it is not known yet.
        public mutating func next(_ find: () -> ProcessIdentity?) -> Outcome {
            if let process { return .found(process) }
            guard attempts <= Self.retries else { return .givenUp }
            attempts += 1
            if let found = find() {
                process = found
                return .found(found)
            }
            return attempts > Self.retries ? .gaveUp : .notYet
        }
    }

    /// The Mac's process table, through libproc. Needs no privilege for the user's own
    /// processes.
    public struct DarwinProcessTable: ProcessTable {
        public init() {}

        public func processIDs() -> [pid_t] {
            let count = proc_listallpids(nil, 0)
            guard count > 0 else { return [] }
            // Room for processes that start between the two calls.
            var processIDs = [pid_t](repeating: 0, count: Int(count) + 64)
            let filled = processIDs.withUnsafeMutableBytes {
                proc_listallpids($0.baseAddress, Int32($0.count))
            }
            guard filled > 0 else { return [] }
            return Array(processIDs.prefix(Int(filled)))
        }

        public func executablePath(of processID: pid_t) -> String? {
            var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
            let length = proc_pidpath(processID, &buffer, UInt32(buffer.count))
            guard length > 0 else { return nil }
            return String(
                decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }

        public func owner(of processID: pid_t) -> (user: uid_t, startTime: UInt64)? {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info, size) == size else {
                return nil
            }
            return (info.pbi_uid, info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec)
        }

        public func openFiles(of processID: pid_t) -> [FileIdentity] {
            let needed = proc_pidinfo(processID, PROC_PIDLISTFDS, 0, nil, 0)
            guard needed > 0 else { return [] }
            let stride = MemoryLayout<proc_fdinfo>.stride
            // Room for descriptors that open between the two calls.
            var descriptors = [proc_fdinfo](
                repeating: proc_fdinfo(), count: Int(needed) / stride + 16)
            let filled = descriptors.withUnsafeMutableBytes {
                proc_pidinfo(processID, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
            }
            guard filled > 0 else { return [] }
            return descriptors.prefix(Int(filled) / stride).compactMap {
                descriptor -> FileIdentity? in
                guard descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { return nil }
                var vnode = vnode_fdinfowithpath()
                let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                guard
                    proc_pidfdinfo(
                        processID, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &vnode, size)
                        == size
                else {
                    return nil
                }
                let status = vnode.pvip.vip_vi.vi_stat
                return FileIdentity(
                    device: UInt64(status.vst_dev), inode: status.vst_ino)
            }
        }

        public func usage(of processID: pid_t) -> ProcessUsage? {
            var info = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(processID, RUSAGE_INFO_V4, $0)
                }
            }
            guard result == 0 else { return nil }
            return ProcessUsage(
                cpuNanoseconds: Self.nanoseconds(machTime: info.ri_user_time + info.ri_system_time),
                footprintBytes: info.ri_phys_footprint)
        }

        /// `ri_user_time` and `ri_system_time` count in the units of `mach_absolute_time`,
        /// which are not nanoseconds on Apple silicon.
        private static let timebase: mach_timebase_info_data_t = {
            var timebase = mach_timebase_info_data_t()
            mach_timebase_info(&timebase)
            return timebase
        }()

        static func nanoseconds(machTime: UInt64) -> UInt64 {
            let (product, overflow) = machTime.multipliedReportingOverflow(
                by: UInt64(timebase.numer))
            guard !overflow, timebase.denom != 0 else {
                return machTime / UInt64(max(timebase.denom, 1)) * UInt64(timebase.numer)
            }
            return product / UInt64(timebase.denom)
        }
    }
#endif
