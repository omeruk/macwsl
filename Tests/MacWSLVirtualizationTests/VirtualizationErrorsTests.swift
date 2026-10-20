import Foundation
import MacWSLCore
import MacWSLVirtualization
import Testing
import Virtualization

@Suite struct VirtualizationErrorsTests {
    /// The error Virtualization.framework returns when the process lacks the entitlement,
    /// as observed on macOS 27.0.1.
    private let missingEntitlement = NSError(
        domain: VZErrorDomain,
        code: VZError.Code.invalidVirtualMachineConfiguration.rawValue,
        userInfo: [
            NSLocalizedFailureErrorKey: "Invalid virtual machine configuration.",
            NSLocalizedFailureReasonErrorKey:
                "The process doesn’t have the “com.apple.security.virtualization” entitlement.",
        ])

    private func vzError(_ code: VZError.Code, reason: String) -> NSError {
        NSError(
            domain: VZErrorDomain, code: code.rawValue,
            userInfo: [NSLocalizedFailureReasonErrorKey: reason])
    }

    @Test(arguments: [true, false])
    func recognizesTheMissingEntitlementByItsReason(processHasEntitlement: Bool) {
        let mapped = VirtualizationErrors.map(
            missingEntitlement, during: .configure, processHasEntitlement: processHasEntitlement)
        #expect(mapped == .virtualizationEntitlementMissing)
    }

    @Test func recognizesTheMissingEntitlementWhenTheReasonIsLocalized() {
        let localized = vzError(
            .invalidVirtualMachineConfiguration,
            reason: "Configuration de machine virtuelle non valide.")
        let mapped = VirtualizationErrors.map(
            localized, during: .start, processHasEntitlement: false)
        #expect(mapped == .virtualizationEntitlementMissing)
    }

    @Test func mapsOtherConfigurationErrors() {
        let error = vzError(
            .invalidVirtualMachineConfiguration, reason: "The memory size is too small.")
        let mapped = VirtualizationErrors.map(
            error, during: .configure, processHasEntitlement: true)
        #expect(mapped == .invalidVMConfiguration(reason: "The memory size is too small."))
    }

    @Test func explainsTheMissingEntitlementWithTheSigningScript() throws {
        let mapped = VirtualizationErrors.map(missingEntitlement, during: .start)
        let suggestion = try #require(mapped.recoverySuggestion)
        #expect(suggestion.contains("scripts/sign-dev.sh"))
        #expect(mapped.errorDescription?.contains("doesn’t have") == false)
    }

    @Test func mapsUnsupportedVirtualization() {
        let error = vzError(.notSupported, reason: "Nested virtualization is not supported.")
        #expect(
            VirtualizationErrors.map(error, during: .start, processHasEntitlement: true)
                == .virtualizationUnavailable(reason: "Nested virtualization is not supported."))
    }

    @Test(arguments: [
        (
            VirtualizationErrors.Operation.configure,
            MacWSLError.invalidVMConfiguration(reason: "boom")
        ),
        (.start, .vmStartFailed(reason: "boom")),
        (.run, .vmFailed(reason: "boom")),
        (.stop, .vmFailed(reason: "boom")),
    ])
    func mapsOtherErrorsByOperation(
        operation: VirtualizationErrors.Operation, expected: MacWSLError
    ) {
        #expect(
            VirtualizationErrors.map(
                vzError(.internalError, reason: "boom"), during: operation,
                processHasEntitlement: true)
                == expected)
        let foreign = NSError(
            domain: NSPOSIXErrorDomain, code: Int(EIO),
            userInfo: [NSLocalizedFailureReasonErrorKey: "boom"])
        #expect(
            VirtualizationErrors.map(foreign, during: operation, processHasEntitlement: true)
                == expected)
    }

    @Test func passesMacWSLErrorsThrough() {
        #expect(
            VirtualizationErrors.map(MacWSLError.guestStopTimedOut(seconds: 3), during: .run)
                == .guestStopTimedOut(seconds: 3))
    }

    @Test func detectsThatTheTestRunnerIsNotSigned() {
        // `swift test` runs an unsigned test bundle, so it never has the entitlement.
        #expect(VirtualizationErrors.processHasEntitlement() == false)
    }
}
