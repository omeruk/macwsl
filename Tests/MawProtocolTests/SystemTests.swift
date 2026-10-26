import Testing

@testable import MawProtocol

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

@Suite struct SystemTests {
    /// A session's descriptor must not reach a program that the daemon starts, such as `tar`
    /// during an install, which would keep the connection open and could read its bytes.
    @Test func duplicatesADescriptorThatIsClosedOnExec() throws {
        var fds: [Int32] = [-1, -1]
        try #require(pipe(&fds) == 0)
        defer {
            close(fds[0])
            close(fds[1])
        }
        try #require(fcntl(fds[1], F_GETFD) & FD_CLOEXEC == 0)

        let duplicate = duplicateClosingOnExec(fds[1])
        try #require(duplicate >= 0)
        defer { close(duplicate) }
        #expect(fcntl(duplicate, F_GETFD) & FD_CLOEXEC != 0)
        // The original's flag is unchanged, and both refer to the same pipe.
        #expect(fcntl(fds[1], F_GETFD) & FD_CLOEXEC == 0)
        let text = Array("ping".utf8)
        #expect(write(duplicate, text, text.count) == text.count)
        var buffer = [UInt8](repeating: 0, count: 4)
        #expect(read(fds[0], &buffer, buffer.count) == 4)
        #expect(buffer == text)
    }

    @Test func reportsADescriptorThatCannotBeDuplicated() {
        #expect(duplicateClosingOnExec(-1) == -1)
        #expect(errno == EBADF)
    }
}
