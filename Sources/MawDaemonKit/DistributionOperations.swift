#if os(macOS)
    import MawCore
    import os

    /// The operations that hold a distribution's name: installations, exports, and removals
    /// (docs/daemon.md, "Operations on a distribution").
    ///
    /// The installer, the daemon's service, and the machine registry share one instance. A name
    /// is held by at most one operation, compared in lowercase as APFS compares file names, so
    /// that `Twin` and `twin` never run two operations on one directory. While an export or a
    /// removal holds a name, its machine does not start (`MachineRegistry.start(_:)`); an
    /// installation's own first start is allowed.
    public final class DistributionOperations: Sendable {
        /// A held name, which `release(_:)` gives back.
        public struct Claim: Sendable, Equatable {
            public let name: DistroName
            public let operation: DistributionOperation
        }

        private let held = OSAllocatedUnfairLock(
            initialState: [String: DistributionOperation]())

        public init() {}

        /// The operation that holds `name`, if one does.
        public func operation(on name: DistroName) -> DistributionOperation? {
            held.withLock { $0[Self.key(name)] }
        }

        /// Throws the error that `claim(_:for:)` would throw for `name`, without claiming it.
        public func check(_ name: DistroName, for operation: DistributionOperation)
            throws(MawError)
        {
            if let holder = self.operation(on: name) {
                throw Self.conflict(name, holder: holder, requester: operation)
            }
        }

        /// Holds `name` for `operation`, or throws the error that names the operation that holds
        /// it already.
        public func claim(_ name: DistroName, for operation: DistributionOperation)
            throws(MawError) -> Claim
        {
            let holder = held.withLock { held -> DistributionOperation? in
                let key = Self.key(name)
                if let holder = held[key] {
                    return holder
                }
                held[key] = operation
                return nil
            }
            if let holder {
                throw Self.conflict(name, holder: holder, requester: operation)
            }
            return Claim(name: name, operation: operation)
        }

        /// Gives a claimed name back.
        public func release(_ claim: Claim) {
            held.withLock { held in
                let key = Self.key(claim.name)
                if held[key] == claim.operation {
                    held.removeValue(forKey: key)
                }
            }
        }

        /// The error for a request of `requester` on a name that `holder` holds. Two
        /// installations of one name keep the error they had before removals and exports.
        static func conflict(
            _ name: DistroName, holder: DistributionOperation, requester: DistributionOperation
        ) -> MawError {
            if holder == .install, requester == .install {
                return .installationInProgress(name)
            }
            return .distributionBusy(name, operation: holder)
        }

        private static func key(_ name: DistroName) -> String {
            name.rawValue.lowercased()
        }
    }
#endif
