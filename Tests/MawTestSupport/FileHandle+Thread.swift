import Foundation

extension FileHandle {
    /// `read(upToCount:)` on a thread of its own, so that waiting for another process to write
    /// does not hold a thread of the cooperative pool, which every test shares.
    public func readOnAThreadOfItsOwn(upToCount count: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            Thread { [self] in
                continuation.resume(with: Result { try read(upToCount: count) })
            }.start()
        }
    }
}
