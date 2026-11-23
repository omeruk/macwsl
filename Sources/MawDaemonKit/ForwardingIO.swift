#if os(macOS)
    import CMawSystem
    import Darwin
    import MawCore
    import MawProtocol
    import os

    /// A pipe that wakes a thread blocked in `poll`.
    final class WakePipe: Sendable {
        let read: OwnedDescriptor
        let write: OwnedDescriptor

        init() throws(SystemError) {
            var fds: [Int32] = [-1, -1]
            let code = maw_pipe(&fds)
            guard code == 0 else { throw SystemError("pipe", code: code) }
            read = OwnedDescriptor(fds[0])
            write = OwnedDescriptor(fds[1])
            _ = maw_set_nonblocking(fds[0])
            _ = maw_set_nonblocking(fds[1])
        }

        func wake() {
            var byte: UInt8 = 1
            _ = Darwin.write(write.rawValue, &byte, 1)
        }

        func drain() {
            var bytes = [UInt8](repeating: 0, count: 64)
            while Darwin.read(read.rawValue, &bytes, bytes.count) > 0 {}
        }
    }

    /// The daemon's side of a forwarding channel (docs/protocol.md, "Forwarding"), on a thread
    /// that alone uses the connection: it reads at all times and delivers each message, in
    /// order, to `messages`, and writes what `send(_:)` queues. The agent dialed the
    /// connection, so a pause in this thread would only hold the agent's writes back.
    final class ForwardingChannelLink: @unchecked Sendable {
        /// What ended the channel.
        enum Ending: Sendable, Equatable {
            case closed
            case failed(String)
        }

        let messages: AsyncStream<ControlMessage>
        private let continuation: AsyncStream<ControlMessage>.Continuation
        private let connection: FrameConnection
        private let wakePipe: WakePipe
        private let lock = OSAllocatedUnfairLock(
            initialState: (outgoing: [ControlMessage](), isClosed: false))
        private let ended: @Sendable (Ending) -> Void

        /// Starts the thread. `ended` runs once, on it, when the channel ends.
        init(
            connection: FrameConnection, ended: @escaping @Sendable (Ending) -> Void
        ) throws(SystemError) {
            self.connection = connection
            self.ended = ended
            wakePipe = try WakePipe()
            (messages, continuation) = AsyncStream.makeStream(of: ControlMessage.self)
            guard startDetachedThread({ [self] in run() }) else {
                continuation.finish()
                throw SystemError("pthread_create", code: EAGAIN)
            }
        }

        func send(_ message: ControlMessage) {
            lock.withLock { $0.outgoing.append(message) }
            wakePipe.wake()
        }

        /// Ends the channel; the agent sees it close.
        func close() {
            lock.withLock { $0.isClosed = true }
            wakePipe.wake()
        }

        private func run() {
            let ending: Ending
            do throws(ConnectionError) {
                ending = try serve()
            } catch {
                ending = .failed(error.description)
            }
            connection.descriptor.close()
            continuation.finish()
            ended(ending)
        }

        private func serve() throws(ConnectionError) -> Ending {
            while true {
                let (outgoing, isClosed) = lock.withLock { state in
                    defer { state.outgoing = [] }
                    return (state.outgoing, state.isClosed)
                }
                if isClosed { return .closed }
                for message in outgoing {
                    connection.enqueue(.control(message))
                }
                try connection.flush()
                var requests = [
                    pollfd(
                        fd: connection.rawDescriptor,
                        events: Int16(POLLIN)
                            | (connection.pendingOutputCount > 0 ? Int16(POLLOUT) : 0),
                        revents: 0),
                    pollfd(fd: wakePipe.read.rawValue, events: Int16(POLLIN), revents: 0),
                ]
                do {
                    _ = try pollDescriptors(&requests, timeout: -1)
                } catch {
                    throw .system(error)
                }
                if requests[1].revents != 0 {
                    wakePipe.drain()
                }
                if requests[0].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                    try connection.receive()
                    while let frame = try connection.nextFrame() {
                        do throws(FrameError) {
                            continuation.yield(try frame.controlMessage())
                        } catch {
                            throw .frame(error)
                        }
                    }
                    if connection.isAtEndOfInput {
                        return .failed("the agent closed the channel")
                    }
                }
            }
        }
    }

    /// Accepts the Mac's connections to every forwarded port of one machine, on one thread
    /// that polls all of their listening sockets, and delivers each with its port to
    /// `connections`.
    final class LoopbackAcceptor: @unchecked Sendable {
        let connections: AsyncStream<(connection: OwnedDescriptor, port: UInt16)>
        private let continuation:
            AsyncStream<(connection: OwnedDescriptor, port: UInt16)>.Continuation
        private let wakePipe: WakePipe
        private let state = OSAllocatedUnfairLock(
            initialState: (listening: [UInt16: LoopbackListeners](), isStopped: false))

        init() throws(SystemError) {
            wakePipe = try WakePipe()
            (connections, continuation) = AsyncStream.makeStream(
                of: (connection: OwnedDescriptor, port: UInt16).self)
            guard startDetachedThread({ [self] in run() }) else {
                continuation.finish()
                throw SystemError("pthread_create", code: EAGAIN)
            }
        }

        func add(_ listeners: LoopbackListeners, for port: UInt16) {
            let accepted = state.withLock { state in
                guard !state.isStopped else { return false }
                state.listening[port] = listeners
                return true
            }
            if !accepted {
                listeners.close()
            }
            wakePipe.wake()
        }

        /// Stops accepting on `port` and closes its sockets at once, so that the port is free
        /// on the Mac when this returns.
        func remove(_ port: UInt16) {
            let removed = state.withLock { $0.listening.removeValue(forKey: port) }
            removed?.close()
            wakePipe.wake()
        }

        /// Closes every listening socket and ends the thread.
        func stop() {
            let removed = state.withLock { state in
                state.isStopped = true
                defer { state.listening = [:] }
                return Array(state.listening.values)
            }
            for listeners in removed {
                listeners.close()
            }
            wakePipe.wake()
        }

        private func run() {
            defer { continuation.finish() }
            while true {
                let (listening, isStopped) = state.withLock { ($0.listening, $0.isStopped) }
                if isStopped { return }
                var requests = [
                    pollfd(fd: wakePipe.read.rawValue, events: Int16(POLLIN), revents: 0)
                ]
                for listeners in listening.values {
                    for descriptor in listeners.descriptors {
                        requests.append(
                            pollfd(fd: descriptor.rawValue, events: Int16(POLLIN), revents: 0))
                    }
                }
                guard (try? pollDescriptors(&requests, timeout: -1)) != nil else {
                    usleep(10_000)
                    continue
                }
                if requests[0].revents != 0 {
                    wakePipe.drain()
                }
                for request in requests.dropFirst() where request.revents & Int16(POLLIN) != 0 {
                    acceptAll(on: request.fd)
                }
            }
        }

        /// Accepts every connection waiting on `descriptor`, if it still is one of the
        /// listening sockets: a port removed meanwhile closed its sockets, and the number may
        /// have been reused. The lookup and the accept, which does not block, hold the lock, so
        /// that `remove(_:)` cannot close the socket between them.
        private func acceptAll(on descriptor: Int32) {
            while true {
                let accepted: (OwnedDescriptor, UInt16)? = state.withLock { state in
                    guard
                        let port = state.listening.first(where: { entry in
                            entry.value.descriptors.contains { $0.rawValue == descriptor }
                        })?.key
                    else { return nil }
                    var connection: Int32 = -1
                    guard maw_tcp_accept(descriptor, &connection) == 0 else { return nil }
                    return (OwnedDescriptor(connection), port)
                }
                guard let (connection, port) = accepted else { return }
                continuation.yield((connection, port))
            }
        }
    }
#endif
