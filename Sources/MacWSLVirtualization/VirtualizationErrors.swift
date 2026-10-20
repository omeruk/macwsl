#if os(macOS)
    import Foundation
    import MacWSLCore
    import Security
    import Virtualization

    /// Translates Virtualization.framework errors into `MacWSLError`, so that callers never show
    /// a framework error raw.
    public enum VirtualizationErrors {
        /// The entitlement every process that creates a VM must be signed with.
        public static let entitlement = "com.apple.security.virtualization"

        /// What was being done when the error occurred. It selects the error case for framework
        /// errors that carry no more specific meaning.
        public enum Operation: Sendable {
            case configure, start, run, stop
        }

        /// Whether the running process is signed with `entitlement`.
        public static func processHasEntitlement() -> Bool {
            guard let task = SecTaskCreateFromSelf(nil) else { return false }
            let value = SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil)
            return (value as? Bool) == true
        }

        /// Maps `error` to a `MacWSLError`.
        ///
        /// Without the entitlement, `validate()` and `start` fail with the generic
        /// `invalidVirtualMachineConfiguration` code, and only the localized failure reason
        /// mentions the entitlement. That error is therefore recognized by two signals: the
        /// process lacks the entitlement, or the reason names its identifier, which is not
        /// localized.
        public static func map(
            _ error: any Error,
            during operation: Operation,
            processHasEntitlement: Bool = VirtualizationErrors.processHasEntitlement()
        ) -> MacWSLError {
            if let error = error as? MacWSLError {
                return error
            }
            let error = error as NSError
            let reason = Self.reason(for: error)
            guard error.domain == VZErrorDomain else {
                return generic(reason, during: operation)
            }
            switch VZError.Code(rawValue: error.code) {
            case .invalidVirtualMachineConfiguration:
                if !processHasEntitlement || reason.contains(entitlement) {
                    return .virtualizationEntitlementMissing
                }
                return .invalidVMConfiguration(reason: reason)
            case .notSupported:
                return .virtualizationUnavailable(reason: reason)
            default:
                return generic(reason, during: operation)
            }
        }

        private static func generic(_ reason: String, during operation: Operation) -> MacWSLError {
            switch operation {
            case .configure: .invalidVMConfiguration(reason: reason)
            case .start: .vmStartFailed(reason: reason)
            case .run, .stop: .vmFailed(reason: reason)
            }
        }

        /// The most specific description the error carries.
        private static func reason(for error: NSError) -> String {
            let reason = error.userInfo[NSLocalizedFailureReasonErrorKey] as? String
            return reason ?? error.localizedDescription
        }
    }
#endif
