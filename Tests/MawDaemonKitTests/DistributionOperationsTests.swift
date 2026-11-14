import Foundation
import MawCore
import MawDaemonKit
import Testing

@Suite struct DistributionOperationsTests {
    static func name(_ name: String) -> DistroName {
        try! DistroName(name)
    }

    @Test func holdsANameUntilItIsReleased() throws {
        let operations = DistributionOperations()
        let claim = try operations.claim(Self.name("Copy"), for: .removal)
        #expect(operations.operation(on: Self.name("Copy")) == .removal)
        operations.release(claim)
        #expect(operations.operation(on: Self.name("Copy")) == nil)
        _ = try operations.claim(Self.name("Copy"), for: .export)
    }

    /// APFS ignores case, so `copy` and `Copy` are one directory and one name.
    @Test func comparesNamesWithoutRegardToCase() throws {
        let operations = DistributionOperations()
        _ = try operations.claim(Self.name("Copy"), for: .export)
        #expect(operations.operation(on: Self.name("COPY")) == .export)
        #expect(throws: MawError.distributionBusy(Self.name("copy"), operation: .export)) {
            try operations.claim(Self.name("copy"), for: .removal)
        }
    }

    /// Each refusal names the operation that holds the name; two installations keep their own
    /// error.
    @Test(arguments: [
        (DistributionOperation.install, DistributionOperation.install),
        (.install, .removal), (.export, .export), (.export, .removal), (.removal, .install),
        (.removal, .export), (.removal, .removal),
    ])
    func namesTheHolderWhenItRefuses(
        _ holder: DistributionOperation, _ requester: DistributionOperation
    ) throws {
        let operations = DistributionOperations()
        _ = try operations.claim(Self.name("Copy"), for: holder)
        let expected: MawError =
            holder == .install && requester == .install
            ? .installationInProgress(Self.name("Copy"))
            : .distributionBusy(Self.name("Copy"), operation: holder)
        #expect(throws: expected) { try operations.check(Self.name("Copy"), for: requester) }
        #expect(throws: expected) { try operations.claim(Self.name("Copy"), for: requester) }
        #expect(operations.operation(on: Self.name("Copy")) == holder)
    }

    /// A release by an operation that does not hold the name changes nothing.
    @Test func releasesOnlyItsOwnClaim() throws {
        let operations = DistributionOperations()
        let removal = try operations.claim(Self.name("Copy"), for: .removal)
        operations.release(removal)
        let export = try operations.claim(Self.name("Copy"), for: .export)
        operations.release(removal)
        #expect(operations.operation(on: Self.name("Copy")) == .export)
        operations.release(export)
    }
}

@Suite struct RegistryOperationTests {
    /// While an export or a removal holds a distribution's name, its machine does not start,
    /// and no session opens; an installation's first start goes on.
    @Test(arguments: [DistributionOperation.export, .removal])
    func refusesToStartWhileAnOperationHoldsTheName(_ operation: DistributionOperation)
        async throws
    {
        let operations = DistributionOperations()
        let factory = FakeFactory()
        let registry = MachineRegistry(
            clock: TestClock(), factory: factory.factory, operations: operations)
        let machine = MachineID.distribution(try DistroName("Copy"))
        let claim = try operations.claim(try DistroName("COPY"), for: operation)
        await #expect(
            throws: MawError.distributionBusy(try DistroName("Copy"), operation: operation)
        ) {
            try await registry.start(machine)
        }
        await #expect(
            throws: MawError.distributionBusy(try DistroName("Copy"), operation: operation)
        ) {
            _ = try await registry.openSession(on: machine) { _, _ in }
        }
        #expect(factory.machines.isEmpty)
        #expect(await registry.isStopped(machine))
        operations.release(claim)
        try await registry.start(machine)
        #expect(await !registry.isStopped(machine))
    }

    @Test func letsAnInstallationStartItsDistribution() async throws {
        let operations = DistributionOperations()
        let registry = MachineRegistry(
            clock: TestClock(), factory: FakeFactory().factory, operations: operations)
        _ = try operations.claim(try DistroName("Copy"), for: .install)
        try await registry.start(.distribution(try DistroName("Copy")))
    }

    /// A removal that begins while a session waits for the machine's start refuses that
    /// session once the start has finished, instead of giving it a lease.
    @Test func refusesASessionThatWaitedForTheStart() async throws {
        let operations = DistributionOperations()
        let factory = FakeFactory { _ in (nil, true) }
        let registry = MachineRegistry(
            clock: TestClock(), factory: factory.factory, operations: operations)
        let machine = MachineID.distribution(try DistroName("Copy"))
        let session = Task {
            _ = try await registry.openSession(on: machine) { _, _ in }
        }
        try await eventually("the start waits") {
            factory.machines.first?.isWaitingToStart == true
        }
        _ = try operations.claim(try DistroName("Copy"), for: .removal)
        factory.machines[0].finishStart()
        await #expect(
            throws: MawError.distributionBusy(try DistroName("Copy"), operation: .removal)
        ) {
            try await session.value
        }
        #expect(factory.machines[0].connections == 0)
    }
}
